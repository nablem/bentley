defmodule Bentley.Snipers.PositionManager do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias Bentley.Repo
  alias Bentley.Schema.SniperPosition
  alias Bentley.Schema.SniperTrade
  alias Bentley.Schema.Token
  alias Bentley.Snipers.Definition
  alias Bentley.Snipers.TelegramNotifier

  @epsilon 1.0e-9
  @usdc_base_unit_scale 1_000_000
  @default_reconcile_zero_close_grace_seconds 60
  @default_reconcile_zero_recheck_delay_ms 750

  @spec open_position(Definition.t(), String.t(), Token.t(), String.t(), NaiveDateTime.t()) ::
          :ok | {:error, term()}
  def open_position(
        %Definition{} = definition,
        notifier_id,
        %Token{} = token,
        wallet_id,
        now \\ current_time()
      )
      when is_binary(wallet_id) do
    cond do
      not definition.buy_config.enabled ->
        :ok

      is_nil(token.market_cap) ->
        {:error, :missing_market_cap}

      true ->
        with {:ok, normalized_wallet_id} <- normalize_wallet_id(wallet_id),
             :ok <- ensure_position_limit(definition, normalized_wallet_id),
             :ok <- ensure_min_wallet_usdc(definition, normalized_wallet_id),
             {:ok, buy_result} <- execute_buy(definition, token, normalized_wallet_id),
             {:ok, units} <- normalize_units(buy_result),
             :ok <-
               persist_open_position(
                 definition,
                 notifier_id,
                 token,
                 normalized_wallet_id,
                 units,
                 buy_result,
                 now
               ) do
          :ok
        else
          {:error, {:insufficient_wallet_usdc, _wallet_usdc_balance, _min_wallet_usdc}} = error ->
            error

          {:error, reason} = error ->
            TelegramNotifier.notify_buy_failure(definition, wallet_id, token, reason)
            error
        end
    end
  end

  @spec process_open_positions(Definition.t(), NaiveDateTime.t()) ::
          {:ok,
           %{processed: non_neg_integer(), sells: non_neg_integer(), closed: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, term()}
  def process_open_positions(%Definition{} = definition, now \\ current_time()) do
    positions =
      SniperPosition
      |> where([p], p.sniper_id == ^definition.id and p.status == "open")
      |> Repo.all()

    summary =
      Enum.reduce(positions, %{processed: 0, sells: 0, closed: 0, failed: 0}, fn position, acc ->
        case process_position(definition, position, now) do
          {:ok, %{sells: sells, closed: closed}} ->
            %{acc | processed: acc.processed + 1, sells: acc.sells + sells, closed: acc.closed + closed}

          {:error, reason} ->
            Logger.error(
              "[Snipers] Failed processing position #{position.id} (#{definition.id}/#{position.token_address}): #{inspect(reason)}"
            )

            %{acc | processed: acc.processed + 1, failed: acc.failed + 1}
        end
      end)

    {:ok, summary}
  rescue
    e -> {:error, e}
  end

  defp process_position(definition, position, now) do
    case Repo.get_by(Token, token_address: position.token_address) do
      nil ->
        handle_missing_token_position(definition, position, now)

      token ->
        with {:ok, {position_after_reconcile, reconcile_closed}} <-
               maybe_reconcile_position(definition, position, token, now),
             {:ok, {position_after_risk, risk_sells, risk_closed}} <-
               maybe_apply_risk_exits(definition, position_after_reconcile, token, now),
             {:ok, {tier_sells, tier_closed}} <-
               maybe_apply_tier_exits(definition, position_after_risk, token, now) do
          {:ok, %{sells: risk_sells + tier_sells, closed: reconcile_closed + risk_closed + tier_closed}}
        end
    end
  end

  defp handle_missing_token_position(definition, %SniperPosition{} = position, now) do
    cond do
      position.remaining_units <= @epsilon ->
        Logger.warning(
          "[Snipers] Closing #{definition.id}/#{position.wallet_id}/#{position.token_address}: token row missing with zero remaining units"
        )

        case close_position(position, now) do
          {:ok, {_updated_position, closed}} -> {:ok, %{sells: 0, closed: closed}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        Logger.warning(
          "[Snipers] Token row missing for #{definition.id}/#{position.wallet_id}/#{position.token_address}; attempting full liquidation"
        )

        synthetic_token = %Token{token_address: position.token_address}

        case sell_all(definition, position, synthetic_token, "token_row_missing", now) do
          {:ok, {_updated_position, sells, closed}} -> {:ok, %{sells: sells, closed: closed}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_reconcile_position(definition, %SniperPosition{} = position, %Token{} = token, now) do
    case executor().token_balance(token, %{sniper_id: definition.id, wallet_id: position.wallet_id}) do
      {:ok, onchain_balance} when is_number(onchain_balance) and onchain_balance >= 0 ->
        cond do
          onchain_balance <= @epsilon ->
            maybe_close_zero_balance(definition, position, token, now, onchain_balance)

          onchain_balance + @epsilon < position.remaining_units ->
            Logger.info(
              "[Snipers] Reconciliation adjusting #{definition.id}/#{position.wallet_id}/#{position.token_address}: remaining #{position.remaining_units} -> #{onchain_balance}"
            )

            position
            |> SniperPosition.changeset(%{remaining_units: onchain_balance})
            |> Repo.update()
            |> case do
              {:ok, updated_position} -> {:ok, {updated_position, 0}}
              {:error, reason} -> {:error, reason}
            end

          true ->
            {:ok, {position, 0}}
        end

      {:ok, onchain_balance} ->
        {:error, {:invalid_token_balance, onchain_balance}}

      {:error, reason} ->
        {:error, {:token_balance_check_failed, reason}}
    end
  end

  defp maybe_close_zero_balance(definition, %SniperPosition{} = position, %Token{} = token, now, onchain_balance) do
    if within_zero_close_grace?(position, now) do
      Logger.info(
        "[Snipers] Reconciliation observed zero balance for #{definition.id}/#{position.wallet_id}/#{position.token_address} within grace window; keeping position open"
      )

      {:ok, {position, 0}}
    else
      case confirm_zero_balance(definition, position, token) do
        {:ok, true} ->
          Logger.info(
            "[Snipers] Reconciliation closing #{definition.id}/#{position.wallet_id}/#{position.token_address}: on-chain balance #{onchain_balance} (confirmed)"
          )

          close_position(position, now)

        {:ok, false} ->
          Logger.info(
            "[Snipers] Reconciliation zero-check recovered #{definition.id}/#{position.wallet_id}/#{position.token_address}; keeping position open"
          )

          {:ok, {position, 0}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp confirm_zero_balance(definition, %SniperPosition{} = position, %Token{} = token) do
    delay_ms = reconcile_zero_recheck_delay_ms()
    if delay_ms > 0, do: Process.sleep(delay_ms)

    case executor().token_balance(token, %{sniper_id: definition.id, wallet_id: position.wallet_id}) do
      {:ok, onchain_balance} when is_number(onchain_balance) and onchain_balance >= 0 ->
        {:ok, onchain_balance <= @epsilon}

      {:ok, onchain_balance} ->
        {:error, {:invalid_token_balance, onchain_balance}}

      {:error, reason} ->
        {:error, {:token_balance_check_failed, reason}}
    end
  end

  defp within_zero_close_grace?(%SniperPosition{opened_at: opened_at}, now)
       when is_struct(opened_at, NaiveDateTime) and is_struct(now, NaiveDateTime) do
    grace_seconds = reconcile_zero_close_grace_seconds()

    grace_seconds > 0 and
      NaiveDateTime.diff(now, opened_at, :second) >= 0 and
      NaiveDateTime.diff(now, opened_at, :second) < grace_seconds
  end

  defp within_zero_close_grace?(_position, _now), do: false

  defp close_position(%SniperPosition{} = position, now) do
    position
    |> SniperPosition.changeset(%{remaining_units: 0.0, status: "closed", closed_at: now})
    |> Repo.update()
    |> case do
      {:ok, updated_position} -> {:ok, {updated_position, 1}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_apply_risk_exits(definition, position, token, now) do
    cond do
      timeout_triggered?(definition, position, now) ->
        sell_all(definition, position, token, "timeout", now)

      stop_loss_triggered?(definition, position, token) ->
        sell_all(definition, position, token, "stop_loss", now)

      true ->
        {:ok, {position, 0, 0}}
    end
  end

  defp maybe_apply_tier_exits(_definition, %SniperPosition{status: "closed"}, _token, _now) do
    {:ok, {0, 0}}
  end

  defp maybe_apply_tier_exits(definition, position, token, now) do
    if is_nil(token.market_cap) do
      {:ok, {0, 0}}
    else
      executed_tiers = executed_tier_indices(position.id)

      definition.exit_tiers
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, {position, 0, 0}}, fn {tier, tier_index},
                                                      {:ok, {current_position, sells, closed}} ->
        cond do
          current_position.status == "closed" ->
            {:halt, {:ok, {current_position, sells, closed}}}

          tier.market_cap <= (current_position.entry_market_cap || 0) ->
            {:cont, {:ok, {current_position, sells, closed}}}

          MapSet.member?(executed_tiers, tier_index) ->
            {:cont, {:ok, {current_position, sells, closed}}}

          token.market_cap < tier.market_cap ->
            {:cont, {:ok, {current_position, sells, closed}}}

          true ->
            units_to_sell =
              calculate_tier_sell_units(definition.exit_tiers, tier_index, current_position)

            if units_to_sell <= @epsilon do
              {:cont, {:ok, {current_position, sells, closed}}}
            else
              case sell_units(definition, current_position, token, units_to_sell, tier_index, "exit_tier", now) do
                {:ok, updated_position} ->
                  closed_inc = if updated_position.status == "closed", do: 1, else: 0
                  {:cont, {:ok, {updated_position, sells + 1, closed + closed_inc}}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
            end
        end
      end)
      |> case do
        {:ok, {_position, sells, closed}} -> {:ok, {sells, closed}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp execute_buy(definition, token, wallet_id) do
    amount_usdc = definition.buy_config.position_size_usd
    amount_usdc_raw = usdc_to_base_units(amount_usdc)

    executor().buy(token, amount_usdc_raw, %{
      sniper_id: definition.id,
      wallet_id: wallet_id,
      trade_type: :buy,
      amount_usdc: amount_usdc,
      amount_usdc_raw: amount_usdc_raw,
      slippage_bps: definition.buy_config.slippage_bps,
      max_slippage_percent: definition.safety.max_slippage_percent
    })
  end

  defp normalize_units(%{units: units}) when is_number(units) and units > 0, do: {:ok, units}
  defp normalize_units(_result), do: {:error, :invalid_trade_units}

  defp persist_open_position(definition, notifier_id, token, wallet_id, units, buy_result, now) do
    attrs = %{
      sniper_id: definition.id,
      notifier_id: notifier_id,
      token_address: token.token_address,
      wallet_id: wallet_id,
      entry_market_cap: token.market_cap,
      position_size_usd: definition.buy_config.position_size_usd,
      initial_units: units,
      remaining_units: units,
      status: "open",
      opened_at: now
    }

    case %SniperPosition{} |> SniperPosition.changeset(attrs) |> Repo.insert() do
      {:ok, position} ->
        case insert_trade(position, %{
            trade_type: "buy",
            units: units,
            amount_usd: buy_result[:amount_usd] || definition.buy_config.position_size_usd,
            tx_signature: buy_result[:tx_signature],
            market_cap: token.market_cap,
            reason: "notifier_trigger",
            executed_at: now
          }) do
          :ok ->
            Logger.info(
              "[Snipers] Opened position #{position.id} #{definition.id}/#{wallet_id}/#{token.token_address}: units #{units}, tx #{inspect(buy_result[:tx_signature])}"
            )

            TelegramNotifier.notify_buy_success(definition, wallet_id, token, units)

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_open_position_error?(changeset) do
          :ok
        else
          {:error, changeset}
        end
    end
  end

  defp insert_trade(position, attrs) do
    attrs = Map.put(attrs, :sniper_position_id, position.id)

    case %SniperTrade{} |> SniperTrade.changeset(attrs) |> Repo.insert() do
      {:ok, _trade} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp timeout_triggered?(definition, position, now) do
    case definition.safety.timeout_hours do
      nil ->
        false

      timeout_hours when is_integer(timeout_hours) and timeout_hours > 0 ->
        NaiveDateTime.diff(now, position.opened_at, :second) >= timeout_hours * 3600
    end
  end

  defp stop_loss_triggered?(definition, position, token) do
    with stop_loss_percent when is_number(stop_loss_percent) <- definition.safety.stop_loss_percent,
         entry_market_cap when is_number(entry_market_cap) <- position.entry_market_cap,
         current_market_cap when is_number(current_market_cap) <- token.market_cap do
      current_market_cap <= entry_market_cap * (1 - stop_loss_percent / 100)
    else
      _ -> false
    end
  end

  defp sell_all(definition, position, token, reason, now) do
    if position.remaining_units <= @epsilon do
      {:ok, {position, 0, 0}}
    else
      case sell_units(definition, position, token, position.remaining_units, nil, reason, now) do
        {:ok, updated_position} -> {:ok, {updated_position, 1, 1}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp sell_units(definition, position, token, units, tier_index, reason, now) do
    case executor().sell(token, units, %{
           sniper_id: definition.id,
           wallet_id: position.wallet_id,
           trade_type: :sell,
           slippage_bps: definition.buy_config.slippage_bps,
           max_slippage_percent: definition.safety.max_slippage_percent
         }) do
      {:ok, sell_result} ->
        sold_units = normalize_sold_units(sell_result, units)
        remaining_units = max(position.remaining_units - sold_units, 0.0)
        status = if remaining_units <= @epsilon, do: "closed", else: "open"

        close_time = if status == "closed", do: now, else: position.closed_at

        Repo.transaction(fn ->
          {:ok, updated_position} =
            position
            |> SniperPosition.changeset(%{
              remaining_units: remaining_units,
              status: status,
              closed_at: close_time
            })
            |> Repo.update()

          :ok =
            insert_trade(updated_position, %{
              trade_type: "sell",
              tier_index: tier_index,
              units: sold_units,
              amount_usd: sell_result[:amount_usd],
              tx_signature: sell_result[:tx_signature],
              market_cap: token.market_cap,
              reason: reason,
              executed_at: now
            })

          updated_position
        end)
        |> case do
          {:ok, updated_position} ->
            Logger.info(
              "[Snipers] Sold #{sold_units} units for #{definition.id}/#{position.wallet_id}/#{position.token_address} (tier #{inspect(tier_index)}, reason #{reason}), remaining #{updated_position.remaining_units}, status #{updated_position.status}, tx #{inspect(sell_result[:tx_signature])}"
            )

            TelegramNotifier.notify_sell_success(definition, position.wallet_id, token, sold_units)

            {:ok, updated_position}

          {:error, reason} ->
            TelegramNotifier.notify_sell_failure(definition, position.wallet_id, token, reason)
            {:error, reason}
        end

      {:error, reason} ->
        TelegramNotifier.notify_sell_failure(definition, position.wallet_id, token, reason)
        {:error, reason}
    end
  end

  defp normalize_sold_units(%{units: units}, fallback_units) when is_number(units) and units > 0 do
    min(units, fallback_units)
  end

  defp normalize_sold_units(_result, fallback_units), do: fallback_units

  defp calculate_tier_sell_units(exit_tiers, tier_index, %SniperPosition{} = position) do
    entry_market_cap = position.entry_market_cap || 0

    cumulative_sell_percent =
      exit_tiers
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {tier, index}, acc ->
        if index <= tier_index and tier.market_cap > entry_market_cap do
          acc + tier.sell_percent
        else
          acc
        end
      end)

    target_sold_units = position.initial_units * cumulative_sell_percent / 100
    already_sold_units = max(position.initial_units - position.remaining_units, 0.0)
    nominal_units = max(target_sold_units - already_sold_units, 0.0)
    bounded_units = min(position.remaining_units, nominal_units)

    # If this tier would consume ≥99.5% of what remains, sell all remaining units
    # to avoid leaving unredeemable dust that keeps the position open forever.
    if bounded_units >= position.remaining_units * 0.995 do
      position.remaining_units
    else
      bounded_units
    end
  end

  defp executed_tier_indices(position_id) do
    SniperTrade
    |> where([t], t.sniper_position_id == ^position_id and t.trade_type == "sell")
    |> where([t], not is_nil(t.tier_index))
    |> select([t], t.tier_index)
    |> Repo.all()
    |> MapSet.new()
  end

  defp ensure_position_limit(definition, wallet_id) do
    case definition.safety.max_position_count do
      nil ->
        :ok

      max_position_count ->
        current_open_count =
          SniperPosition
          |> where(
            [p],
            p.sniper_id == ^definition.id and p.wallet_id == ^wallet_id and p.status == "open"
          )
          |> Repo.aggregate(:count, :id)

        if current_open_count >= max_position_count do
          {:error, :max_position_count_reached}
        else
          :ok
        end
    end
  end

  defp ensure_min_wallet_usdc(definition, wallet_id) do
    case definition.buy_config.min_wallet_usdc do
      nil ->
        :ok

      min_wallet_usdc when is_number(min_wallet_usdc) and min_wallet_usdc > 0 ->
        case executor().wallet_usdc_balance(%{sniper_id: definition.id, wallet_id: wallet_id}) do
          {:ok, wallet_usdc_balance}
          when is_number(wallet_usdc_balance) and wallet_usdc_balance >= min_wallet_usdc ->
            :ok

          {:ok, wallet_usdc_balance} when is_number(wallet_usdc_balance) ->
            {:error, {:insufficient_wallet_usdc, wallet_usdc_balance, min_wallet_usdc}}

          {:ok, wallet_usdc_balance} ->
            {:error, {:invalid_wallet_usdc_balance, wallet_usdc_balance}}

          {:error, reason} ->
            maybe_log_wallet_usdc_rate_limit(definition, wallet_id, reason)
            {:error, {:wallet_usdc_balance_check_failed, reason}}
        end
    end
  end

  defp maybe_log_wallet_usdc_rate_limit(definition, wallet_id, reason) do
    if wallet_usdc_rate_limited?(reason) do
      Logger.warning(
        "[Snipers] wallet_usdc_balance rate limited for #{definition.id}/#{wallet_id}; retry backoff may delay trigger buy: #{inspect(reason)}"
      )
    end
  end

  defp wallet_usdc_rate_limited?(reason) do
    normalized =
      reason
      |> inspect(limit: :infinity)
      |> String.downcase()

    String.contains?(normalized, "429") or
      String.contains?(normalized, "rate limit") or
      String.contains?(normalized, "too many requests")
  end

  defp duplicate_open_position_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} when is_list(opts) ->
        opts[:constraint] == :unique and
          to_string(opts[:constraint_name]) in [
            "sniper_positions_sniper_id_token_address_index",
            "sniper_positions_sniper_id_wallet_id_token_address_index"
          ]

      _ ->
        false
    end)
  end

  defp normalize_wallet_id(wallet_id) do
    case String.trim(wallet_id) do
      "" -> {:error, :invalid_wallet_id}
      normalized_wallet_id -> {:ok, normalized_wallet_id}
    end
  end

  defp executor do
    Application.get_env(:bentley, :sniper_executor, Bentley.Snipers.Executor.Noop)
  end

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp reconcile_zero_close_grace_seconds do
    env_non_neg_integer(
      "SNIPER_RECONCILE_ZERO_CLOSE_GRACE_SECONDS",
      @default_reconcile_zero_close_grace_seconds
    )
  end

  defp reconcile_zero_recheck_delay_ms do
    env_non_neg_integer(
      "SNIPER_RECONCILE_ZERO_RECHECK_DELAY_MS",
      @default_reconcile_zero_recheck_delay_ms
    )
  end

  defp env_non_neg_integer(name, default) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp usdc_to_base_units(amount_usdc) when is_number(amount_usdc) and amount_usdc > 0 do
    amount_usdc
    |> to_string()
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(@usdc_base_unit_scale))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end
end

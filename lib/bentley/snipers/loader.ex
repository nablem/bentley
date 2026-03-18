defmodule Bentley.Snipers.Loader do
  @moduledoc false

  alias Bentley.Snipers.Definition

  @default_interval_seconds 120

  @spec load_from_config() :: {:ok, [Definition.t()]} | {:error, term()}
  def load_from_config do
    Application.get_env(:bentley, :snipers_file_path)
    |> load_from_file()
  end

  @spec load_from_file(String.t() | nil) :: {:ok, [Definition.t()]} | {:error, term()}
  def load_from_file(nil), do: {:ok, []}
  def load_from_file(""), do: {:ok, []}

  def load_from_file(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, document} -> parse_document(document)
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  end

  defp parse_document(document) do
    with {:ok, entries} <- extract_entries(document),
         {:ok, definitions} <- parse_entries(entries),
         :ok <- validate_unique_ids(definitions) do
      {:ok, definitions}
    end
  end

  defp extract_entries(entries) when is_list(entries), do: {:ok, entries}
  defp extract_entries(%{"snipers" => entries}) when is_list(entries), do: {:ok, entries}
  defp extract_entries(_document), do: {:error, :invalid_sniper_document}

  defp parse_entries(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case parse_entry(entry, index) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      error -> error
    end
  end

  defp parse_entry(entry, index) when is_map(entry) do
    with {:ok, id} <- fetch_required_string(entry, "id", index),
         {:ok, enabled} <- fetch_boolean(entry, "enabled", true),
         {:ok, wallet_ids} <- fetch_wallet_ids(entry, id),
         {:ok, trigger_on_notifier_ids} <- fetch_trigger_on_notifiers(entry, id),
         {:ok, poll_interval_ms} <- fetch_poll_interval_ms(entry, id),
         {:ok, buy_config} <- parse_buy_config(Map.get(entry, "buy_config", %{}), id),
         {:ok, exit_tiers} <- parse_exit_tiers(Map.get(entry, "exit_tiers"), id),
         {:ok, safety} <- parse_safety(Map.get(entry, "safety", %{}), id) do
      {:ok,
       %Definition{
         id: id,
         enabled: enabled,
         wallet_ids: wallet_ids,
         trigger_on_notifier_ids: trigger_on_notifier_ids,
         poll_interval_ms: poll_interval_ms,
         buy_config: buy_config,
         exit_tiers: exit_tiers,
         safety: safety
       }}
    end
  end

  defp parse_entry(_entry, index), do: {:error, {:invalid_sniper_entry, index}}

  defp fetch_wallet_ids(entry, id) do
    cond do
      Map.has_key?(entry, "wallet_ids") ->
        parse_wallet_ids(Map.get(entry, "wallet_ids"), id)

      Map.has_key?(entry, "wallet_id") ->
        with {:ok, wallet_id} <- fetch_required_string(entry, "wallet_id", id) do
          {:ok, [wallet_id]}
        end

      true ->
        {:error, {:missing_required_field, id, "wallet_ids"}}
    end
  end

  defp parse_wallet_ids(wallet_ids, id) when is_list(wallet_ids) do
    wallet_ids
    |> Enum.reduce_while({:ok, []}, fn wallet_id, {:ok, acc} ->
      case normalize_wallet_id(wallet_id, id) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, {:missing_required_field, id, "wallet_ids"}}
      {:ok, parsed_wallet_ids} -> {:ok, parsed_wallet_ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp parse_wallet_ids(_wallet_ids, id), do: {:error, {:invalid_wallet_ids, id}}

  defp normalize_wallet_id(wallet_id, id) when is_binary(wallet_id) do
    case String.trim(wallet_id) do
      "" -> {:error, {:invalid_wallet_id, id, wallet_id}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_wallet_id(_wallet_id, id), do: {:error, {:invalid_wallet_ids, id}}

  defp fetch_trigger_on_notifiers(entry, id) do
    case Map.get(entry, "trigger_on_notifiers", []) do
      nil -> {:ok, []}
      notifier_id when is_binary(notifier_id) -> parse_trigger_notifier_ids([notifier_id], id)
      notifier_ids when is_list(notifier_ids) -> parse_trigger_notifier_ids(notifier_ids, id)
      _ -> {:error, {:invalid_trigger_on_notifiers, id}}
    end
  end

  defp parse_trigger_notifier_ids(notifier_ids, id) do
    notifier_ids
    |> Enum.reduce_while({:ok, []}, fn notifier_id, {:ok, acc} ->
      case normalize_notifier_id(notifier_id, id) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_ids} -> {:ok, normalized_ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_notifier_id(notifier_id, id) when is_binary(notifier_id) do
    case String.trim(notifier_id) do
      "" -> {:error, {:invalid_trigger_on_notifier_id, id, notifier_id}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_notifier_id(_notifier_id, id),
    do: {:error, {:invalid_trigger_on_notifiers, id}}

  defp fetch_poll_interval_ms(entry, id) do
    with {:ok, seconds} <-
           fetch_positive_integer(entry, "poll_interval_seconds", @default_interval_seconds, id) do
      {:ok, :timer.seconds(seconds)}
    end
  end

  defp parse_buy_config(nil, _id), do: {:ok, Definition.default_buy_config()}

  defp parse_buy_config(config, id) when is_map(config) do
    defaults = Definition.default_buy_config()

    with {:ok, enabled} <- fetch_boolean(config, "enabled", defaults.enabled),
         {:ok, position_size_usd} <-
           fetch_positive_number(config, "position_size_usd", defaults.position_size_usd, id),
         {:ok, slippage_bps} <-
           fetch_positive_integer(config, "slippage_bps", defaults.slippage_bps, id),
         {:ok, min_wallet_usdc} <-
           fetch_optional_positive_number(config, "min_wallet_usdc", defaults.min_wallet_usdc, id) do
      {:ok,
       %{
         enabled: enabled,
         position_size_usd: position_size_usd,
         slippage_bps: slippage_bps,
         min_wallet_usdc: min_wallet_usdc
       }}
    end
  end

  defp parse_buy_config(_config, id), do: {:error, {:invalid_buy_config, id}}

  defp parse_exit_tiers(nil, id), do: {:error, {:missing_exit_tiers, id}}

  defp parse_exit_tiers(exit_tiers, id) when is_list(exit_tiers) do
    with {:ok, parsed_tiers} <- parse_exit_tier_entries(exit_tiers, id),
         :ok <- validate_exit_tiers_not_empty(parsed_tiers, id),
         :ok <- validate_exit_tier_sell_percent_total(parsed_tiers, id) do
      {:ok, parsed_tiers}
    end
  end

  defp parse_exit_tiers(_exit_tiers, id), do: {:error, {:invalid_exit_tiers, id}}

  defp parse_exit_tier_entries(exit_tiers, id) do
    exit_tiers
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, tier_index}, {:ok, acc} ->
      case parse_exit_tier(entry, id, tier_index) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed_tiers} -> {:ok, Enum.reverse(parsed_tiers)}
      error -> error
    end
  end

  defp parse_exit_tier(entry, id, tier_index) when is_map(entry) do
    with {:ok, market_cap} <- fetch_positive_number(entry, "market_cap", nil, id),
         {:ok, sell_percent} <- fetch_positive_number(entry, "sell_percent", nil, id),
         :ok <- validate_percent_le_100(sell_percent, id, {:exit_tier_sell_percent, tier_index}) do
      {:ok, %{market_cap: market_cap, sell_percent: sell_percent}}
    else
      {:error, {:invalid_positive_number, ^id, _field}} ->
        {:error, {:invalid_exit_tier, id, tier_index}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_exit_tier(_entry, id, tier_index), do: {:error, {:invalid_exit_tier, id, tier_index}}

  defp validate_exit_tiers_not_empty([], id), do: {:error, {:missing_exit_tiers, id}}
  defp validate_exit_tiers_not_empty(_exit_tiers, _id), do: :ok

  defp validate_exit_tier_sell_percent_total(exit_tiers, id) do
    total = Enum.reduce(exit_tiers, 0, fn tier, acc -> acc + tier.sell_percent end)

    if total > 100 do
      {:error, {:invalid_exit_tier_sell_percent_total, id, total}}
    else
      :ok
    end
  end

  defp parse_safety(nil, _id), do: {:ok, Definition.default_safety()}

  defp parse_safety(safety, id) when is_map(safety) do
    defaults = Definition.default_safety()

    with {:ok, max_slippage_percent} <-
           fetch_optional_percent(
             safety,
             "max_slippage_percent",
             defaults.max_slippage_percent,
             id
           ),
         {:ok, max_position_count} <-
           fetch_optional_positive_integer(
             safety,
             "max_position_count",
             defaults.max_position_count,
             id
           ),
         {:ok, stop_loss_percent} <-
           fetch_optional_percent(safety, "stop_loss_percent", defaults.stop_loss_percent, id),
         {:ok, timeout_hours} <-
           fetch_optional_positive_integer(safety, "timeout_hours", defaults.timeout_hours, id) do
      {:ok,
       %{
         max_slippage_percent: max_slippage_percent,
         max_position_count: max_position_count,
         stop_loss_percent: stop_loss_percent,
         timeout_hours: timeout_hours
       }}
    end
  end

  defp parse_safety(_safety, id), do: {:error, {:invalid_safety, id}}

  defp fetch_required_string(entry, key, context) do
    case Map.get(entry, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, {:missing_required_field, context, key}}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_required_field, context, key}}
    end
  end

  defp fetch_boolean(entry, key, default) do
    case Map.get(entry, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_boolean, key}}
    end
  end

  defp fetch_positive_integer(entry, key, default, context) do
    case Map.get(entry, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, context, key}}
    end
  end

  defp fetch_optional_positive_integer(entry, key, default, context) do
    case Map.get(entry, key, default) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, context, key}}
    end
  end

  defp fetch_positive_number(entry, key, nil, context) do
    case Map.get(entry, key) do
      value when is_number(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_number, context, key}}
    end
  end

  defp fetch_positive_number(entry, key, default, context) when is_number(default) do
    case Map.get(entry, key, default) do
      value when is_number(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_number, context, key}}
    end
  end

  defp fetch_optional_positive_number(entry, key, default, context) do
    case Map.get(entry, key, default) do
      nil -> {:ok, nil}
      value when is_number(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_number, context, key}}
    end
  end

  defp fetch_optional_percent(entry, key, default, context) do
    case Map.get(entry, key, default) do
      nil -> {:ok, nil}
      value when is_number(value) and value > 0 and value <= 100 -> {:ok, value}
      _ -> {:error, {:invalid_percent, context, key}}
    end
  end

  defp validate_percent_le_100(value, _context, _key) when is_number(value) and value <= 100,
    do: :ok
  defp validate_percent_le_100(_value, context, key), do: {:error, {:invalid_percent, context, key}}

  defp validate_unique_ids(definitions) do
    definitions
    |> Enum.group_by(& &1.id)
    |> Enum.find_value(fn
      {_id, [_single]} -> nil
      {id, _definitions} -> {:error, {:duplicate_sniper_id, id}}
    end)
    |> case do
      nil -> :ok
      error -> error
    end
  end
end

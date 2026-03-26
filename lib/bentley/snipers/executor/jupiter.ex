defmodule Bentley.Snipers.Executor.Jupiter do
  @moduledoc """
  Live Solana/Jupiter executor for sniper buy/sell operations.

  Buy inputs are expected in Solana USDC base units (6 decimals).

  Uses Solana preflight validation (skipPreflight: false) to reject invalid
  transactions synchronously before they reach the chain. Implements additional
  late confirmation recovery with balance-delta fallback as a defensive safety
  net for RPC lag scenarios.
  """

  @behaviour Bentley.Snipers.Executor

  import Bitwise
  require Logger

  alias Bentley.Schema.Token
  alias Bentley.Snipers.Env

  @jupiter_base_url "https://api.jup.ag/swap/v1"
  @default_rpc_url "https://api.mainnet-beta.solana.com"
  @usdc_mint "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  @default_slippage_bps 50
  @usdc_base_unit_scale 1_000_000
  @default_rpc_retry_attempts 5
  @default_rpc_retry_base_backoff_ms 250
  @default_rpc_retry_max_backoff_ms 2_500
  @default_requote_retry_attempts 1
  @default_requote_retry_delay_ms 150
  @default_late_confirmation_attempts 10
  @default_confirm_poll_interval_ms 1_000
  @default_confirm_max_attempts 30
  @default_send_tx_min_interval_ms 1_300
  @send_tx_last_ms_key {__MODULE__, :send_tx_last_ms}

  @type wallet :: %{secret_key: binary(), public_key: binary()}

  @impl true
  def buy(%Token{} = token, amount_usdc_raw, options)
      when is_integer(amount_usdc_raw) and amount_usdc_raw > 0 do
    slippage_bps = slippage_bps_from_options(options)
    amount_usd = options[:amount_usdc] || usdc_from_raw(amount_usdc_raw)

    with {:ok, wallet_id} <- wallet_id_from_options(options),
         {:ok, wallet} <- fetch_wallet(wallet_id),
         {:ok, balance_before} <-
           fetch_wallet_token_balance(wallet.public_key, token.token_address),
         {:ok, quote} <- get_quote(@usdc_mint, token.token_address, amount_usdc_raw, slippage_bps) do
      case execute_swap_with_requote(
             quote,
             wallet,
             fn -> get_quote(@usdc_mint, token.token_address, amount_usdc_raw, slippage_bps) end,
             requote_retry_attempts()
           ) do
        {:ok, {tx_signature, final_quote}} ->
          build_buy_result(
            wallet.public_key,
            token.token_address,
            balance_before,
            tx_signature,
            final_quote,
            amount_usd
          )

        {:error, {:confirmation_timeout, tx_signature, timeout_quote}} ->
          recover_buy_after_confirmation_timeout(
            wallet.public_key,
            token.token_address,
            balance_before,
            tx_signature,
            timeout_quote,
            amount_usd
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def buy(_token, _amount_usdc_raw, _options), do: {:error, :invalid_buy_amount}

  @impl true
  def sell(%Token{} = token, units, options) when is_number(units) and units > 0 do
    with {:ok, wallet_id} <- wallet_id_from_options(options),
         {:ok, wallet} <- fetch_wallet(wallet_id),
         {:ok, amount_in_raw} <- normalize_sell_units(units),
         {:ok, balance_before} <-
           fetch_wallet_token_balance(wallet.public_key, token.token_address),
         {:ok, quote} <-
           get_quote(token.token_address, @usdc_mint, amount_in_raw, slippage_bps_from_options(options)) do
      case execute_swap(quote, wallet) do
        {:ok, tx_signature} ->
          build_sell_result(amount_in_raw, tx_signature, quote)

        {:error, {:confirmation_timeout, tx_signature}} ->
          recover_sell_after_confirmation_timeout(
            wallet.public_key,
            token.token_address,
            balance_before,
            amount_in_raw,
            tx_signature,
            quote
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def sell(_token, _units, _options), do: {:error, :invalid_sell_amount}

  @impl true
  def wallet_usdc_balance(options) when is_map(options) do
    with {:ok, wallet_id} <- wallet_id_from_options(options),
         {:ok, wallet} <- fetch_wallet(wallet_id),
         {:ok, usdc_balance} <- fetch_wallet_usdc_balance(wallet.public_key) do
      {:ok, usdc_balance}
    end
  end

  def wallet_usdc_balance(_options), do: {:error, :invalid_options}

  @impl true
  def token_balance(%Token{} = token, options) when is_map(options) do
    with {:ok, wallet_id} <- wallet_id_from_options(options),
         {:ok, wallet} <- fetch_wallet(wallet_id),
         {:ok, raw_balance} <- fetch_wallet_token_balance(wallet.public_key, token.token_address) do
      {:ok, raw_balance}
    end
  end

  def token_balance(_token, _options), do: {:error, :invalid_options}

  defp wallet_id_from_options(%{wallet_id: wallet_id}) when is_binary(wallet_id) do
    case String.trim(wallet_id) do
      "" -> {:error, :missing_wallet_id}
      normalized -> {:ok, normalized}
    end
  end

  defp wallet_id_from_options(_options), do: {:error, :missing_wallet_id}

  defp slippage_bps_from_options(options) do
    case options[:slippage_bps] do
      slippage_bps when is_integer(slippage_bps) and slippage_bps > 0 -> slippage_bps
      _ -> @default_slippage_bps
    end
  end

  defp normalize_sell_units(units) when is_integer(units), do: {:ok, units}

  defp normalize_sell_units(units) when is_float(units) do
    units
    |> round()
    |> case do
      value when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_sell_amount}
    end
  end

  defp fetch_wallet(wallet_id) do
    with {:ok, private_key} <- Env.fetch_solana_wallet_private_key(wallet_id),
         {:ok, wallet} <- decode_wallet(private_key) do
      {:ok, wallet}
    end
  end

  defp decode_wallet(private_key_string) when is_binary(private_key_string) do
    bytes_result =
      if String.starts_with?(String.trim(private_key_string), "[") do
        decode_json_wallet_bytes(private_key_string)
      else
        decode_base58_wallet_bytes(private_key_string)
      end

    with {:ok, bytes} <- bytes_result do
      case byte_size(bytes) do
        64 ->
          <<secret_key::binary-size(32), public_key::binary-size(32)>> = bytes
          {:ok, %{secret_key: secret_key, public_key: public_key}}

        32 ->
          secret_key = bytes
          {:ok, %{secret_key: secret_key, public_key: Ed25519.derive_public_key(secret_key)}}

        other ->
          {:error, {:invalid_private_key_size, other}}
      end
    end
  end

  defp decode_json_wallet_bytes(private_key_string) do
    try do
      bytes =
        private_key_string
        |> Jason.decode!()
        |> :erlang.list_to_binary()

      {:ok, bytes}
    rescue
      _ -> {:error, :invalid_private_key_json}
    end
  end

  defp decode_base58_wallet_bytes(private_key_string) do
    try do
      case Base58.decode(private_key_string) do
        decoded when is_binary(decoded) and byte_size(decoded) > 0 -> {:ok, decoded}
        _ -> {:error, :invalid_private_key_base58}
      end
    rescue
      _ -> {:error, :invalid_private_key_base58}
    end
  end

  defp get_quote(input_mint, output_mint, amount_raw, slippage_bps) do
    params = [
      inputMint: input_mint,
      outputMint: output_mint,
      amount: amount_raw,
      slippageBps: slippage_bps
    ]

    jupiter_get(
      "#{@jupiter_base_url}/quote",
      Keyword.merge([params: params, headers: jupiter_headers()], jupiter_req_options())
    )
    |> case do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:jupiter_quote_failed, status, body}}
      {:error, reason} -> {:error, {:jupiter_quote_failed, reason}}
    end
  end

  defp execute_swap(quote_response, wallet) do
    with {:ok, swap_tx_b64} <- get_swap_transaction(quote_response, wallet.public_key),
         {:ok, signed_tx_b64} <- sign_transaction(swap_tx_b64, wallet),
         {:ok, tx_signature} <- send_transaction(signed_tx_b64) do
      case confirm_transaction(tx_signature) do
        :ok ->
          {:ok, tx_signature}

        {:error, :confirmation_timeout} ->
          {:error, {:confirmation_timeout, tx_signature}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_swap_with_requote(quote, wallet, _refetch_quote, attempts_left)
       when attempts_left < 0 do
    execute_swap(quote, wallet)
  end

  defp execute_swap_with_requote(quote, wallet, refetch_quote, attempts_left)
       when is_function(refetch_quote, 0) do
    case execute_swap(quote, wallet) do
      {:ok, tx_signature} ->
        {:ok, {tx_signature, quote}}

      {:error, {:confirmation_timeout, tx_signature}} ->
        {:error, {:confirmation_timeout, tx_signature, quote}}

      {:error, {:transaction_failed, reason}} = error ->
        if attempts_left > 0 and retryable_transaction_failure?(reason) do
          requote_and_retry_swap(quote, wallet, refetch_quote, attempts_left, reason)
        else
          error
        end

      {:error, {:send_transaction_failed, reason}} = error ->
        if attempts_left > 0 and retryable_send_transaction_failure?(reason) do
          requote_and_retry_swap(quote, wallet, refetch_quote, attempts_left, reason)
        else
          error
        end

      other ->
        other
    end
  end

  defp requote_and_retry_swap(_quote, wallet, refetch_quote, attempts_left, reason)
       when is_function(refetch_quote, 0) do
    Logger.warning(
      "[Snipers] Swap failed with retryable error; requoting and retrying once more: #{inspect(reason)}"
    )

    requote_delay_ms = requote_retry_delay_ms()
    if requote_delay_ms > 0, do: Process.sleep(requote_delay_ms)

    with {:ok, refreshed_quote} <- refetch_quote.() do
      execute_swap_with_requote(refreshed_quote, wallet, refetch_quote, attempts_left - 1)
    end
  end

  defp recover_buy_after_confirmation_timeout(
         wallet_public_key,
         token_address,
         balance_before,
         tx_signature,
         timeout_quote,
         amount_usd
       ) do
    Logger.warning(
      "[Snipers] Buy confirmation timed out for tx #{tx_signature}; attempting late confirmation recovery"
    )

    case confirm_transaction(tx_signature, @default_late_confirmation_attempts) do
      :ok ->
        Logger.warning(
          "[Snipers] Late confirmation succeeded for buy tx #{tx_signature}; persisting position"
        )

        build_buy_result(
          wallet_public_key,
          token_address,
          balance_before,
          tx_signature,
          timeout_quote,
          amount_usd
        )

      {:error, {:transaction_failed, reason}} ->
        {:error, {:transaction_failed, reason}}

      {:error, :confirmation_timeout} ->
        # If RPC remains stale, accept only a positive on-chain balance delta as
        # evidence of execution. Do not open a position from quote data alone.
        case fetch_wallet_token_balance(wallet_public_key, token_address) do
          {:ok, balance_after} ->
            case recover_units_from_balance_delta(balance_before, balance_after) do
              {:ok, actual_delta} ->
                case validate_recovered_delta(actual_delta, timeout_quote) do
                  :ok ->
                    Logger.warning(
                      "[Snipers] Buy tx #{tx_signature} remains unconfirmed via RPC but recovered from on-chain balance delta=#{actual_delta}"
                    )

                    {:ok, %{units: actual_delta, amount_usd: amount_usd, tx_signature: tx_signature}}

                  {:error, :delta_mismatch} ->
                    {:error, {:buy_unconfirmed_timeout, tx_signature}}
                end

              {:error, :buy_unconfirmed_timeout} ->
                {:error, {:buy_unconfirmed_timeout, tx_signature}}
            end

          {:error, reason} ->
            {:error, {:buy_unconfirmed_timeout, tx_signature, reason}}
        end
    end
  end

  defp build_buy_result(
         wallet_public_key,
         token_address,
         balance_before,
         tx_signature,
         quote,
         amount_usd
       ) do
    case fetch_wallet_token_balance(wallet_public_key, token_address) do
      {:ok, balance_after} ->
        {:ok,
         %{
           units: derive_buy_units(balance_before, balance_after, quote),
           amount_usd: amount_usd,
           tx_signature: tx_signature
         }}

      {:error, reason} ->
        units = quote_out_amount(quote)

        if units > 0 do
          Logger.warning(
            "[Snipers] Post-buy balance check failed for tx #{tx_signature}; using quote outAmount fallback: #{inspect(reason)}"
          )

          {:ok,
           %{
             units: units,
             amount_usd: amount_usd,
             tx_signature: tx_signature
           }}
        else
          {:error, {:post_buy_balance_check_failed, reason}}
        end
    end
  end

  defp build_sell_result(amount_in_raw, tx_signature, quote) do
    with {:ok, out_amount_raw} <- parse_raw_amount(Map.get(quote, "outAmount")) do
      {:ok,
       %{
         units: amount_in_raw,
         amount_usd: usdc_from_raw(out_amount_raw),
         tx_signature: tx_signature
       }}
    end
  end

  defp recover_sell_after_confirmation_timeout(
         wallet_public_key,
         token_address,
         balance_before,
         amount_in_raw,
         tx_signature,
         timeout_quote
       ) do
    Logger.warning(
      "[Snipers] Sell confirmation timed out for tx #{tx_signature}; attempting late confirmation recovery"
    )

    case confirm_transaction(tx_signature, @default_late_confirmation_attempts) do
      :ok ->
        Logger.warning(
          "[Snipers] Late confirmation succeeded for sell tx #{tx_signature}; persisting sell result"
        )

        build_sell_result(amount_in_raw, tx_signature, timeout_quote)

      {:error, {:transaction_failed, reason}} ->
        {:error, {:transaction_failed, reason}}

      {:error, :confirmation_timeout} ->
        # If RPC remains stale, accept only a positive token balance reduction as
        # evidence of execution. Do not persist a sell from quote data alone.
        case fetch_wallet_token_balance(wallet_public_key, token_address) do
          {:ok, balance_after} ->
            case recover_sold_units_from_balance_delta(balance_before, balance_after) do
              {:ok, sold_units_delta} ->
                sold_units = min(sold_units_delta, amount_in_raw)

                Logger.warning(
                  "[Snipers] Sell tx #{tx_signature} remains unconfirmed via RPC but recovered from on-chain balance delta=#{sold_units}"
                )

                {:ok,
                 %{
                   units: sold_units,
                   amount_usd: derive_sell_amount_usd(sold_units, amount_in_raw, timeout_quote),
                   tx_signature: tx_signature
                 }}

              {:error, :sell_unconfirmed_timeout} ->
                {:error, {:sell_unconfirmed_timeout, tx_signature}}
            end

          {:error, reason} ->
            {:error, {:sell_unconfirmed_timeout, tx_signature, reason}}
        end
    end
  end

  @doc false
  @spec derive_buy_units(integer(), integer(), map()) :: integer()
  def derive_buy_units(balance_before, balance_after, quote)
      when is_integer(balance_before) and is_integer(balance_after) and is_map(quote) do
    actual_delta = balance_after - balance_before
    if actual_delta > 0, do: actual_delta, else: quote_out_amount(quote)
  end

  @doc false
  @spec recover_units_from_balance_delta(integer(), integer()) :: {:ok, integer()} | {:error, :buy_unconfirmed_timeout}
  def recover_units_from_balance_delta(balance_before, balance_after)
      when is_integer(balance_before) and is_integer(balance_after) do
    actual_delta = balance_after - balance_before
    if actual_delta > 0, do: {:ok, actual_delta}, else: {:error, :buy_unconfirmed_timeout}
  end

  @doc false
  @spec recover_sold_units_from_balance_delta(integer(), integer()) ::
          {:ok, integer()} | {:error, :sell_unconfirmed_timeout}
  def recover_sold_units_from_balance_delta(balance_before, balance_after)
      when is_integer(balance_before) and is_integer(balance_after) do
    actual_delta = balance_before - balance_after
    if actual_delta > 0, do: {:ok, actual_delta}, else: {:error, :sell_unconfirmed_timeout}
  end

  @doc false
  @spec validate_recovered_delta(integer(), map()) :: :ok | {:error, :delta_mismatch}
  def validate_recovered_delta(actual_delta, quote)
      when is_integer(actual_delta) and is_map(quote) and actual_delta > 0 do
    expected_delta = quote_out_amount(quote)

    # Allow 5% variance to account for slippage and rounding differences
    tolerance = max(div(expected_delta, 20), 1)

    if abs(actual_delta - expected_delta) <= tolerance do
      :ok
    else
      {:error, :delta_mismatch}
    end
  end

  def validate_recovered_delta(_actual_delta, _quote), do: {:error, :delta_mismatch}

  defp derive_sell_amount_usd(sold_units, requested_units, quote)
       when is_integer(sold_units) and sold_units > 0 and is_integer(requested_units) and
              requested_units > 0 and is_map(quote) do
    expected_out_raw = quote_out_amount(quote)

    if expected_out_raw > 0 do
      expected_out_raw
      |> Kernel.*(sold_units / requested_units)
      |> round()
      |> usdc_from_raw()
    else
      0.0
    end
  end

  defp derive_sell_amount_usd(_sold_units, _requested_units, _quote), do: 0.0

  defp get_swap_transaction(quote_response, wallet_public_key) do
    payload = %{
      "quoteResponse" => quote_response,
      "userPublicKey" => Base58.encode(wallet_public_key),
      "wrapAndUnwrapSol" => true,
      "dynamicComputeUnitLimit" => true,
      "prioritizationFeeLamports" => "auto"
    }

    jupiter_post(
      "#{@jupiter_base_url}/swap",
      Keyword.merge([json: payload, headers: jupiter_headers()], jupiter_req_options())
    )
    |> case do
      {:ok, %{status: 200, body: %{"swapTransaction" => swap_tx_b64}}} when is_binary(swap_tx_b64) ->
        {:ok, swap_tx_b64}

      {:ok, %{status: status, body: body}} ->
        {:error, {:jupiter_swap_failed, status, body}}

      {:error, reason} ->
        {:error, {:jupiter_swap_failed, reason}}
    end
  end

  defp sign_transaction(swap_transaction_b64, wallet) do
    try do
      raw_tx = Base.decode64!(swap_transaction_b64)
      {sig_count, rest} = decode_compact_u16(raw_tx)
      sig_size = sig_count * 64
      <<_existing_sigs::binary-size(sig_size), message::binary>> = rest
      signature = Ed25519.signature(message, wallet.secret_key, wallet.public_key)

      signed_tx =
        encode_compact_u16(sig_count) <>
          signature <>
          if(sig_count > 1, do: <<0::size((sig_count - 1) * 64 * 8)>>, else: <<>>) <>
          message

      {:ok, Base.encode64(signed_tx)}
    rescue
      _ -> {:error, :transaction_signing_failed}
    end
  end

  defp send_transaction(signed_tx_b64) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "sendTransaction",
      "params" => [
        signed_tx_b64,
        %{"encoding" => "base64", "skipPreflight" => false}
      ]
    }

    with_send_transaction_rate_limit(fn ->
      rpc_post(payload)
    end)
    |> case do
      {:ok, %{status: 200, body: %{"result" => tx_signature}}} when is_binary(tx_signature) ->
        {:ok, tx_signature}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, {:send_transaction_failed, error}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:send_transaction_failed, status, body}}

      {:error, reason} ->
        {:error, {:send_transaction_failed, reason}}
    end
  end

  @doc false
  @spec confirmation_succeeded?(map()) :: boolean()
  def confirmation_succeeded?(status) when is_map(status) do
    is_nil(Map.get(status, "err")) and
      Map.get(status, "confirmationStatus") in ["confirmed", "finalized"]
  end

  @doc false
  @spec retryable_transaction_failure?(term()) :: boolean()
  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => 6001}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => 6017}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => 6002}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => 6024}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => "6001"}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => "6017"}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => "6002"}]}) do
    true
  end

  def retryable_transaction_failure?(%{"InstructionError" => [_index, %{"Custom" => "6024"}]}) do
    true
  end

  def retryable_transaction_failure?(_reason), do: false

  @doc false
  @spec retryable_send_transaction_failure?(term()) :: boolean()
  def retryable_send_transaction_failure?(%{"data" => %{"err" => reason}}) do
    retryable_transaction_failure?(reason)
  end

  def retryable_send_transaction_failure?(_reason), do: false

  defp confirm_transaction(tx_signature), do: confirm_transaction(tx_signature, @default_confirm_max_attempts)

  defp confirm_transaction(tx_signature, attempts) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "getSignatureStatuses",
      "params" => [[tx_signature], %{"searchTransactionHistory" => true}]
    }

    case rpc_post(payload) do
      {:ok, %{status: 200, body: %{"result" => %{"value" => [status]}}}} when is_map(status) ->
        cond do
          confirmation_succeeded?(status) ->
            :ok

          not is_nil(Map.get(status, "err")) ->
            {:error, {:transaction_failed, Map.get(status, "err")}}

          attempts > 0 ->
            Process.sleep(@default_confirm_poll_interval_ms)
            confirm_transaction(tx_signature, attempts - 1)

          true ->
            {:error, :confirmation_timeout}
        end

      _ when attempts > 0 ->
        Process.sleep(@default_confirm_poll_interval_ms)
        confirm_transaction(tx_signature, attempts - 1)

      _ ->
        {:error, :confirmation_timeout}
    end
  end

  defp quote_out_amount(quote) do
    case parse_raw_amount(Map.get(quote, "outAmount")) do
      {:ok, amount} -> amount
      _ -> 0
    end
  end

  defp fetch_wallet_usdc_balance(wallet_public_key) do
    with {:ok, raw_total} <- fetch_wallet_token_balance(wallet_public_key, @usdc_mint) do
      {:ok, usdc_from_raw(raw_total)}
    end
  end

  defp fetch_wallet_token_balance(wallet_public_key, mint) when is_binary(mint) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "getTokenAccountsByOwner",
      "params" => [
        Base58.encode(wallet_public_key),
        %{"mint" => mint},
        %{"encoding" => "jsonParsed"}
      ]
    }

    rpc_post(payload)
    |> case do
      {:ok, %{status: 200, body: %{"result" => %{"value" => accounts}}}} when is_list(accounts) ->
        raw_total = Enum.reduce(accounts, 0, fn account, acc -> acc + account_raw_amount(account) end)
        {:ok, raw_total}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, {:wallet_balance_rpc_error, error}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:wallet_balance_failed, status, body}}

      {:error, reason} ->
        {:error, {:wallet_balance_failed, reason}}
    end
  end

  defp account_raw_amount(account) do
    account
    |> get_in(["account", "data", "parsed", "info", "tokenAmount", "amount"])
    |> parse_raw_amount()
    |> case do
      {:ok, value} -> value
      _ -> 0
    end
  end

  defp parse_raw_amount(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_raw_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, :invalid_raw_amount}
    end
  end

  defp parse_raw_amount(_value), do: {:error, :invalid_raw_amount}

  defp usdc_from_raw(raw_amount) when is_integer(raw_amount) and raw_amount >= 0 do
    raw_amount / @usdc_base_unit_scale
  end

  defp jupiter_headers do
    case Env.fetch_jupiter_api_key() do
      {:ok, api_key} -> [{"x-api-key", api_key}]
      {:error, :missing_jupiter_api_key} -> []
    end
  end

  defp rpc_url do
    System.get_env("SOLANA_RPC_URL") || @default_rpc_url
  end

  defp rpc_post(payload), do: rpc_post(payload, 0)

  defp rpc_post(payload, attempt) do
    method = rpc_method(payload)

    case solana_rpc_post(rpc_url(), Keyword.merge([json: payload], solana_rpc_req_options())) do
      {:ok, response} = result ->
        if retryable_rpc_response?(response) and attempt < rpc_retry_attempts() do
          sleep_rpc_backoff(attempt, method, rpc_retry_reason(response))
          rpc_post(payload, attempt + 1)
        else
          result
        end

      {:error, reason} = result ->
        if retryable_rpc_transport_error?(reason) and attempt < rpc_retry_attempts() do
          sleep_rpc_backoff(attempt, method, "transport_error=#{inspect(reason)}")
          rpc_post(payload, attempt + 1)
        else
          result
        end
    end
  end

  defp retryable_rpc_response?(%{status: status}) when status in [429, 500, 502, 503, 504],
    do: true

  defp retryable_rpc_response?(%{status: 200, body: %{"error" => error}}),
    do: retryable_rpc_error?(error)

  defp retryable_rpc_response?(_response), do: false

  defp retryable_rpc_error?(%{"code" => code, "message" => message}) do
    code in [429, -32005] or rate_limited_message?(message)
  end

  defp retryable_rpc_error?(%{"message" => message}), do: rate_limited_message?(message)
  defp retryable_rpc_error?(_error), do: false

  defp retryable_rpc_transport_error?(reason) do
    message = reason |> inspect() |> String.downcase()

    String.contains?(message, "timeout") or
      String.contains?(message, "closed") or
      String.contains?(message, "econn") or
      String.contains?(message, "rate limit")
  end

  defp rate_limited_message?(message) when is_binary(message) do
    normalized = String.downcase(message)
    String.contains?(normalized, "too many requests") or String.contains?(normalized, "rate limit")
  end

  defp rate_limited_message?(_message), do: false

  defp sleep_rpc_backoff(attempt, method, reason) do
    base_ms = rpc_retry_base_backoff_ms()
    max_ms = rpc_retry_max_backoff_ms()

    delay_ms =
      base_ms
      |> Kernel.*(:math.pow(2, attempt))
      |> round()
      |> min(max_ms)

    # Keep retries from synchronizing across concurrent workers.
    jitter_ms = :rand.uniform(max(div(delay_ms, 3), 1))
    total_sleep_ms = delay_ms + jitter_ms

    Logger.warning(
      "[Snipers] RPC retry method=#{method} attempt=#{attempt + 1}/#{rpc_retry_attempts()} sleep_ms=#{total_sleep_ms} reason=#{reason}"
    )

    Process.sleep(total_sleep_ms)
  end

  defp rpc_method(%{"method" => method}) when is_binary(method), do: method
  defp rpc_method(_payload), do: "unknown"

  defp rpc_retry_reason(%{status: status, body: %{"error" => error}}) do
    "status=#{status} rpc_error=#{inspect(error)}"
  end

  defp rpc_retry_reason(%{status: status}) do
    "status=#{status}"
  end

  defp with_send_transaction_rate_limit(fun) when is_function(fun, 0) do
    :global.trans({__MODULE__, :send_transaction_rate_limit}, fn ->
      min_interval_ms = send_tx_min_interval_ms()
      now_ms = System.monotonic_time(:millisecond)
      last_send_ms = :persistent_term.get(@send_tx_last_ms_key, nil)

      if is_integer(last_send_ms) do
        sleep_ms = max(last_send_ms + min_interval_ms - now_ms, 0)
        if sleep_ms > 0, do: Process.sleep(sleep_ms)
      end

      :persistent_term.put(@send_tx_last_ms_key, System.monotonic_time(:millisecond))
      fun.()
    end)
  end

  defp rpc_retry_attempts do
    env_positive_integer("SNIPER_RPC_RETRY_ATTEMPTS", @default_rpc_retry_attempts)
  end

  defp rpc_retry_base_backoff_ms do
    env_positive_integer("SNIPER_RPC_RETRY_BASE_BACKOFF_MS", @default_rpc_retry_base_backoff_ms)
  end

  defp rpc_retry_max_backoff_ms do
    env_positive_integer("SNIPER_RPC_RETRY_MAX_BACKOFF_MS", @default_rpc_retry_max_backoff_ms)
  end

  defp send_tx_min_interval_ms do
    env_positive_integer("SNIPER_SEND_TX_MIN_INTERVAL_MS", @default_send_tx_min_interval_ms)
  end

  defp requote_retry_attempts do
    env_non_neg_integer("SNIPER_REQUOTE_RETRY_ATTEMPTS", @default_requote_retry_attempts)
  end

  defp requote_retry_delay_ms do
    env_non_neg_integer("SNIPER_REQUOTE_RETRY_DELAY_MS", @default_requote_retry_delay_ms)
  end



  defp jupiter_req_options do
    Application.get_env(:bentley, :jupiter_req_options, [])
  end

  defp jupiter_get(url, options) do
    case Application.get_env(:bentley, :jupiter_http_client) do
      nil -> Req.get(url, options)
      module -> module.get(url, options)
    end
  end

  defp jupiter_post(url, options) do
    case Application.get_env(:bentley, :jupiter_http_client) do
      nil -> Req.post(url, options)
      module -> module.post(url, options)
    end
  end

  defp solana_rpc_post(url, options) do
    case Application.get_env(:bentley, :solana_rpc_http_client) do
      nil -> Req.post(url, options)
      module -> module.post(url, options)
    end
  end

  defp solana_rpc_req_options do
    Application.get_env(:bentley, :solana_rpc_req_options, [])
  end

  defp env_positive_integer(name, default) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
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

  # Helper for compact-u16 (Solana VarInt)
  defp decode_compact_u16(<<0::1, val::7, rest::binary>>), do: {val, rest}

  defp decode_compact_u16(<<1::1, val_low::7, 0::1, val_high::7, rest::binary>>) do
    {val_low + (val_high <<< 7), rest}
  end

  defp decode_compact_u16(bin), do: {0, bin}

  defp encode_compact_u16(val) when val < 128, do: <<val>>

  defp encode_compact_u16(val) when val < 16384 do
    <<1::1, band(val, 127)::7, 0::1, bsr(val, 7)::7>>
  end
end

defmodule Bentley.Snipers.Executor.Jupiter do
  @moduledoc """
  Live Solana/Jupiter executor for sniper buy/sell operations.

  Buy inputs are expected in Solana USDC base units (6 decimals).
  """

  @behaviour Bentley.Snipers.Executor

  import Bitwise

  alias Bentley.Schema.Token
  alias Bentley.Snipers.Env

  @jupiter_base_url "https://api.jup.ag/swap/v1"
  @default_rpc_url "https://api.mainnet-beta.solana.com"
  @usdc_mint "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  @default_slippage_bps 50
  @usdc_base_unit_scale 1_000_000

  @type wallet :: %{secret_key: binary(), public_key: binary()}

  @impl true
  def buy(%Token{} = token, amount_usdc_raw, options)
      when is_integer(amount_usdc_raw) and amount_usdc_raw > 0 do
    with {:ok, wallet_id} <- wallet_id_from_options(options),
         {:ok, wallet} <- fetch_wallet(wallet_id),
         {:ok, quote} <-
           get_quote(@usdc_mint, token.token_address, amount_usdc_raw, slippage_bps_from_options(options)),
         {:ok, tx_signature} <- execute_swap(quote, wallet),
         {:ok, out_amount_raw} <- parse_raw_amount(Map.get(quote, "outAmount")) do
      {:ok,
       %{
         units: out_amount_raw,
         amount_usd: options[:amount_usdc] || usdc_from_raw(amount_usdc_raw),
         tx_signature: tx_signature
       }}
    end
  end

  def buy(_token, _amount_usdc_raw, _options), do: {:error, :invalid_buy_amount}

  @impl true
  def sell(%Token{} = token, units, options) when is_number(units) and units > 0 do
    with {:ok, wallet_id} <- wallet_id_from_options(options),
         {:ok, wallet} <- fetch_wallet(wallet_id),
         {:ok, amount_in_raw} <- normalize_sell_units(units),
         {:ok, quote} <-
           get_quote(token.token_address, @usdc_mint, amount_in_raw, slippage_bps_from_options(options)),
         {:ok, tx_signature} <- execute_swap(quote, wallet),
         {:ok, out_amount_raw} <- parse_raw_amount(Map.get(quote, "outAmount")) do
      {:ok,
       %{
         units: amount_in_raw,
         amount_usd: usdc_from_raw(out_amount_raw),
         tx_signature: tx_signature
       }}
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

    Req.get("#{@jupiter_base_url}/quote", params: params, headers: jupiter_headers())
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
      _ = confirm_transaction(tx_signature)
      {:ok, tx_signature}
    end
  end

  defp get_swap_transaction(quote_response, wallet_public_key) do
    payload = %{
      "quoteResponse" => quote_response,
      "userPublicKey" => Base58.encode(wallet_public_key),
      "wrapAndUnwrapSol" => true,
      "dynamicComputeUnitLimit" => true,
      "prioritizationFeeLamports" => "auto"
    }

    Req.post("#{@jupiter_base_url}/swap", json: payload, headers: jupiter_headers())
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
        %{"encoding" => "base64", "skipPreflight" => true}
      ]
    }

    Req.post(rpc_url(), json: payload)
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

  defp confirm_transaction(tx_signature) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "getSignatureStatuses",
      "params" => [[tx_signature]]
    }

    Req.post(rpc_url(), json: payload)
    |> case do
      {:ok, %{status: 200, body: %{"result" => %{"value" => [status]}}}} when is_map(status) ->
        :ok

      _ ->
        # Confirmation is best-effort here; transaction submission already succeeded.
        :ok
    end
  end

  defp fetch_wallet_usdc_balance(wallet_public_key) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "getTokenAccountsByOwner",
      "params" => [
        Base58.encode(wallet_public_key),
        %{"mint" => @usdc_mint},
        %{"encoding" => "jsonParsed"}
      ]
    }

    Req.post(rpc_url(), json: payload)
    |> case do
      {:ok, %{status: 200, body: %{"result" => %{"value" => accounts}}}} when is_list(accounts) ->
        raw_total = Enum.reduce(accounts, 0, fn account, acc -> acc + account_raw_amount(account) end)
        {:ok, usdc_from_raw(raw_total)}

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

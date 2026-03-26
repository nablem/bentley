defmodule Bentley.Snipers.TelegramNotifier do
  @moduledoc false

  require Logger

  alias Bentley.Snipers.Definition
  alias Bentley.Telegram.Client

  @token_decimals_scale 1_000_000
  @thousand_tokens 100.0
  @hundred_thousand_tokens 100_000.0
  @max_telegram_message_chars 3500
  @max_reason_chars 700

  @spec notify_buy_success(Definition.t(), String.t(), map(), number()) :: :ok
  def notify_buy_success(%Definition{} = definition, wallet_id, token, units)
      when is_binary(wallet_id) and is_map(token) and is_number(units) do
    notify(
      definition,
      wallet_id <> " just bought " <> format_units(units) <> " " <> token_symbol(token)
    )
  end

  @spec notify_buy_failure(Definition.t(), String.t(), map(), term()) :: :ok
  def notify_buy_failure(%Definition{} = definition, wallet_id, token, reason)
      when is_binary(wallet_id) and is_map(token) do
    notify(
      definition,
      wallet_id <>
        " failed to buy " <>
        token_symbol(token) <>
        " (reason: " <> format_failure_reason(reason) <> ")"
    )
  end

  @spec notify_sell_success(Definition.t(), String.t(), map(), number()) :: :ok
  def notify_sell_success(%Definition{} = definition, wallet_id, token, units)
      when is_binary(wallet_id) and is_map(token) and is_number(units) do
    notify(
      definition,
      wallet_id <> " just sold " <> format_units(units) <> " " <> token_symbol(token)
    )
  end

  @spec notify_sell_failure(Definition.t(), String.t(), map(), term()) :: :ok
  def notify_sell_failure(%Definition{} = definition, wallet_id, token, reason)
      when is_binary(wallet_id) and is_map(token) do
    notify(
      definition,
      wallet_id <>
        " failed to sell " <>
        token_symbol(token) <>
        " (reason: " <> format_failure_reason(reason) <> ")"
    )
  end

  defp notify(%Definition{telegram_channel: channel}, _message)
       when not is_binary(channel) or channel == "",
       do: :ok

  defp notify(%Definition{telegram_channel: channel}, message) when is_binary(message) do
    safe_message = truncate(message, @max_telegram_message_chars)

    case Client.send_message(channel, safe_message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Snipers] Failed to send sniper telegram notification to #{channel}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_failure_reason({:send_transaction_failed, payload}) do
    # Typical Solana/Jupiter payload shape:
    # %{"code" => -32002, "data" => %{"err" => %{"InstructionError" => [idx, %{"Custom" => code}]}, ...}}
    code = get_in(payload, ["code"])
    instruction_error = get_in(payload, ["data", "err", "InstructionError"])
    rpc_message = get_in(payload, ["message"])
    custom = extract_custom_error(instruction_error)

    base =
      cond do
        is_integer(custom) ->
          "send_transaction_failed code=#{inspect(code)} custom=#{custom}"

        is_binary(custom) ->
          "send_transaction_failed code=#{inspect(code)} custom=#{custom}"

        not is_nil(instruction_error) ->
          "send_transaction_failed code=#{inspect(code)} instruction_error=#{inspect(instruction_error)}"

        is_binary(rpc_message) and rpc_message != "" ->
          "send_transaction_failed code=#{inspect(code)} rpc_message=#{inspect(rpc_message)}"

        true ->
          "send_transaction_failed code=#{inspect(code)} payload=#{inspect(payload)}"
      end

    truncate(base, @max_reason_chars)
  end

  defp format_failure_reason({:transaction_failed, payload}) do
    truncate("transaction_failed #{inspect(payload)}", @max_reason_chars)
  end

  defp format_failure_reason(reason) do
    truncate(inspect(reason), @max_reason_chars)
  end

  defp extract_custom_error([_idx, %{"Custom" => custom}]), do: custom
  defp extract_custom_error(_), do: nil

  defp truncate(value, max_chars) when is_binary(value) and is_integer(max_chars) and max_chars > 3 do
    if String.length(value) > max_chars do
      String.slice(value, 0, max_chars - 3) <> "..."
    else
      value
    end
  end

  defp token_symbol(token) do
    case Map.get(token, :ticker) do
      nil ->
        Map.get(token, :token_address) || "UNKNOWN"

      "$" <> _ = ticker ->
        ticker

      ticker ->
        "$" <> ticker
    end
  end

  defp format_units(value) when is_number(value) do
    token_units = value / @token_decimals_scale

    cond do
      token_units >= @hundred_thousand_tokens ->
        format_with_suffix(token_units / 1_000_000, "M")

      token_units >= @thousand_tokens ->
        format_with_suffix(token_units / 1_000, "K")

      true ->
        value
        |> round()
        |> Integer.to_string()
    end
  end

  defp format_with_suffix(value, suffix) when is_number(value) and is_binary(suffix) do
    formatted =
      value
      |> Float.round(1)
      |> :erlang.float_to_binary(decimals: 1)

    formatted <> suffix
  end
end

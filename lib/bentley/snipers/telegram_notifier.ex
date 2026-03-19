defmodule Bentley.Snipers.TelegramNotifier do
  @moduledoc false

  require Logger

  alias Bentley.Snipers.Definition
  alias Bentley.Telegram.Client

  @token_decimals_scale 1_000_000
  @thousand_tokens 100.0
  @hundred_thousand_tokens 100_000.0

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
        " failed to buy " <> token_symbol(token) <> " (reason: " <> inspect(reason) <> ")"
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
        " failed to sell " <> token_symbol(token) <> " (reason: " <> inspect(reason) <> ")"
    )
  end

  defp notify(%Definition{telegram_channel: channel}, _message)
       when not is_binary(channel) or channel == "",
       do: :ok

  defp notify(%Definition{telegram_channel: channel}, message) when is_binary(message) do
    case Client.send_message(channel, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Snipers] Failed to send sniper telegram notification to #{channel}: #{inspect(reason)}"
        )

        :ok
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

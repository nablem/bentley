defmodule Bentley.Snipers.TelegramNotifier do
  @moduledoc false

  require Logger

  alias Bentley.Snipers.Definition
  alias Bentley.Telegram.Client

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

  defp format_units(value) when is_integer(value), do: Integer.to_string(value)

  defp format_units(value) when is_float(value) do
    if Float.round(value, 2) == Float.round(value, 0) do
      value
      |> round()
      |> Integer.to_string()
    else
      :erlang.float_to_binary(value, decimals: 2)
    end
  end
end

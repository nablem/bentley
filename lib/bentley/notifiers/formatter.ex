defmodule Bentley.Notifiers.Formatter do
  @moduledoc false

  alias Bentley.Notifiers.Criteria
  alias Bentley.Notifiers.Definition

  @spec format(Definition.t(), struct() | map(), NaiveDateTime.t()) :: String.t()
  def format(_definition, token, now \\ current_time()) do
    title =
      [Map.get(token, :name), ticker_fragment(Map.get(token, :ticker))]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> case do
        "" -> Map.get(token, :token_address) || "Unknown token"
        value -> value
      end

    [
      title,
      line("Token", Map.get(token, :token_address)),
      line("Age", format_age(Criteria.age_in_hours(token, now))),
      line("Market cap", format_money(Map.get(token, :market_cap))),
      line("Liquidity", format_money(Map.get(token, :liquidity))),
      line("Volume 1h", format_money(Map.get(token, :volume_1h))),
      line("Volume 6h", format_money(Map.get(token, :volume_6h))),
      line("Volume 24h", format_money(Map.get(token, :volume_24h))),
      line("Change 1h", format_percent(Map.get(token, :change_1h))),
      line("Change 6h", format_percent(Map.get(token, :change_6h))),
      line("Change 24h", format_percent(Map.get(token, :change_24h))),
      line("ATH", format_money(Map.get(token, :ath))),
      line("Website", Map.get(token, :website_url)),
      line("X", Map.get(token, :x_url)),
      line("Telegram", Map.get(token, :telegram_url)),
      line("Dexscreener", Map.get(token, :url))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp line(_label, nil), do: nil
  defp line(label, value), do: label <> ": " <> value

  defp ticker_fragment(nil), do: nil
  defp ticker_fragment(ticker), do: "(" <> ticker <> ")"

  defp format_age(nil), do: nil
  defp format_age(hours), do: :erlang.float_to_binary(hours, decimals: 2) <> "h"

  defp format_money(nil), do: nil

  defp format_money(value) when is_number(value) do
    "$" <> format_number(value)
  end

  defp format_percent(nil), do: nil

  defp format_percent(value) when is_number(value) do
    format_number(value) <> "%"
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    if Float.round(value, 2) == Float.round(value, 0) do
      value
      |> round()
      |> Integer.to_string()
    else
      :erlang.float_to_binary(value, decimals: 2)
    end
  end

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end
end

defmodule Bentley.Notifiers.Formatter do
  @moduledoc false

  alias Bentley.Notifiers.Criteria
  alias Bentley.Notifiers.Definition

  @spec format(Definition.t(), struct() | map(), NaiveDateTime.t() | nil) :: String.t()
  def format(_definition, token, now \\ nil) do
    now = now || current_time()
    ticker = Map.get(token, :ticker)
    name = Map.get(token, :name)
    description = Map.get(token, :description)
    token_address = Map.get(token, :token_address)
    dexscreener_url = Map.get(token, :url)

    [
      build_title(ticker, name),
      truncate_description(description),
      "",
      metric("Market Cap", format_money(Map.get(token, :market_cap))),
      metric("1h Volume", format_money(Map.get(token, :volume_1h))),
      metric("1h Change", format_percent(Map.get(token, :change_1h))),
      metric("Age", format_age(Criteria.age_in_hours(token, now))),
      "",
      build_urls_line(dexscreener_url, token_address)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp build_title(nil, nil), do: "Unknown token"
  defp build_title(nil, name), do: html_escape(name)
  defp build_title(ticker, nil), do: ticker_with_prefix(ticker) |> html_escape()

  defp build_title(ticker, name) do
    (ticker_with_prefix(ticker) <> " — " <> name)
    |> html_escape()
  end

  defp ticker_with_prefix("$" <> _ = ticker), do: ticker
  defp ticker_with_prefix(ticker), do: "$" <> ticker

  defp truncate_description(nil), do: nil

  defp truncate_description(description) do
    description
    |> String.slice(0, 100)
    |> html_escape()
  end

  defp metric(_label, nil), do: nil
  defp metric(label, value), do: label <> ": " <> html_escape(value)

  defp format_money(nil), do: nil

  defp format_money(value) when is_number(value) do
    cond do
      value >= 1_000_000_000 -> "$" <> format_decimal(value / 1_000_000_000) <> "B"
      value >= 1_000_000 -> "$" <> format_decimal(value / 1_000_000) <> "M"
      value >= 1_000 -> "$" <> format_decimal(value / 1_000) <> "K"
      true -> "$" <> format_decimal(value)
    end
  end

  defp format_percent(nil), do: nil

  defp format_percent(value) when is_number(value) do
    sign = if value >= 0, do: "+", else: ""
    sign <> format_decimal(value) <> "%"
  end

  defp format_age(nil), do: nil

  defp format_age(hours) when is_number(hours) do
    cond do
      hours < 1.0 ->
        minutes = round(hours * 60)
        "#{minutes} minute#{if minutes == 1, do: "", else: "s"}"

      hours < 48.0 ->
        h = trunc(hours)
        "#{h} hour#{if h == 1, do: "", else: "s"}"

      true ->
        days = trunc(hours / 24)
        "#{days} day#{if days == 1, do: "", else: "s"}"
    end
  end

  defp format_decimal(value) when is_number(value) do
    float = value * 1.0

    if Float.round(float, 2) == Float.round(float, 0) do
      Integer.to_string(round(float))
    else
      :erlang.float_to_binary(float, decimals: 2)
    end
  end

  defp build_urls_line(dexscreener_url, token_address) do
    [link("DEX Screener", dexscreener_url), link("Jupiter", jupiter_url(token_address))]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " | ")
    end
  end

  defp link(_label, nil), do: nil
  defp link(label, url), do: ~s(<a href="#{html_escape(url)}">#{label}</a>)

  defp jupiter_url(nil), do: nil
  defp jupiter_url(token_address), do: "https://jup.ag/swap/USDC-" <> token_address

  defp html_escape(nil), do: nil

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end
end

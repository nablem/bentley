defmodule Bentley.Activator do
  @moduledoc """
  Determines whether a token should stay active and records an inactivity reason.

  This module is intentionally small for now so validation rules can be expanded
  later without changing updater flow.
  """

  require Logger

  @min_market_cap_threshold 2_500.0
  @age_limit_hours 840

  @spec define_activity(map()) :: %{active: boolean(), inactivity_reason: String.t() | nil}
  def define_activity(attrs) when is_map(attrs) do
    case inactivity_reason(attrs) do
      nil ->
        %{active: true, inactivity_reason: nil}

      reason ->
        Logger.info(
          "[Activator] Marking token #{inspect(Map.get(attrs, :token_address))} inactive: #{reason}"
        )

        %{active: false, inactivity_reason: reason}
    end
  end

  defp inactivity_reason(attrs) do
    first_update? = first_update?(attrs)

    cond do
      first_update? and blank?(Map.get(attrs, :token_address)) -> "missing_token_address"
      first_update? and missing_name_or_ticker?(attrs) -> "missing_name_or_ticker"
      first_update? and invalid_ticker_format?(Map.get(attrs, :ticker)) -> "invalid_ticker_format"
      invalid_market_cap?(Map.get(attrs, :created_on_chain_at), Map.get(attrs, :market_cap)) -> "invalid_market_cap"
      low_market_cap?(Map.get(attrs, :market_cap)) -> "market_cap_below_2_5k"
      zero_volume_6h?(Map.get(attrs, :volume_6h)) -> "zero_volume_6h"
      tiktok_creator_profile?(Map.get(attrs, :tiktok_url)) -> "tiktok_creator_profile"
      x_post_url?(Map.get(attrs, :x_url)) -> "x_post_url"
      low_liquidity?(Map.get(attrs, :liquidity)) -> "low_liquidity"
      high_boost?(Map.get(attrs, :boost)) -> "high_boost"
      age_above_limit?(Map.get(attrs, :created_on_chain_at)) -> "age_above_#{@age_limit_hours}h"
      livestream_related?(attrs) -> "livestream_related"
      first_update? and name_too_long?(Map.get(attrs, :name)) -> "name_too_long"
      first_update? and invalid_name_charset?(Map.get(attrs, :name)) -> "name_contains_foreign_alphabet"
      first_update? and suspicious_name?(Map.get(attrs, :name)) -> "suspicious_name"
      true -> nil
    end
  end

  defp first_update?(attrs), do: is_nil(Map.get(attrs, :last_checked_at))

  defp missing_name_or_ticker?(attrs) do
    is_nil(Map.get(attrs, :name)) or is_nil(Map.get(attrs, :ticker))
  end

  defp invalid_ticker_format?(ticker) when is_binary(ticker) do
    not String.match?(ticker, ~r/^\$?\w+$/u)
  end

  defp invalid_ticker_format?(_), do: false

  defp invalid_market_cap?(created_on_chain_at, market_cap)
       when is_struct(created_on_chain_at, NaiveDateTime) and is_number(market_cap) do
    age_seconds = NaiveDateTime.diff(current_time(), created_on_chain_at, :second)
    age_seconds >= 0 and age_seconds < 3_600 and market_cap > 50_000_000
  end

  defp invalid_market_cap?(_, _), do: false

  defp low_market_cap?(market_cap) when is_number(market_cap),
    do: market_cap < @min_market_cap_threshold

  defp low_market_cap?(_), do: false

  defp zero_volume_6h?(volume_6h) when is_number(volume_6h), do: volume_6h == 0
  defp zero_volume_6h?(_), do: false

  defp tiktok_creator_profile?(tiktok_url) when is_binary(tiktok_url), do: String.contains?(tiktok_url, "@")
  defp tiktok_creator_profile?(_), do: false

  defp x_post_url?(x_url) when is_binary(x_url), do: String.contains?(x_url, "/status/")
  defp x_post_url?(_), do: false

  defp low_liquidity?(liquidity) when is_number(liquidity), do: liquidity < 1_000
  defp low_liquidity?(_), do: false

  defp high_boost?(boost) when is_number(boost), do: boost >= 500
  defp high_boost?(_), do: false

  defp livestream_related?(attrs) do
    [Map.get(attrs, :website_url), Map.get(attrs, :url)]
    |> Enum.any?(&livestream_domain?/1)
  end

  defp livestream_domain?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) ->
        normalized_host =
          host
          |> String.downcase()
          |> String.trim_leading("www.")

        String.ends_with?(normalized_host, "kick.com") or
          String.ends_with?(normalized_host, "twitch.tv")

      _ ->
        false
    end
  end

  defp livestream_domain?(_), do: false

  defp age_above_limit?(created_on_chain_at) when is_struct(created_on_chain_at, NaiveDateTime) do
    NaiveDateTime.diff(current_time(), created_on_chain_at, :second) > @age_limit_hours * 3_600
  end

  defp age_above_limit?(_), do: false

  defp name_too_long?(name) when is_binary(name), do: String.length(name) > 35
  defp name_too_long?(_), do: false

  defp invalid_name_charset?(name) when is_binary(name) do
    not String.match?(name, ~r/\A[a-zA-Z0-9\/_!?: -]+\z/)
  end

  defp invalid_name_charset?(_), do: false

  defp suspicious_name?(name) when is_binary(name) do
    Bentley.SuspiciousTermsCache.match?(name)
  end

  defp suspicious_name?(_), do: false

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false
end

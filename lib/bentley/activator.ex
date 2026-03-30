defmodule Bentley.Activator do
  @moduledoc """
  Determines whether a token should stay active and records an inactivity reason.

  This module is intentionally small for now so validation rules can be expanded
  later without changing updater flow.
  """

  require Logger

  @min_market_cap_threshold 2_500.0
  @age_limit_hours 840
  @tiktok_name_stopwords ~w(the a an token coin official)
  @desc_terms_regex ~r"""
    \b
    (?:
      a(\.?g)?\.?i|
      agent(s|ic)?|
      privacy|
      dapp|
      defi|
      decentralized|
      platform|
      trading|
      artist|
      dev|
      (live-?)?stream(ed|ing)?|
      creator|
      reward(s)?|
      .*@.*|
      powered|
      driven|
      airdrops?|
      fees?|
      (re)?launch(e[rsd]|ing)?|
      ^i('m)?|
      first
    )
    \b
  """ix

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
      tiktok_creator_profile?(Map.get(attrs, :tiktok_url), Map.get(attrs, :name)) -> "tiktok_creator_profile"
      discord_url_present?(Map.get(attrs, :discord_url)) -> "discord_url_present"
      x_post_url?(Map.get(attrs, :x_url)) -> "x_post_url"
      low_liquidity?(Map.get(attrs, :liquidity)) -> "low_liquidity"
      high_boost?(Map.get(attrs, :boost)) -> "high_boost"
      age_above_limit?(Map.get(attrs, :created_on_chain_at)) -> "age_above_#{@age_limit_hours}h"
      suspicious_website?(attrs) -> "suspicious_website"
      first_update? and blocked_description_terms?(Map.get(attrs, :description)) -> "suspicious_description"
      # Re-enforce suspicious_name on subsequent updates when it was already the stored reason.
      # This prevents a cache reload from being undone by the next updater cycle,
      # which skips this check for non-first updates.
      (Map.get(attrs, :inactivity_reason) == "suspicious_name" or
         (first_update? and suspicious_name?(Map.get(attrs, :name)))) ->
        "suspicious_name"
      true -> nil
    end
  end

  defp first_update?(attrs), do: is_nil(Map.get(attrs, :last_checked_at))

  defp missing_name_or_ticker?(attrs) do
    is_nil(Map.get(attrs, :name)) or is_nil(Map.get(attrs, :ticker))
  end

  defp invalid_ticker_format?(ticker) when is_binary(ticker) do
    not String.match?(ticker, ~r/\A\$?[a-zA-Z0-9_?!-]+\z/)
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

  defp tiktok_creator_profile?(tiktok_url, token_name) when is_binary(tiktok_url) do
    case URI.parse(tiktok_url) do
      %URI{path: path} when is_binary(path) ->
        case Regex.run(~r|^/@([^/?#]+)(?:/([^?#]+))?/?$|, path, capture: :all_but_first) do
          [_handle] ->
            true

          [handle, _video_segment] ->
            tiktok_handle_matches_token_name?(handle, token_name)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp tiktok_creator_profile?(_, _), do: false

  defp tiktok_handle_matches_token_name?(handle, token_name)
       when is_binary(handle) and is_binary(token_name) do
    normalized_handle = normalize_name_for_tiktok_match(handle)
    normalized_token_name = normalize_name_for_tiktok_match(token_name)

    byte_size(normalized_handle) >= 4 and
      byte_size(normalized_token_name) >= 4 and
      (normalized_handle == normalized_token_name or
         String.starts_with?(normalized_handle, normalized_token_name))
  end

  defp tiktok_handle_matches_token_name?(_, _), do: false

  defp normalize_name_for_tiktok_match(value) when is_binary(value) do
    value
    |> URI.decode()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> maybe_reduce_to_leading_name()
    |> Enum.reject(&(&1 in @tiktok_name_stopwords))
    |> Enum.join("")
  end

  defp maybe_reduce_to_leading_name([first_word, "the" | _rest]), do: [first_word]
  defp maybe_reduce_to_leading_name(words), do: words

  defp discord_url_present?(discord_url) when is_binary(discord_url), do: not blank?(discord_url)
  defp discord_url_present?(_), do: false

  defp x_post_url?(x_url) when is_binary(x_url) do
    case URI.parse(x_url) do
      %URI{path: path} when is_binary(path) ->
        String.contains?(path, "/status/") or
          String.starts_with?(path, "/intent") or
          String.starts_with?(path, "/grok")

      _ ->
        false
    end
  end

  defp x_post_url?(_), do: false

  defp low_liquidity?(liquidity) when is_number(liquidity), do: liquidity < 1_000
  defp low_liquidity?(_), do: false

  defp high_boost?(boost) when is_number(boost), do: boost >= 500
  defp high_boost?(_), do: false

  defp suspicious_website?(attrs) do
    [Map.get(attrs, :website_url), Map.get(attrs, :url)]
    |> Enum.any?(&suspicious_website_domain?/1)
  end

  defp suspicious_website_domain?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) ->
        normalized_host =
          host
          |> String.downcase()
          |> String.trim_leading("www.")

        String.ends_with?(normalized_host, "github.com") or
          String.ends_with?(normalized_host, "kick.com") or
          String.ends_with?(normalized_host, "twitch.tv") or
          String.ends_with?(normalized_host, "youtube.com") or
          normalized_host == "youtu.be" or
          String.ends_with?(normalized_host, "bitcointalk.org") or
          String.ends_with?(normalized_host, "reddit.com") or
          String.ends_with?(normalized_host, "4chan.org")

      _ ->
        false
    end
  end

  defp suspicious_website_domain?(_), do: false

  defp age_above_limit?(created_on_chain_at) when is_struct(created_on_chain_at, NaiveDateTime) do
    NaiveDateTime.diff(current_time(), created_on_chain_at, :second) > @age_limit_hours * 3_600
  end

  defp age_above_limit?(_), do: false

  defp blocked_description_terms?(description) when is_binary(description) do
    String.match?(description, @desc_terms_regex)
  end

  defp blocked_description_terms?(_), do: false

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

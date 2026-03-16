defmodule Bentley.Activator do
  @moduledoc """
  Determines whether a token should stay active and records an inactivity reason.

  This module is intentionally small for now so validation rules can be expanded
  later without changing updater flow.
  """

  require Logger

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
    cond do
      blank?(Map.get(attrs, :token_address)) -> "missing_token_address"
      low_liquidity?(Map.get(attrs, :liquidity)) -> "low_liquidity"
      high_boost?(Map.get(attrs, :boost)) -> "high_boost"
      livestream_related?(attrs) -> "livestream_related"
      contains_space?(Map.get(attrs, :ticker)) -> "ticker_contains_space"
      name_too_long?(Map.get(attrs, :name)) -> "name_too_long"
      suspicious_name?(Map.get(attrs, :name)) -> "suspicious_name"
      invalid_name_charset?(Map.get(attrs, :name)) -> "name_contains_foreign_alphabet"
      true -> nil
    end
  end

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

  defp contains_space?(value) when is_binary(value), do: String.contains?(value, " ")
  defp contains_space?(_), do: false

  defp name_too_long?(name) when is_binary(name), do: String.length(name) > 30
  defp name_too_long?(_), do: false

  defp invalid_name_charset?(name) when is_binary(name) do
    not String.match?(name, ~r/\A[a-zA-Z0-9\/_!?: -]+\z/)
  end

  defp invalid_name_charset?(_), do: false

  defp suspicious_name?(name) when is_binary(name) do
    Bentley.SuspiciousTermsCache.match?(name)
  end

  defp suspicious_name?(_), do: false

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false
end

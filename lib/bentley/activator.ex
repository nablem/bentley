defmodule Bentley.Activator do
  @moduledoc """
  Determines whether a token should stay active and records an inactivity reason.

  This module is intentionally small for now so validation rules can be expanded
  later without changing updater flow.
  """

  @spec define_activity(map()) :: %{active: boolean(), inactivity_reason: String.t() | nil}
  def define_activity(attrs) when is_map(attrs) do
    case inactivity_reason(attrs) do
      nil ->
        %{active: true, inactivity_reason: nil}

      reason ->
        %{active: false, inactivity_reason: reason}
    end
  end

  defp inactivity_reason(attrs) do
    cond do
      blank?(Map.get(attrs, :token_address)) -> "missing_token_address"
      true -> nil
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false
end

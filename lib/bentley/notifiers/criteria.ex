defmodule Bentley.Notifiers.Criteria do
  @moduledoc false

  alias Bentley.Notifiers.Definition

  @spec match?(struct() | map(), %{optional(Definition.metric()) => Definition.range()}, NaiveDateTime.t()) ::
          boolean()
  def match?(token, criteria, now \\ current_time()) when is_map(criteria) do
    Enum.all?(criteria, fn {metric, range} ->
      token
      |> metric_value(metric, now)
      |> within_range?(range)
    end)
  end

  @spec age_in_hours(struct() | map(), NaiveDateTime.t()) :: float() | nil
  def age_in_hours(token, now \\ current_time()) do
    case Map.get(token, :created_on_chain_at) do
      %NaiveDateTime{} = created_on_chain_at ->
        NaiveDateTime.diff(now, created_on_chain_at, :second) / 3_600

      _ ->
        nil
    end
  end

  defp metric_value(token, :age_hours, now), do: age_in_hours(token, now)
  defp metric_value(token, metric, _now), do: Map.get(token, metric)

  defp within_range?(nil, _range), do: false

  defp within_range?(value, %{min: min, max: max}) when is_number(value) do
    min_match? = is_nil(min) or value >= min
    max_match? = is_nil(max) or value <= max
    min_match? and max_match?
  end

  defp within_range?(_value, _range), do: false

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end
end

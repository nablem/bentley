defmodule Bentley.Notifiers.Loader do
  @moduledoc false

  alias Bentley.Notifiers.Definition

  @default_interval_seconds 60
  @default_max_tokens_per_run 20

  @spec load_from_config() :: {:ok, [Definition.t()]} | {:error, term()}
  def load_from_config do
    Application.get_env(:bentley, :notifiers_file_path)
    |> load_from_file()
  end

  @spec load_from_file(String.t() | nil) :: {:ok, [Definition.t()]} | {:error, term()}
  def load_from_file(nil), do: {:ok, []}
  def load_from_file(""), do: {:ok, []}

  def load_from_file(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, document} -> parse_document(document)
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  end

  defp parse_document(document) do
    with {:ok, entries} <- extract_entries(document),
         {:ok, definitions} <- parse_entries(entries),
         :ok <- validate_unique_ids(definitions) do
      {:ok, definitions}
    end
  end

  defp extract_entries(entries) when is_list(entries), do: {:ok, entries}

  defp extract_entries(%{"notifiers" => entries}) when is_list(entries), do: {:ok, entries}

  defp extract_entries(_document), do: {:error, :invalid_notifier_document}

  defp parse_entries(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case parse_entry(entry, index) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      error -> error
    end
  end

  defp parse_entry(entry, index) when is_map(entry) do
    with {:ok, id} <- fetch_required_string(entry, "id", index),
         {:ok, telegram_channel} <- fetch_required_string(entry, "telegram_channel", id),
         {:ok, enabled} <- fetch_boolean(entry, "enabled", true),
         {:ok, poll_interval_ms} <- fetch_poll_interval_ms(entry),
         {:ok, max_tokens_per_run} <- fetch_positive_integer(entry, "max_tokens_per_run", @default_max_tokens_per_run, id),
         {:ok, criteria} <- parse_criteria(Map.get(entry, "criteria", %{}), id) do
      {:ok,
       %Definition{
         id: id,
         enabled: enabled,
         telegram_channel: telegram_channel,
         poll_interval_ms: poll_interval_ms,
         max_tokens_per_run: max_tokens_per_run,
         criteria: criteria
       }}
    end
  end

  defp parse_entry(_entry, index), do: {:error, {:invalid_notifier_entry, index}}

  defp parse_criteria(criteria, _id) when criteria in [%{}, nil], do: {:ok, %{}}

  defp parse_criteria(criteria, id) when is_map(criteria) do
    Enum.reduce_while(criteria, {:ok, %{}}, fn {metric_name, range}, {:ok, acc} ->
      with {:ok, metric} <- normalize_metric(metric_name, id),
           {:ok, parsed_range} <- parse_range(range, id, metric) do
        {:cont, {:ok, Map.put(acc, metric, parsed_range)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_criteria(_criteria, id), do: {:error, {:invalid_criteria, id}}

  defp normalize_metric(metric_name, id) when is_binary(metric_name) do
    normalized = String.to_atom(metric_name)
    if normalized in Definition.metrics(), do: {:ok, normalized}, else: {:error, {:unsupported_metric, id, metric_name}}
  end

  defp normalize_metric(metric_name, id), do: {:error, {:unsupported_metric, id, metric_name}}

  defp parse_range(range, id, metric) when is_map(range) do
    min = Map.get(range, "min")
    max = Map.get(range, "max")

    with :ok <- validate_optional_number(min, id, metric, "min"),
         :ok <- validate_optional_number(max, id, metric, "max"),
         :ok <- ensure_bound_present(min, max, id, metric),
         :ok <- validate_range_order(min, max, id, metric) do
      {:ok, %{min: min, max: max}}
    end
  end

  defp parse_range(_range, id, metric), do: {:error, {:invalid_range, id, metric}}

  defp validate_optional_number(nil, _id, _metric, _bound), do: :ok
  defp validate_optional_number(value, _id, _metric, _bound) when is_number(value), do: :ok

  defp validate_optional_number(_value, id, metric, bound) do
    {:error, {:invalid_range_bound, id, metric, bound}}
  end

  defp ensure_bound_present(nil, nil, id, metric), do: {:error, {:empty_range, id, metric}}
  defp ensure_bound_present(_min, _max, _id, _metric), do: :ok

  defp validate_range_order(min, max, id, metric)
       when is_number(min) and is_number(max) and min > max do
    {:error, {:invalid_range_order, id, metric}}
  end

  defp validate_range_order(_min, _max, _id, _metric), do: :ok

  defp fetch_required_string(entry, key, context) do
    case Map.get(entry, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, {:missing_required_field, context, key}}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_required_field, context, key}}
    end
  end

  defp fetch_boolean(entry, key, default) do
    case Map.get(entry, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_boolean, key}}
    end
  end

  defp fetch_poll_interval_ms(entry) do
    with {:ok, seconds} <- fetch_positive_integer(entry, "poll_interval_seconds", @default_interval_seconds, "poll_interval_seconds") do
      {:ok, :timer.seconds(seconds)}
    end
  end

  defp fetch_positive_integer(entry, key, default, context) do
    case Map.get(entry, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, context, key}}
    end
  end

  defp validate_unique_ids(definitions) do
    definitions
    |> Enum.group_by(& &1.id)
    |> Enum.find_value(fn
      {_id, [_single]} -> nil
      {id, _definitions} -> {:error, {:duplicate_notifier_id, id}}
    end)
    |> case do
      nil -> :ok
      error -> error
    end
  end
end

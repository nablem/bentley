defmodule Bentley.SuspiciousTermsCache do
  @moduledoc """
  Caches compiled suspicious-term regexes in ETS for fast matching.

  Patterns are loaded from the configured `:suspicious_terms_file_path` on startup.
  If the configured path changes at runtime, the cache reloads on the next lookup.
  """

  use GenServer
  require Logger

  @table :bentley_suspicious_terms_cache
  @patterns_key :patterns
  @path_key :path
  @suspicious_terms_file_path_key :suspicious_terms_file_path

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec match?(term()) :: boolean()
  def match?(name) when is_binary(name) do
    maybe_reload_when_path_changed()

    patterns()
    |> Enum.any?(&String.match?(name, &1))
  end

  def match?(_), do: false

  @spec reload() :: :ok
  def reload do
    case Process.whereis(__MODULE__) do
      nil ->
        ensure_table()
        _ = reload_from_config()
        :ok

      _pid ->
        GenServer.call(__MODULE__, :reload)
    end
  end

  @impl true
  def init(_state) do
    ensure_table()
    _ = reload_from_config()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    _ = reload_from_config()
    {:reply, :ok, state}
  end

  defp maybe_reload_when_path_changed do
    ensure_table()

    if configured_path() != cached_path() do
      _ = reload_from_config()
    end
  end

  defp reload_from_config do
    case configured_path() do
      path when is_binary(path) and path != "" ->
        case load_patterns(path) do
          {:ok, patterns} ->
            :ets.insert(@table, {@patterns_key, patterns})
            :ets.insert(@table, {@path_key, path})
            :ok

          {:error, reason} ->
            Logger.error(
              "[SuspiciousTermsCache] Failed to read suspicious terms file #{inspect(path)}: #{inspect(reason)}"
            )

            :ets.insert(@table, {@patterns_key, []})
            :ets.insert(@table, {@path_key, path})
            :ok
        end

      _ ->
        :ets.insert(@table, {@patterns_key, []})
        :ets.insert(@table, {@path_key, nil})
        :ok
    end
  end

  defp load_patterns(path) do
    case File.read(path) do
      {:ok, terms} ->
        patterns =
          terms
          |> String.split(~r/\R/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.flat_map(&compile_pattern/1)

        {:ok, patterns}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_pattern(expression) do
    normalized_pattern = normalize_pattern(expression)

    case Regex.compile(normalized_pattern, "iu") do
      {:ok, regex} ->
        [regex]

      {:error, reason} ->
        Logger.warning(
          "[SuspiciousTermsCache] Ignoring invalid suspicious pattern #{inspect(expression)}: #{inspect(reason)}"
        )

        []
    end
  end

  defp normalize_pattern(expression) do
    prefix = if String.starts_with?(expression, "^"), do: "", else: "\\b"
    suffix = if String.ends_with?(expression, "$"), do: "", else: "\\b"
    prefix <> expression <> suffix
  end

  defp patterns do
    ensure_table()

    case :ets.lookup(@table, @patterns_key) do
      [{@patterns_key, patterns}] -> patterns
      _ -> []
    end
  end

  defp cached_path do
    ensure_table()

    case :ets.lookup(@table, @path_key) do
      [{@path_key, path}] -> path
      _ -> nil
    end
  end

  defp configured_path do
    Application.get_env(:bentley, @suspicious_terms_file_path_key)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _table_id ->
        @table
    end

    :ok
  end
end

defmodule Bentley.Notifiers do
  @moduledoc """
  Manages notifier worker processes loaded from the configured YAML file.
  """

  use GenServer
  require Logger

  alias Bentley.Notifiers.Definition
  alias Bentley.Notifiers.Loader
  alias Bentley.Notifiers.Worker

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec reload() :: :ok | {:error, term()}
  def reload do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, :reload, 30_000)
    end
  end

  @spec loaded_definitions() :: [Definition.t()]
  def loaded_definitions do
    case Process.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, :loaded_definitions)
    end
  end

  @spec worker_pid(String.t()) :: pid() | nil
  def worker_pid(id) when is_binary(id) do
    case Registry.lookup(Bentley.Notifiers.Registry, id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(_state) do
    state = %{definitions: %{}}

    case load_and_apply(state) do
      {:ok, new_state} -> {:ok, new_state}
      {:error, reason, fallback_state} ->
        Logger.error("[Notifiers] Failed to load notifier definitions on startup: #{inspect(reason)}")
        {:ok, fallback_state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case load_and_apply(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, same_state} -> {:reply, {:error, reason}, same_state}
    end
  end

  @impl true
  def handle_call(:loaded_definitions, _from, state) do
    definitions = state.definitions |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, definitions, state}
  end

  defp load_and_apply(state) do
    case Loader.load_from_config() do
      {:ok, definitions} ->
        {:ok, apply_definitions(state, definitions)}

      {:error, reason} ->
        Logger.error("[Notifiers] Failed to load notifier definitions: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp apply_definitions(state, definitions) do
    next_definitions =
      definitions
      |> Enum.filter(& &1.enabled)
      |> Map.new(fn definition -> {definition.id, definition} end)

    stop_removed_or_changed_workers(state.definitions, next_definitions)
    start_added_or_changed_workers(state.definitions, next_definitions)

    %{state | definitions: next_definitions}
  end

  defp stop_removed_or_changed_workers(current, next) do
    Enum.each(current, fn {id, definition} ->
      case Map.get(next, id) do
        nil -> stop_worker(id)
        ^definition -> :ok
        _updated -> stop_worker(id)
      end
    end)
  end

  defp start_added_or_changed_workers(current, next) do
    Enum.each(next, fn {id, definition} ->
      case Map.get(current, id) do
        ^definition -> :ok
        _previous -> start_worker(definition)
      end
    end)
  end

  defp start_worker(definition) do
    case DynamicSupervisor.start_child(Bentley.Notifiers.Supervisor, {Worker, definition}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Logger.error("[Notifiers] Failed to start worker #{definition.id}: #{inspect(reason)}")
    end
  end

  defp stop_worker(id) do
    case worker_pid(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Bentley.Notifiers.Supervisor, pid)
    end
  end
end

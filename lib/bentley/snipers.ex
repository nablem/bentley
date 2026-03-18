defmodule Bentley.Snipers do
  @moduledoc """
  Manages sniper worker processes loaded from configured YAML.

  Snipers can be manually reloaded with `reload/0`.
  """

  use GenServer
  require Logger

  alias Bentley.Snipers.Definition
  alias Bentley.Snipers.Loader
  alias Bentley.Snipers.PositionManager
  alias Bentley.Snipers.Worker

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
    case Registry.lookup(Bentley.Snipers.Registry, id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec trigger_on_notification(String.t(), struct()) :: :ok | {:error, term()}
  def trigger_on_notification(notifier_id, token) when is_binary(notifier_id) and is_map(token) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid ->
        GenServer.cast(__MODULE__, {:trigger_on_notification, notifier_id, token})
        :ok
    end
  end

  @impl true
  def init(_state) do
    state = %{definitions: %{}, notifier_index: %{}}

    case load_and_apply(state) do
      {:ok, new_state} -> {:ok, new_state}
      {:error, reason, fallback_state} ->
        Logger.error("[Snipers] Failed to load sniper definitions on startup: #{inspect(reason)}")
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

  @impl true
  def handle_cast({:trigger_on_notification, notifier_id, token}, state) do
    state.notifier_index
    |> Map.get(notifier_id, [])
    |> Enum.each(fn sniper_id ->
      case Map.get(state.definitions, sniper_id) do
        nil ->
          :ok

        definition ->
          Task.Supervisor.start_child(Bentley.Snipers.TaskSupervisor, fn ->
            Enum.each(definition.wallet_ids, fn wallet_id ->
              case PositionManager.open_position(definition, notifier_id, token, wallet_id) do
                :ok ->
                  :ok

                {:error, :sniper_executor_not_configured} ->
                  Logger.warning(
                    "[Snipers] Skipping buy for #{definition.id}/#{wallet_id}: sniper executor is not configured"
                  )

                {:error, reason} ->
                  Logger.error(
                    "[Snipers] Failed to open position for #{definition.id}/#{wallet_id} on #{token.token_address}: #{inspect(reason)}"
                  )
              end
            end)
          end)
      end
    end)

    {:noreply, state}
  end

  defp load_and_apply(state) do
    case Loader.load_from_config() do
      {:ok, definitions} ->
        {:ok, apply_definitions(state, definitions)}

      {:error, reason} ->
        Logger.error("[Snipers] Failed to load sniper definitions: #{inspect(reason)}")
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

    %{state | definitions: next_definitions, notifier_index: build_notifier_index(next_definitions)}
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
    case DynamicSupervisor.start_child(Bentley.Snipers.Supervisor, {Worker, definition}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} ->
        Logger.error("[Snipers] Failed to start worker #{definition.id}: #{inspect(reason)}")
    end
  end

  defp stop_worker(id) do
    case worker_pid(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Bentley.Snipers.Supervisor, pid)
    end
  end

  defp build_notifier_index(definitions) do
    Enum.reduce(definitions, %{}, fn {_id, definition}, acc ->
      Enum.reduce(definition.trigger_on_notifier_ids, acc, fn notifier_id, index ->
        Map.update(index, notifier_id, [definition.id], fn sniper_ids ->
          [definition.id | sniper_ids] |> Enum.uniq()
        end)
      end)
    end)
  end
end

defmodule Bentley.Snipers.Worker do
  @moduledoc false

  use GenServer
  require Logger

  alias Bentley.Snipers.Definition
  alias Bentley.Snipers.PositionManager

  def start_link(%Definition{} = definition) do
    GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
  end

  def child_spec(%Definition{} = definition) do
    %{
      id: {__MODULE__, definition.id},
      start: {__MODULE__, :start_link, [definition]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via_tuple(id), do: {:via, Registry, {Bentley.Snipers.Registry, id}}

  @impl true
  def init(%Definition{} = definition) do
    schedule_poll(definition.poll_interval_ms)
    {:ok, definition}
  end

  @impl true
  def handle_info(:poll, %Definition{} = definition) do
    case PositionManager.process_open_positions(definition) do
      {:ok, %{processed: processed, sells: sells, closed: closed, failed: failed}}
      when processed > 0 or sells > 0 or closed > 0 or failed > 0 ->
        Logger.info(
          "[Snipers] #{definition.id} processed #{processed} open positions, executed #{sells} sells, closed #{closed}, failed #{failed}"
        )

      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.error("[Snipers] #{definition.id} poll failed: #{inspect(reason)}")
    end

    schedule_poll(definition.poll_interval_ms)
    {:noreply, definition}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end

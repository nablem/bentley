defmodule Bentley.RateLimiter do
  @moduledoc """
  A simple rate limiter that allows 60 requests per minute (1 per second).
  """
  use GenServer
  require Logger

  @rate_ms 1000 # 1 request per second = 60 per minute

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes a function if a slot is available, otherwise waits.
  """
  def execute(func) do
    GenServer.call(__MODULE__, :acquire, :infinity)
    func.()
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{last_request_at: nil}}
  end

  @impl true
  def handle_call(:acquire, _from, %{last_request_at: nil} = state) do
    {:reply, :ok, %{state | last_request_at: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    now = System.monotonic_time(:millisecond)
    diff = now - state.last_request_at

    if diff < @rate_ms do
      wait_time = @rate_ms - diff
      Process.sleep(wait_time)
      new_now = System.monotonic_time(:millisecond)
      {:reply, :ok, %{state | last_request_at: new_now}}
    else
      {:reply, :ok, %{state | last_request_at: now}}
    end
  end
end

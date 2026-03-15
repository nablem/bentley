defmodule Bentley.Recorder do
  @moduledoc """
  Periodically fetches latest Solana token profiles from Dexscreener.
  """
  use GenServer
  require Logger

  alias Bentley.Repo
  alias Bentley.Schema.Token
  alias Bentley.RateLimiter

  @poll_interval :timer.minutes(2)
  @api_url "https://api.dexscreener.com/token-profiles/latest/v1"
  @chain_id "solana"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Start immediately
    schedule_poll(0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    Logger.info("[Recorder] Polling Dexscreener for latest profiles...")

    case RateLimiter.execute(fn -> Req.get(@api_url) end) do
      {:ok, %{status: 200, body: profiles}} when is_list(profiles) ->
        profiles
        |> Enum.filter(fn p -> p["chainId"] == @chain_id end)
        |> Enum.each(&process_token/1)

      {:ok, response} ->
        Logger.error("[Recorder] Unexpected response: #{inspect(response)}")

      {:error, reason} ->
        Logger.error("[Recorder] API request failed: #{inspect(reason)}")
    end

    schedule_poll()

    {:noreply, state}
  end

  def process_token(data) do
    attrs = %{
      token_address: data["tokenAddress"],
      description: data["description"]
    }

    # Upsert token
    %Token{}
    |> Token.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:description, :updated_at]},
      conflict_target: :token_address
    )
    |> case do
      {:ok, _token} ->
        Logger.info("[Recorder] Discovered/Updated token: #{data["tokenAddress"]}")

      {:error, changeset} ->
        Logger.error(
          "[Recorder] Failed to save token #{data["tokenAddress"]}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp schedule_poll(interval \\ @poll_interval) do
    Process.send_after(self(), :poll, interval)
  end
end

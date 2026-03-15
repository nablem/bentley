defmodule Bentley.Updater do
  @moduledoc """
  Periodically refreshes metrics for active Solana tokens.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias Bentley.RateLimiter
  alias Bentley.Repo
  alias Bentley.Schema.Token

  @details_api_base_url "https://api.dexscreener.com/tokens/v1/solana"
  @default_update_interval :timer.minutes(2)
  @default_batch_size 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_update(0)
    {:ok, %{interval: @default_update_interval, batch_size: @default_batch_size}}
  end

  @impl true
  def handle_info(:update, state) do
    Logger.info("[Updater] Refreshing metrics for active tokens...")

    due_token_addresses(state.batch_size, state.interval)
    |> Enum.each(&fetch_and_update_token/1)

    schedule_update(state.interval)
    {:noreply, state}
  end

  def due_token_addresses(
        limit \\ @default_batch_size,
        interval_ms \\ @default_update_interval,
        now \\ current_time()
      ) do
    cutoff = cutoff_for(now, interval_ms)

    Token
    |> where([t], is_nil(t.last_checked_at) or t.last_checked_at <= ^cutoff)
    |> order_by([t], asc: t.last_checked_at)
    |> limit(^limit)
    |> select([t], t.token_address)
    |> Repo.all()
  end

  def cutoff_for(now \\ current_time(), interval_ms \\ @default_update_interval) do
    NaiveDateTime.add(now, -div(interval_ms, 1_000), :second)
  end

  def update_token_from_details(token_address, details) when is_binary(token_address) and is_map(details) do
    attrs = %{
      market_cap: normalize_number(details["marketCap"]),
      volume_1h: normalize_number(get_in(details, ["volume", "h1"])),
      volume_6h: normalize_number(get_in(details, ["volume", "h6"])),
      volume_24h: normalize_number(get_in(details, ["volume", "h24"])),
      change_1h: normalize_number(get_in(details, ["priceChange", "h1"])),
      change_6h: normalize_number(get_in(details, ["priceChange", "h6"])),
      last_checked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    case Repo.get_by(Token, token_address: token_address) do
      nil ->
        {:error, :token_not_found}

      token ->
        token
        |> Token.changeset(attrs)
        |> Repo.update()
    end
  end

  defp fetch_and_update_token(token_address) do
    case RateLimiter.execute(fn -> Req.get("#{@details_api_base_url}/#{token_address}") end) do
      {:ok, %{status: 200, body: [details | _]}} when is_map(details) ->
        case update_token_from_details(token_address, details) do
          {:ok, _token} ->
            Logger.debug("[Updater] Refreshed #{token_address}")

          {:error, reason} ->
            Logger.error("[Updater] Failed to persist #{token_address}: #{inspect(reason)}")
        end

      {:ok, %{status: 200, body: body}} ->
        Logger.error("[Updater] Unexpected details payload for #{token_address}: #{inspect(body)}")

      {:ok, response} ->
        Logger.error("[Updater] Unexpected response for #{token_address}: #{inspect(response)}")

      {:error, reason} ->
        Logger.error("[Updater] API request failed for #{token_address}: #{inspect(reason)}")
    end
  end

  defp normalize_number(value) when is_integer(value), do: value * 1.0
  defp normalize_number(value) when is_float(value), do: value
  defp normalize_number(_value), do: nil

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp schedule_update(interval) do
    Process.send_after(self(), :update, interval)
  end
end

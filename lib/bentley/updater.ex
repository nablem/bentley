defmodule Bentley.Updater do
  @moduledoc """
  Periodically refreshes metrics for active Solana tokens.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias Bentley.Activator
  alias Bentley.RateLimiter
  alias Bentley.Repo
  alias Bentley.Schema.Token

  @details_api_base_url "https://api.dexscreener.com/tokens/v1/solana"
  @default_update_interval :timer.minutes(1)
  @default_batch_size 30

  @high_volume_threshold 1_000.0
  @age_fast_hours 10.0
  @age_short_hours 24.0
  @age_medium_hours 72.0
  @age_long_hours 240.0

  @fast_refresh_interval :timer.minutes(3)
  @short_refresh_interval :timer.minutes(5)
  @medium_refresh_interval :timer.minutes(15)
  @long_refresh_interval :timer.minutes(60)
  @very_long_refresh_interval :timer.hours(3)

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

    due_token_addresses(state.batch_size)
    |> Enum.each(&fetch_and_update_token/1)

    schedule_update(state.interval)
    {:noreply, state}
  end

  def due_token_addresses(limit \\ @default_batch_size, now \\ current_time()) do
    Token
    |> where([t], t.active == true)
    |> select([t], %{
      token_address: t.token_address,
      created_on_chain_at: t.created_on_chain_at,
      last_checked_at: t.last_checked_at,
      volume_1h: t.volume_1h
    })
    |> Repo.all()
    |> Enum.filter(&due_by_policy?(&1, now))
    |> Enum.sort_by(&overdue_ratio(&1, now), :desc)
    |> Enum.take(limit)
    |> Enum.map(& &1.token_address)
  end

  def cutoff_for(now \\ current_time(), interval_ms \\ @default_update_interval) do
    NaiveDateTime.add(now, -div(interval_ms, 1_000), :second)
  end

  def update_interval_for(age_hours, volume_1h) do
    cond do
      fast_refresh?(age_hours, volume_1h) ->
        @fast_refresh_interval

      age_hours < @age_short_hours ->
        @short_refresh_interval

      age_hours < @age_medium_hours ->
        @medium_refresh_interval

      age_hours < @age_long_hours ->
        @long_refresh_interval

      true ->
        @very_long_refresh_interval
    end
  end

  def update_token_from_details(token_address, details) when is_binary(token_address) and is_map(details) do
    socials = get_in(details, ["info", "socials"]) || []

    attrs = %{
      url: details["url"],
      website_url: first_website_url(details),
      x_url: social_url(socials, "twitter"),
      telegram_url: social_url(socials, "telegram"),
      boost: normalize_integer(get_in(details, ["boosts", "active"])),
      created_on_chain_at: normalize_pair_created_at(details["pairCreatedAt"]),
      market_cap: normalize_number(details["marketCap"]),
      name: get_in(details, ["baseToken", "name"]),
      ticker: get_in(details, ["baseToken", "symbol"]),
      volume_1h: normalize_number(get_in(details, ["volume", "h1"])),
      volume_6h: normalize_number(get_in(details, ["volume", "h6"])),
      volume_24h: normalize_number(get_in(details, ["volume", "h24"])),
      change_1h: normalize_number(get_in(details, ["priceChange", "h1"])),
      change_6h: normalize_number(get_in(details, ["priceChange", "h6"])),
      change_24h: normalize_number(get_in(details, ["priceChange", "h24"])),
      liquidity: normalize_number(get_in(details, ["liquidity", "usd"])),
      icon: get_in(details, ["info", "imageUrl"]),
      last_checked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    case Repo.get_by(Token, token_address: token_address) do
      nil ->
        {:error, :token_not_found}

      token ->
        attrs = Enum.reject(attrs, fn {_key, value} -> is_nil(value) end) |> Map.new()
        attrs = compute_ath(attrs, token)
        activity_attrs =
          token
          |> attrs_for_activity(attrs)
          |> Activator.define_activity()

        attrs = Map.merge(attrs, activity_attrs)

        token
        |> Token.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc false
  def handle_details_response(token_address, response) when is_binary(token_address) do
    case response do
      {:ok, %{status: 200, body: [details | _]}} when is_map(details) ->
        case update_token_from_details(token_address, details) do
          {:ok, token} -> {:ok, :updated, token}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: 200, body: []}} ->
        case mark_token_inactive(token_address, "token_undefined_per_api") do
          {:ok, token} -> {:ok, :inactivated, token}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: 200, body: body}} ->
        Logger.error("[Updater] Unexpected details payload for #{token_address}: #{inspect(body)}")
        {:error, :unexpected_details_payload}

      {:ok, response} ->
        Logger.error("[Updater] Unexpected response for #{token_address}: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        Logger.error("[Updater] API request failed for #{token_address}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp compute_ath(attrs, token) do
    case attrs[:market_cap] do
      market_cap when is_number(market_cap) ->
        ath =
          [token.ath, token.market_cap, market_cap]
          |> Enum.filter(&is_number/1)
          |> Enum.max()

        Map.put(attrs, :ath, ath)

      _ ->
        attrs
    end
  end

  defp mark_token_inactive(token_address, reason) do
    case Repo.get_by(Token, token_address: token_address) do
      nil ->
        {:error, :token_not_found}

      token ->
        token
        |> Token.changeset(%{
          active: false,
          inactivity_reason: reason,
          last_checked_at: current_time()
        })
        |> Repo.update()
    end
  end

  defp attrs_for_activity(token, incoming_attrs) do
    token
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
    |> Map.merge(incoming_attrs)
    # Activity gating relies on the previous persisted check timestamp.
    |> Map.put(:last_checked_at, token.last_checked_at)
  end

  defp fetch_and_update_token(token_address) do
    response = RateLimiter.execute(fn -> Req.get("#{@details_api_base_url}/#{token_address}") end)

    case handle_details_response(token_address, response) do
      {:ok, :updated, _token} ->
        Logger.debug("[Updater] Refreshed #{token_address}")

      {:ok, :inactivated, _token} ->
        Logger.info("[Updater] Marked #{token_address} inactive: token_undefined_per_api")

      {:error, reason} ->
        Logger.error("[Updater] Failed to persist #{token_address}: #{inspect(reason)}")
    end
  end

  defp normalize_number(value) when is_integer(value), do: value * 1.0
  defp normalize_number(value) when is_float(value), do: value
  defp normalize_number(_value), do: nil

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(value) when is_float(value), do: trunc(value)
  defp normalize_integer(_value), do: nil

  defp normalize_pair_created_at(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.to_naive(datetime) |> NaiveDateTime.truncate(:second)
      _ -> nil
    end
  end

  defp normalize_pair_created_at(value) when is_float(value) do
    normalize_pair_created_at(round(value))
  end

  defp normalize_pair_created_at(_value), do: nil

  defp first_website_url(details) do
    details
    |> get_in(["info", "websites"])
    |> case do
      [%{"url" => url} | _] when is_binary(url) -> url
      _ -> nil
    end
  end

  defp social_url(socials, type) do
    socials
    |> Enum.find_value(fn
      %{"type" => ^type, "url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp fast_refresh?(age_hours, volume_1h) do
    age_hours < @age_fast_hours or volume_1h > @high_volume_threshold
  end

  defp due_by_policy?(token, now) do
    age_hours = age_in_hours(token.created_on_chain_at, now)
    volume_1h = token.volume_1h || 0.0
    interval = update_interval_for(age_hours, volume_1h)

    token.last_checked_at == nil or
      NaiveDateTime.compare(token.last_checked_at, cutoff_for(now, interval)) in [:lt, :eq]
  end

  # Never-checked tokens always get maximum priority.
  defp overdue_ratio(%{last_checked_at: nil}, _now), do: 1.0e308

  defp overdue_ratio(token, now) do
    age_hours = age_in_hours(token.created_on_chain_at, now)
    volume_1h = token.volume_1h || 0.0
    interval_seconds = div(update_interval_for(age_hours, volume_1h), 1_000)
    NaiveDateTime.diff(now, token.last_checked_at, :second) / interval_seconds
  end

  defp age_in_hours(nil, _now), do: 0.0

  defp age_in_hours(created_on_chain_at, now) do
    NaiveDateTime.diff(now, created_on_chain_at, :second) / 3_600
  end

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp schedule_update(interval) do
    Process.send_after(self(), :update, interval)
  end
end

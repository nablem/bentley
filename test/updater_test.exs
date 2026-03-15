defmodule Bentley.UpdaterTest do
  use ExUnit.Case

  alias Bentley.Repo
  alias Bentley.Schema.Token
  alias Bentley.Updater

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bentley.Repo)
  end

  test "update_token_from_details persists metrics" do
    token_address = "young_token_1"

    %Token{}
    |> Token.changeset(%{token_address: token_address})
    |> Repo.insert!()

    details = %{
      "url" => "https://dexscreener.com/solana/AbC123",
      "pairCreatedAt" => 1_700_000_000_000,
      "baseToken" => %{"name" => "Alpha", "symbol" => "ALP"},
      "boosts" => %{"active" => 3},
      "marketCap" => 42_000,
      "liquidity" => %{"usd" => 99_500},
      "volume" => %{"h1" => 1_200, "h6" => 5_500, "h24" => 24_000},
      "priceChange" => %{"h1" => 12.5, "h6" => -3.1, "h24" => 8.7},
      "info" => %{
        "imageUrl" => "https://cdn.dex.example/icon.png",
        "websites" => [%{"url" => "https://alpha.example"}],
        "socials" => [
          %{"type" => "twitter", "url" => "https://x.com/alpha"},
          %{"type" => "telegram", "url" => "https://t.me/alpha"}
        ]
      }
    }

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.url == "https://dexscreener.com/solana/AbC123"
    assert token.website_url == "https://alpha.example"
    assert token.x_url == "https://x.com/alpha"
    assert token.telegram_url == "https://t.me/alpha"
    assert token.boost == 3
    assert token.created_on_chain_at == ~N[2023-11-14 22:13:20]
    assert token.name == "Alpha"
    assert token.ticker == "ALP"
    assert token.icon == "https://cdn.dex.example/icon.png"
    assert token.market_cap == 42_000.0
    assert token.liquidity == 99_500.0
    assert token.volume_1h == 1_200.0
    assert token.volume_6h == 5_500.0
    assert token.volume_24h == 24_000.0
    assert token.change_1h == 12.5
    assert token.change_6h == -3.1
    assert token.change_24h == 8.7
    assert token.last_checked_at != nil
  end

  test "update_token_from_details keeps existing values when sparse body omits fields" do
    token_address = "sparse_token_1"

    %Token{}
    |> Token.changeset(%{
      token_address: token_address,
      url: "https://before.example",
      website_url: "https://site.before",
      x_url: "https://x.com/before",
      telegram_url: "https://t.me/before",
      boost: 7,
      market_cap: 123.0,
      name: "Before",
      ticker: "BFR",
      volume_1h: 10.0,
      volume_6h: 11.0,
      volume_24h: 12.0,
      change_1h: 1.0,
      change_6h: 2.0,
      change_24h: 3.0,
      liquidity: 456.0,
      icon: "https://icon.before",
      created_on_chain_at: ~N[2024-01-01 00:00:00]
    })
    |> Repo.insert!()

    assert {:ok, _} = Updater.update_token_from_details(token_address, %{})

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.url == "https://before.example"
    assert token.website_url == "https://site.before"
    assert token.x_url == "https://x.com/before"
    assert token.telegram_url == "https://t.me/before"
    assert token.boost == 7
    assert token.created_on_chain_at == ~N[2024-01-01 00:00:00]
    assert token.market_cap == 123.0
    assert token.name == "Before"
    assert token.ticker == "BFR"
    assert token.volume_1h == 10.0
    assert token.volume_6h == 11.0
    assert token.volume_24h == 12.0
    assert token.change_1h == 1.0
    assert token.change_6h == 2.0
    assert token.change_24h == 3.0
    assert token.liquidity == 456.0
    assert token.icon == "https://icon.before"
    assert token.last_checked_at != nil
  end

  test "update_token_from_details keeps existing numeric values when incoming numeric fields are malformed" do
    token_address = "malformed_token_1"

    %Token{}
    |> Token.changeset(%{
      token_address: token_address,
      created_on_chain_at: ~N[2024-02-02 00:00:00],
      boost: 8,
      market_cap: 10.0,
      liquidity: 20.0,
      volume_1h: 30.0,
      volume_6h: 40.0,
      volume_24h: 50.0,
      change_1h: 60.0,
      change_6h: 70.0,
      change_24h: 80.0
    })
    |> Repo.insert!()

    details = %{
      "pairCreatedAt" => "not_a_timestamp",
      "boosts" => %{"active" => "bad"},
      "marketCap" => "bad",
      "liquidity" => %{"usd" => "bad"},
      "volume" => %{"h1" => "bad", "h6" => "bad", "h24" => "bad"},
      "priceChange" => %{"h1" => "bad", "h6" => "bad", "h24" => "bad"}
    }

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.created_on_chain_at == ~N[2024-02-02 00:00:00]
    assert token.boost == 8
    assert token.market_cap == 10.0
    assert token.liquidity == 20.0
    assert token.volume_1h == 30.0
    assert token.volume_6h == 40.0
    assert token.volume_24h == 50.0
    assert token.change_1h == 60.0
    assert token.change_6h == 70.0
    assert token.change_24h == 80.0
    assert token.last_checked_at != nil
  end

  test "update_token_from_details returns error when token does not exist" do
    assert {:error, :token_not_found} = Updater.update_token_from_details("missing_token", %{})
  end

  test "due_token_addresses only returns unchecked or stale tokens" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    created_on_chain_at = NaiveDateTime.add(now, -30 * 3_600, :second)
    high_volume_interval = Updater.update_interval_for(30.0, 1_500.0)
    low_volume_interval = Updater.update_interval_for(30.0, 100.0)

    %Token{}
    |> Token.changeset(%{token_address: "never_checked"})
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "high_volume_due",
      created_on_chain_at: created_on_chain_at,
      volume_1h: 1_500.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, high_volume_interval), -10, :second)
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "low_volume_fresh",
      created_on_chain_at: created_on_chain_at,
      volume_1h: 100.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, low_volume_interval), 10, :second)
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "low_volume_due",
      created_on_chain_at: created_on_chain_at,
      volume_1h: 100.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, low_volume_interval), -10, :second)
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "inactive_due",
      active: false,
      created_on_chain_at: created_on_chain_at,
      volume_1h: 100.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, low_volume_interval), -10, :second)
    })
    |> Repo.insert!()

    token_addresses = Updater.due_token_addresses(10, now)

    assert "never_checked" in token_addresses
    assert "high_volume_due" in token_addresses
    assert "low_volume_due" in token_addresses
    refute "low_volume_fresh" in token_addresses
    refute "inactive_due" in token_addresses
  end

  test "update_interval_for applies age and volume rules" do
    assert Updater.update_interval_for(5.0, 100.0) == :timer.minutes(3)
    assert Updater.update_interval_for(100.0, 1_500.0) == :timer.minutes(3)
    assert Updater.update_interval_for(20.0, 100.0) == :timer.minutes(5)
    assert Updater.update_interval_for(30.0, 100.0) == :timer.minutes(15)
    assert Updater.update_interval_for(100.0, 100.0) == :timer.minutes(45)
    assert Updater.update_interval_for(600.0, 100.0) == :timer.hours(2)
  end

  test "update_interval_for handles boundaries and precedence exhaustively" do
    cases = [
      {0.0, 0.0, :timer.minutes(3)},
      {9.999, 0.0, :timer.minutes(3)},
      {10.0, 0.0, :timer.minutes(5)},
      {23.999, 0.0, :timer.minutes(5)},
      {24.0, 0.0, :timer.minutes(15)},
      {47.999, 0.0, :timer.minutes(15)},
      {48.0, 0.0, :timer.minutes(45)},
      {499.999, 0.0, :timer.minutes(45)},
      {500.0, 0.0, :timer.hours(2)},
      {1_000.0, 0.0, :timer.hours(2)},
      {10.0, 1_000.0, :timer.minutes(5)},
      {500.0, 1_000.01, :timer.minutes(3)},
      {30.0, 50_000.0, :timer.minutes(3)},
      {-1.0, 0.0, :timer.minutes(3)}
    ]

    Enum.each(cases, fn {age_hours, volume_1h, expected_interval} ->
      assert Updater.update_interval_for(age_hours, volume_1h) == expected_interval
    end)
  end

  test "due_token_addresses includes token exactly at cutoff and excludes just after cutoff" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    created_on_chain_at = NaiveDateTime.add(now, -40 * 3_600, :second)
    interval_ms = Updater.update_interval_for(40.0, 100.0)
    cutoff = cutoff_for(now, interval_ms)

    %Token{}
    |> Token.changeset(%{
      token_address: "exact_cutoff_due",
      created_on_chain_at: created_on_chain_at,
      volume_1h: 100.0,
      last_checked_at: cutoff
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "after_cutoff_not_due",
      created_on_chain_at: created_on_chain_at,
      volume_1h: 100.0,
      last_checked_at: NaiveDateTime.add(cutoff, 1, :second)
    })
    |> Repo.insert!()

    token_addresses = Updater.due_token_addresses(10, now)

    assert "exact_cutoff_due" in token_addresses
    refute "after_cutoff_not_due" in token_addresses
  end

  defp cutoff_for(now, interval_ms), do: Updater.cutoff_for(now, interval_ms)
end

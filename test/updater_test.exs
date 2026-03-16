defmodule Bentley.UpdaterTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

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

  test "update_token_from_details applies activity attrs from activator before update" do
    token_address = "reactivation_token"
    created_on_chain_at = NaiveDateTime.add(NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second), -(100 * 3_600), :second)

    %Token{}
    |> Token.changeset(%{
      token_address: token_address,
      active: false,
      inactivity_reason: "manually_disabled",
      description: "keep me",
      url: "https://before.example/token",
      website_url: "https://before.example",
      x_url: "https://x.com/before",
      telegram_url: "https://t.me/before",
      boost: 9,
      created_on_chain_at: created_on_chain_at,
      market_cap: 123.0,
      volume_1h: 45.0,
      icon: "https://before.example/icon.png"
    })
    |> Repo.insert!()

    details = %{"baseToken" => %{"name" => "Reactivated", "symbol" => "REA"}}

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == true
    assert token.inactivity_reason == nil
    assert token.description == "keep me"
    assert token.url == "https://before.example/token"
    assert token.website_url == "https://before.example"
    assert token.x_url == "https://x.com/before"
    assert token.telegram_url == "https://t.me/before"
    assert token.boost == 9
    assert token.created_on_chain_at == created_on_chain_at
    assert token.market_cap == 123.0
    assert token.volume_1h == 45.0
    assert token.icon == "https://before.example/icon.png"
  end

  test "update_token_from_details computes ath by comparing market caps" do
    token_address = "ath_test_token"

    # Insert token with existing market cap and ath
    %Token{}
    |> Token.changeset(%{
      token_address: token_address,
      market_cap: 100.0,
      ath: 150.0
    })
    |> Repo.insert!()

    # Update with higher market cap - ath should be updated to new value
    details = %{
      "marketCap" => 200.0,
      "baseToken" => %{"name" => "Token", "symbol" => "TOK"}
    }

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.market_cap == 200.0
    assert token.ath == 200.0

    # Update with lower market cap - ath should remain at previous high
    details = %{
      "marketCap" => 50.0,
      "baseToken" => %{"name" => "Token", "symbol" => "TOK"}
    }

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.market_cap == 50.0
    assert token.ath == 200.0

    details = %{
      "marketCap" => 100.0,
      "baseToken" => %{"name" => "Token", "symbol" => "TOK"}
    }

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.market_cap == 100.0
    assert token.ath == 200.0
  end

  test "handle_details_response marks token inactive when api returns an empty array" do
    token_address = "random_token"

    %Token{}
    |> Token.changeset(%{
      token_address: token_address,
      active: true,
      inactivity_reason: nil
    })
    |> Repo.insert!()

    capture_log(fn ->
      assert {:ok, :inactivated, _token} =
               Updater.handle_details_response(token_address, {:ok, %{status: 200, body: []}})
    end)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == false
    assert token.inactivity_reason == "token_undefined_per_api"
    assert token.last_checked_at != nil
  end

  test "update_token_from_details applies ticker format check only on first update" do
    token_address = "first_update_ticker_space"

    %Token{}
    |> Token.changeset(%{token_address: token_address, active: true})
    |> Repo.insert!()

    details = %{"baseToken" => %{"name" => "Token", "symbol" => "BAD TICK"}}

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == false
    assert token.inactivity_reason == "invalid_ticker_format"
    assert token.last_checked_at != nil

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == true
    assert token.inactivity_reason == nil
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

  test "due_token_addresses prioritizes by overdue ratio, not by absolute staleness" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Old token (very_long = 3h interval), last checked 4.5h ago → ratio = 1.5
    # Without the fix this would rank 2nd (checked 4.5h ago).
    %Token{}
    |> Token.changeset(%{
      token_address: "slow_ratio_1_5x",
      created_on_chain_at: NaiveDateTime.add(now, -300 * 3_600, :second),
      volume_1h: 0.0,
      last_checked_at: NaiveDateTime.add(now, -270 * 60, :second)
    })
    |> Repo.insert!()

    # Young token (fast = 3min interval), last checked 12min ago → ratio = 4.0
    # Without the fix this would rank last (most recently checked).
    %Token{}
    |> Token.changeset(%{
      token_address: "fast_ratio_4x",
      created_on_chain_at: NaiveDateTime.add(now, -5 * 3_600, :second),
      volume_1h: 0.0,
      last_checked_at: NaiveDateTime.add(now, -12 * 60, :second)
    })
    |> Repo.insert!()

    # Old token (very_long = 3h interval), last checked 9h ago → ratio = 3.0
    # Without the fix this would rank 1st (oldest last_checked_at).
    %Token{}
    |> Token.changeset(%{
      token_address: "slow_ratio_3x",
      created_on_chain_at: NaiveDateTime.add(now, -300 * 3_600, :second),
      volume_1h: 0.0,
      last_checked_at: NaiveDateTime.add(now, -540 * 60, :second)
    })
    |> Repo.insert!()

    addresses = Updater.due_token_addresses(3, now)

    # Correct order: highest ratio first — fast token must beat the merely stale slow ones.
    assert addresses == ["fast_ratio_4x", "slow_ratio_3x", "slow_ratio_1_5x"]
  end

  test "due_token_addresses gives never-checked tokens the highest priority" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Old token very overdue (ratio = 3.0).
    %Token{}
    |> Token.changeset(%{
      token_address: "slow_overdue",
      created_on_chain_at: NaiveDateTime.add(now, -300 * 3_600, :second),
      volume_1h: 0.0,
      last_checked_at: NaiveDateTime.add(now, -540 * 60, :second)
    })
    |> Repo.insert!()

    # Token never checked — should always come first regardless.
    %Token{}
    |> Token.changeset(%{token_address: "never_checked"})
    |> Repo.insert!()

    [first | _] = Updater.due_token_addresses(2, now)
    assert first == "never_checked"
  end

  test "update_interval_for applies age and volume rules" do
    assert Updater.update_interval_for(5.0, 100.0) == :timer.minutes(3)
    assert Updater.update_interval_for(100.0, 1_500.0) == :timer.minutes(3)
    assert Updater.update_interval_for(20.0, 100.0) == :timer.minutes(5)
    assert Updater.update_interval_for(30.0, 100.0) == :timer.minutes(15)
    assert Updater.update_interval_for(100.0, 100.0) == :timer.minutes(60)
    assert Updater.update_interval_for(600.0, 100.0) == :timer.hours(3)
  end

  test "update_interval_for handles boundaries and precedence exhaustively" do
    cases = [
      {0.0, 0.0, :timer.minutes(3)},
      {9.999, 0.0, :timer.minutes(3)},
      {10.0, 0.0, :timer.minutes(5)},
      {23.999, 0.0, :timer.minutes(5)},
      {24.0, 0.0, :timer.minutes(15)},
      {71.999, 0.0, :timer.minutes(15)},
      {72.0, 0.0, :timer.minutes(60)},
      {239.999, 0.0, :timer.minutes(60)},
      {240.0, 0.0, :timer.hours(3)},
      {1_000.0, 0.0, :timer.hours(3)},
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

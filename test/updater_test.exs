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
      "marketCap" => 42_000,
      "volume" => %{"h1" => 1_200, "h6" => 5_500, "h24" => 24_000},
      "priceChange" => %{"h1" => 12.5, "h6" => -3.1}
    }

    assert {:ok, _} = Updater.update_token_from_details(token_address, details)

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.market_cap == 42_000.0
    assert token.volume_1h == 1_200.0
    assert token.volume_6h == 5_500.0
    assert token.volume_24h == 24_000.0
    assert token.change_1h == 12.5
    assert token.change_6h == -3.1
    assert token.last_checked_at != nil
  end

  test "due_token_addresses only returns unchecked or stale tokens" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.add(30 * 3_600, :second)
    high_volume_interval = Updater.update_interval_for(30.0, 1_500.0)
    low_volume_interval = Updater.update_interval_for(30.0, 100.0)

    %Token{}
    |> Token.changeset(%{token_address: "never_checked"})
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "high_volume_due",
      volume_1h: 1_500.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, high_volume_interval), -10, :second)
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "low_volume_fresh",
      volume_1h: 100.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, low_volume_interval), 10, :second)
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "low_volume_due",
      volume_1h: 100.0,
      last_checked_at: NaiveDateTime.add(cutoff_for(now, low_volume_interval), -10, :second)
    })
    |> Repo.insert!()

    token_addresses = Updater.due_token_addresses(10, now)

    assert "never_checked" in token_addresses
    assert "high_volume_due" in token_addresses
    assert "low_volume_due" in token_addresses
    refute "low_volume_fresh" in token_addresses
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
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.add(40 * 3_600, :second)
    interval_ms = Updater.update_interval_for(40.0, 100.0)
    cutoff = cutoff_for(now, interval_ms)

    %Token{}
    |> Token.changeset(%{
      token_address: "exact_cutoff_due",
      volume_1h: 100.0,
      last_checked_at: cutoff
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "after_cutoff_not_due",
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

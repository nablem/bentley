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
    now = ~N[2026-03-15 18:00:00]
    interval_ms = :timer.minutes(2)
    cutoff = Updater.cutoff_for(now, interval_ms)

    %Token{}
    |> Token.changeset(%{token_address: "never_checked"})
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "stale_token",
      last_checked_at: NaiveDateTime.add(cutoff, -30, :second)
    })
    |> Repo.insert!()

    %Token{}
    |> Token.changeset(%{
      token_address: "fresh_token",
      last_checked_at: NaiveDateTime.add(cutoff, 30, :second)
    })
    |> Repo.insert!()

    token_addresses = Updater.due_token_addresses(10, interval_ms, now)

    assert "never_checked" in token_addresses
    assert "stale_token" in token_addresses
    refute "fresh_token" in token_addresses
  end
end

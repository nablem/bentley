defmodule Bentley.ActivatorTest do
  use ExUnit.Case, async: true

  alias Bentley.Activator

  test "define_activity marks token as active when no inactivity reason is found" do
    attrs = %{token_address: "abc123", active: false, inactivity_reason: "stale", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity marks token as inactive when token address is blank" do
    attrs = %{token_address: "   ", name: "Broken"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "missing_token_address"
  end

  test "define_activity marks token as inactive when liquidity is below 1000" do
    attrs = %{token_address: "abc123", liquidity: 999.99, name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "low_liquidity"
  end

  test "define_activity marks token as inactive when boost is >= 500" do
    attrs = %{token_address: "abc123", boost: 500, name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "high_boost"
  end

  test "define_activity marks token as inactive for kick website" do
    attrs = %{token_address: "abc123", website_url: "https://kick.com/some-channel", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "livestream_related"
  end

  test "define_activity marks token as inactive when ticker contains a space" do
    attrs = %{token_address: "abc123", ticker: "AL P", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "ticker_contains_space"
  end

  test "define_activity marks token as inactive when name is longer than 30 chars" do
    attrs = %{token_address: "abc123", name: "This name is definitely over thirty chars"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "name_too_long"
  end

  test "define_activity marks token as inactive when name contains foreign alphabet" do
    attrs = %{token_address: "abc123", name: "Token漢字"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "name_contains_foreign_alphabet"
  end
end

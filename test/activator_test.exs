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
end

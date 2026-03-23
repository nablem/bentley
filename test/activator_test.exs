defmodule Bentley.ActivatorTest do
  use ExUnit.Case, async: false

  alias Bentley.Activator

  setup do
    previous_path = Application.get_env(:bentley, :suspicious_terms_file_path)

    on_exit(fn ->
      Application.put_env(:bentley, :suspicious_terms_file_path, previous_path)
    end)

    :ok
  end

  test "define_activity marks token as active when no inactivity reason is found" do
    attrs = %{
      token_address: "abc123",
      active: false,
      inactivity_reason: "stale",
      name: "Alpha",
      ticker: "ALP"
    }

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
    attrs = %{token_address: "abc123", liquidity: 999.99, name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "low_liquidity"
  end

  test "define_activity marks token as inactive when market cap is below 2.5K" do
    attrs = %{token_address: "abc123", market_cap: 2_499.99, name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "market_cap_below_2_5k"
  end

  test "define_activity does not mark token inactive when market cap is exactly 2.5K" do
    attrs = %{token_address: "abc123", market_cap: 2_500.0, name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity marks token as inactive when 6-hour volume is zero" do
    attrs = %{token_address: "abc123", volume_6h: 0.0, name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "zero_volume_6h"
  end

  test "define_activity filters tiktok creator profile urls" do
    blocked_tiktok_urls = [
      "https://www.tiktok.com/@alpha",
      "https://www.tiktok.com/@alpha/"
    ]

    Enum.each(blocked_tiktok_urls, fn tiktok_url ->
      attrs = %{token_address: "abc123", tiktok_url: tiktok_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == false
      assert result.inactivity_reason == "tiktok_creator_profile"
    end)

    allowed_tiktok_urls = [
      "https://www.tiktok.com/@alpha/video/123",
      "https://www.tiktok.com/discover?query=@alpha"
    ]

    Enum.each(allowed_tiktok_urls, fn tiktok_url ->
      attrs = %{token_address: "abc123", tiktok_url: tiktok_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == true
      assert result.inactivity_reason == nil
    end)
  end

  test "define_activity marks token as inactive for filtered X URL routes" do
    blocked_x_urls = [
      "https://x.com/alpha/status/123",
      "https://x.com/intent/post?text=hello",
      "https://x.com/search?q=alpha",
      "https://x.com/grok"
    ]

    Enum.each(blocked_x_urls, fn x_url ->
      attrs = %{token_address: "abc123", x_url: x_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == false
      assert result.inactivity_reason == "x_post_url"
    end)

    allowed_attrs = %{token_address: "abc123", x_url: "https://x.com/alpha", name: "Alpha", ticker: "ALP"}
    allowed_result = Activator.define_activity(allowed_attrs)

    assert allowed_result.active == true
    assert allowed_result.inactivity_reason == nil
  end

  test "define_activity marks token as inactive when boost is >= 500" do
    attrs = %{token_address: "abc123", boost: 500, name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "high_boost"
  end

  test "define_activity marks token as inactive for kick website" do
    attrs = %{
      token_address: "abc123",
      website_url: "https://kick.com/some-channel",
      name: "Alpha",
      ticker: "ALP"
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "livestream_related"
  end

  test "define_activity marks token as inactive when name or ticker is nil" do
    attrs = %{token_address: "abc123", name: nil, ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "missing_name_or_ticker"
  end

  test "define_activity marks token as inactive when ticker format is invalid" do
    attrs = %{token_address: "abc123", ticker: "AL P", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "invalid_ticker_format"
  end

  test "define_activity marks token as inactive when age is above 840 hours" do
    attrs = %{
      token_address: "abc123",
      name: "Alpha",
      ticker: "ALP",
      created_on_chain_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -(841 * 3_600), :second),
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "age_above_840h"
  end

  test "define_activity marks token as inactive when age is below 1 hour and market cap is above 50M" do
    attrs = %{
      token_address: "abc123",
      name: "Alpha",
      ticker: "ALP",
      created_on_chain_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -(30 * 60), :second),
      market_cap: 50_000_001.0,
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "invalid_market_cap"
  end

  test "define_activity does not mark invalid market cap when age is above 1 hour" do
    attrs = %{
      token_address: "abc123",
      name: "Alpha",
      ticker: "ALP",
      created_on_chain_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -(2 * 3_600), :second),
      market_cap: 50_000_001.0,
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity marks token as inactive when name is longer than 35 chars" do
    attrs = %{token_address: "abc123", ticker: "ALP", name: "This name is definitely over thirty chars"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "name_too_long"
  end

  test "define_activity marks token as inactive when name contains foreign alphabet" do
    attrs = %{token_address: "abc123", ticker: "ALP", name: "Token漢字"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "name_contains_foreign_alphabet"
  end

  test "define_activity marks token as inactive when name matches suspicious term" do
    suspicious_terms_file_path = write_suspicious_terms_file(["rug", "^scam", "dump$"])
    Application.put_env(:bentley, :suspicious_terms_file_path, suspicious_terms_file_path)

    result = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "Mega Rug Launch"})

    assert result.active == false
    assert result.inactivity_reason == "suspicious_name"
  end

  test "define_activity applies word boundaries for suspicious term matching" do
    suspicious_terms_file_path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, suspicious_terms_file_path)

    result = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "Drugcoin"})

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity keeps ^ and $ anchors for suspicious term matching" do
    suspicious_terms_file_path = write_suspicious_terms_file(["^scam", "dump$"])
    Application.put_env(:bentley, :suspicious_terms_file_path, suspicious_terms_file_path)

    start_match = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "scam alert"})
    end_match = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "mega dump"})

    assert start_match.active == false
    assert start_match.inactivity_reason == "suspicious_name"
    assert end_match.active == false
    assert end_match.inactivity_reason == "suspicious_name"
  end

  test "define_activity skips token identity checks after first update" do
    attrs = %{
      token_address: "   ",
      ticker: "AL P",
      name: "This name is definitely over thirty chars",
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity still applies non-identity checks after first update" do
    attrs = %{
      token_address: "   ",
      liquidity: 999.0,
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "low_liquidity"
  end

  test "define_activity still applies low market cap check after first update" do
    attrs = %{
      token_address: "   ",
      market_cap: 2_400.0,
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "market_cap_below_2_5k"
  end

  test "define_activity still applies zero 6-hour volume check after first update" do
    attrs = %{
      token_address: "   ",
      volume_6h: 0,
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "zero_volume_6h"
  end

  test "define_activity still applies tiktok creator profile check after first update" do
    attrs = %{
      token_address: "abc123",
      tiktok_url: "https://www.tiktok.com/@alpha",
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "tiktok_creator_profile"
  end

  defp write_suspicious_terms_file(lines) do
    file_path = Path.join(System.tmp_dir!(), "suspicious_terms_#{System.unique_integer([:positive])}.txt")
    File.write!(file_path, Enum.join(lines, "\n"))

    on_exit(fn ->
      File.rm(file_path)
    end)

    file_path
  end
end

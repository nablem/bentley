defmodule Bentley.ActivatorTest do
  use ExUnit.Case, async: false

  import Mox

  alias Bentley.Activator

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous_path = Application.get_env(:bentley, :suspicious_terms_file_path)
    previous_claude_api_key = Application.get_env(:bentley, :claude_api_key)
    previous_claude_client = Application.get_env(:bentley, :claude_client)

    Application.delete_env(:bentley, :claude_api_key)
    Application.put_env(:bentley, :claude_client, Bentley.Claude.ClientMock)

    on_exit(fn ->
      Application.put_env(:bentley, :suspicious_terms_file_path, previous_path)
      restore_app_env(:bentley, :claude_api_key, previous_claude_api_key)
      restore_app_env(:bentley, :claude_client, previous_claude_client)
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

    blocked_tiktok_videos = [
      {"Alpha", "https://www.tiktok.com/@alpha/video/123"},
      {"Alpha", "https://www.tiktok.com/@alphaofficial/video/123"},
      {"Tortellini", "https://www.tiktok.com/@tortellini702/video/7621316266602581278"},
      {"Joeffrey The Pig", "https://www.tiktok.com/@joeffreypig/video/123"},
      {"Joeffrey The Pig", "https://www.tiktok.com/@joeffrey458/video/123"},
      {"Joeffrey The Big Pink Pig", "https://www.tiktok.com/@joeffrey999/video/123"},
      {"Joey Official", "https://www.tiktok.com/@joey46468/video/991"},
      {"Cafe Luna", "https://www.tiktok.com/@cafelunaofficial/video/555"},
      {"El Nino", "https://www.tiktok.com/@elnino/video/888"},
      {"Mega Coin", "https://www.tiktok.com/@mega/video/777"}
    ]

    Enum.each(blocked_tiktok_videos, fn {token_name, tiktok_url} ->
      attrs = %{token_address: "abc123", tiktok_url: tiktok_url, name: token_name, ticker: "TRTL"}

      result = Activator.define_activity(attrs)

      assert result.active == false
      assert result.inactivity_reason == "tiktok_creator_profile"
    end)

    allowed_tiktok_urls = [
      "https://www.tiktok.com/@unrelated/video/123",
      "https://www.tiktok.com/discover?query=@alpha",
      "https://www.tiktok.com/@joe/video/991",
      "https://www.tiktok.com/@jo3y/video/991",
      "https://www.tiktok.com/@pigjoeffrey/video/123",
      "https://www.tiktok.com/@cafelunafan/video/555",
      "https://www.tiktok.com/@megacoiners/video/777",
      "https://www.tiktok.com/tag/@alpha"
    ]

    Enum.each(allowed_tiktok_urls, fn tiktok_url ->
      attrs = %{token_address: "abc123", tiktok_url: tiktok_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == true
      assert result.inactivity_reason == nil
    end)
  end

  test "define_activity marks token as inactive when discord url is present" do
    attrs = %{token_address: "abc123", discord_url: "https://discord.gg/alpha", name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "discord_url_present"
  end

  test "define_activity keeps token active when discord url is nil or blank" do
    nil_result =
      Activator.define_activity(%{token_address: "abc123", discord_url: nil, name: "Alpha", ticker: "ALP"})

    blank_result =
      Activator.define_activity(%{token_address: "abc123", discord_url: "   ", name: "Alpha", ticker: "ALP"})

    assert nil_result.active == true
    assert nil_result.inactivity_reason == nil
    assert blank_result.active == true
    assert blank_result.inactivity_reason == nil
  end

  test "define_activity marks token as inactive for filtered X URL routes" do
    blocked_x_urls = [
      "https://x.com/alpha/status/123",
      "https://x.com/intent/post?text=hello",
      "https://x.com/grok"
    ]

    Enum.each(blocked_x_urls, fn x_url ->
      attrs = %{token_address: "abc123", x_url: x_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == false
      assert result.inactivity_reason == "x_post_url"
    end)

    allowed_x_urls = [
      "https://x.com/alpha",
      "https://x.com/search?q=alpha"
    ]

    Enum.each(allowed_x_urls, fn x_url ->
      allowed_attrs = %{token_address: "abc123", x_url: x_url, name: "Alpha", ticker: "ALP"}
      allowed_result = Activator.define_activity(allowed_attrs)

      assert allowed_result.active == true
      assert allowed_result.inactivity_reason == nil
    end)
  end

  test "define_activity marks token as inactive when boost is >= 500" do
    attrs = %{token_address: "abc123", boost: 500, name: "Alpha", ticker: "ALP"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "high_boost"
  end

  test "define_activity marks token as inactive for suspicious websites" do
    blocked_urls = [
      "https://kick.com/some-channel",
      "https://www.twitch.tv/some-channel",
      "https://github.com/febo/p-token",
      "https://www.youtube.com/watch?v=abc123",
      "https://youtu.be/abc123",
      "https://bitcointalk.org/index.php?topic=123",
      "https://www.reddit.com/r/CryptoMoonShots",
      "https://en.wikipedia.org/wiki/Bitcoin",
      "https://boards.4chan.org/biz/"
    ]

    Enum.each(blocked_urls, fn website_url ->
      attrs = %{token_address: "abc123", website_url: website_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == false
      assert result.inactivity_reason == "suspicious_website"
    end)

    allowed_urls = [
      "https://gitlab.com/example/project",
      "https://myproject.com"
    ]

    Enum.each(allowed_urls, fn website_url ->
      attrs = %{token_address: "abc123", website_url: website_url, name: "Alpha", ticker: "ALP"}

      result = Activator.define_activity(attrs)

      assert result.active == true
      assert result.inactivity_reason == nil
    end)
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

  test "define_activity marks token as inactive when ticker contains non-latin characters" do
    attrs = %{token_address: "abc123", ticker: "토큰", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "invalid_ticker_format"
  end

  test "define_activity keeps token active when ticker uses allowed punctuation" do
    attrs = %{token_address: "abc123", ticker: "ALP_2026-OK?!", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity keeps token active when ticker starts with dollar sign" do
    attrs = %{token_address: "abc123", ticker: "$ALP", name: "Alpha"}

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
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

  test "define_activity marks token as inactive when description contains blocked terms on first update" do
    blocked_descriptions = [
      "AI-driven platform for everyone",
      "A.I analytics for meme coins",
      "AGI has been achieved by OmegaToken",
      "Multi-agent application for crypto",
      "Agentic marketing service for web3 projects",
      "Privacy-focused assistant for users",
      "Next-gen dapp launch",
      "Relaunching with new features",
      "Innovative game launcher",
      "Project re-launched now",
      "Live-streaming event",
      "Streamed live on Twitch",
      "Decentralized liquidity network",
      "Best trading terminal",
      "Crypto artist collective",
      "By BetaToken creator",
      "By @gamma",
      "Built by a solo dev",
      "Powered by memes",
      "Community driven token",
      "Massive airdrop incoming",
      "Rewards for early users",
      "No fees for early users",
      "DeFi staking protocol",
      "I'm a entrepreneur in crypto",
      "First token on the blockchain",
      "Official token of the metaverse"
    ]

    Enum.each(blocked_descriptions, fn description ->
      attrs = %{token_address: "abc123", ticker: "ALP", name: "Alpha", description: description}

      result = Activator.define_activity(attrs)

      assert result.active == false
      assert result.inactivity_reason == "suspicious_description"
    end)
  end

  test "define_activity marks token as inactive when Claude says two-word name is a real person" do
    Application.put_env(:bentley, :claude_api_key, "test-key")

    Bentley.Claude.ClientMock
    |> expect(:real_person_name?, fn "John Smith" -> {:ok, true} end)

    result = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "John Smith"})

    assert result.active == false
    assert result.inactivity_reason == "real_person"
  end

  test "define_activity keeps token active when Claude says two-word name is not a real person" do
    Application.put_env(:bentley, :claude_api_key, "test-key")

    Bentley.Claude.ClientMock
    |> expect(:real_person_name?, fn "Alpha Coin" -> {:ok, false} end)

    result = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "Alpha Coin"})

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity keeps token active when claude api key is missing" do
    result = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "John Smith"})

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity skips claude check when name is not exactly two words" do
    Application.put_env(:bentley, :claude_api_key, "test-key")

    result = Activator.define_activity(%{token_address: "abc123", ticker: "ALP", name: "Mr. John Smith"})

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity skips claude check after first update" do
    Application.put_env(:bentley, :claude_api_key, "test-key")

    result =
      Activator.define_activity(%{
        token_address: "abc123",
        ticker: "ALP",
        name: "John Smith",
        last_checked_at: ~N[2026-03-16 00:00:00]
      })

    assert result.active == true
    assert result.inactivity_reason == nil
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

  test "define_activity re-applies suspicious name check after first update when inactivity_reason was suspicious_name" do
    attrs = %{
      token_address: "abc123",
      ticker: "ALP",
      name: "Mega Rug Launch",
      inactivity_reason: "suspicious_name",
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == false
    assert result.inactivity_reason == "suspicious_name"
  end

  test "define_activity skips suspicious name check after first update when inactivity_reason is something else" do
    suspicious_terms_file_path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, suspicious_terms_file_path)

    attrs = %{
      token_address: "abc123",
      ticker: "ALP",
      name: "Mega Rug Launch",
      inactivity_reason: "low_liquidity",
      last_checked_at: ~N[2026-03-16 00:00:00]
    }

    result = Activator.define_activity(attrs)

    assert result.active == true
    assert result.inactivity_reason == nil
  end

  test "define_activity skips blocked description check after first update" do
    attrs = %{
      token_address: "abc123",
      ticker: "ALP",
      name: "Alpha",
      description: "AI trading platform",
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

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end

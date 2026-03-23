defmodule Bentley.SnipersTest do
  use ExUnit.Case, async: false

  import Mox

  alias Bentley.Repo
  alias Bentley.Schema.SniperPosition
  alias Bentley.Schema.SniperTrade
  alias Bentley.Schema.Token
  alias Bentley.Snipers
  alias Bentley.Snipers.Definition
  alias Bentley.Snipers.Loader
  alias Bentley.Snipers.PositionManager
  alias Bentley.Snipers.TelegramNotifier

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bentley.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Bentley.Repo, {:shared, self()})

    previous_path = Application.get_env(:bentley, :snipers_file_path)
    previous_executor = Application.get_env(:bentley, :sniper_executor)
    previous_client = Application.get_env(:bentley, :telegram_client)

    Repo.delete_all(SniperTrade)
    Repo.delete_all(SniperPosition)
    Repo.delete_all(Token)

    Application.put_env(:bentley, :sniper_executor, Bentley.Snipers.ExecutorMock)
    Application.put_env(:bentley, :telegram_client, Bentley.Telegram.ClientMock)
    Application.put_env(:bentley, :snipers_file_path, nil)

    stub(Bentley.Telegram.ClientMock, :send_message, fn _channel, _message -> :ok end)
    stub(Bentley.Telegram.ClientMock, :send_photo, fn _channel, _photo_url, _caption -> :ok end)

    stub(Bentley.Snipers.ExecutorMock, :token_balance, fn _token, _options ->
      {:ok, 1_000_000_000_000}
    end)

    :ok = Snipers.reload()

    on_exit(fn ->
      Application.put_env(:bentley, :sniper_executor, previous_executor)
      Application.put_env(:bentley, :telegram_client, previous_client)
      Application.put_env(:bentley, :snipers_file_path, previous_path)
      _ = Snipers.reload()
    end)

    :ok
  end

  test "loader parses sniper defaults with optional stop loss and timeout disabled" do
    path =
      write_yaml!("""
      snipers:
        - id: alpha
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          exit_tiers:
            - market_cap: 50000
              sell_percent: 100
      """)

    assert {:ok,
            [
              %Definition{
                id: "alpha",
                trigger_on_notifier_ids: ["early-microcap"],
                wallet_ids: ["main"],
                poll_interval_ms: 120_000,
                buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil},
                safety: %{
                  max_slippage_percent: 15,
                  max_position_count: 10,
                  stop_loss_percent: nil,
                  timeout_hours: nil
                },
                exit_tiers: [%{market_cap: 50000, sell_percent: 100}]
              }
            ]} = Loader.load_from_file(path)
  end

  test "loader accepts disabling max position and max slippage safety" do
    path =
      write_yaml!("""
      snipers:
        - id: alpha
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          exit_tiers:
            - market_cap: 50000
              sell_percent: 100
          safety:
            max_slippage_percent: null
            max_position_count: null
            stop_loss_percent: null
            timeout_hours: null
      """)

    assert {:ok, [%Definition{safety: safety}]} = Loader.load_from_file(path)
    assert safety.max_slippage_percent == nil
    assert safety.max_position_count == nil
    assert safety.stop_loss_percent == nil
    assert safety.timeout_hours == nil
  end

  test "open_position enforces minimum wallet usdc capital when configured" do
    now = ~N[2026-03-18 14:00:00]

    token =
      insert_token!(%{
        token_address: "token-min-usdc",
        active: true,
        market_cap: 30_000.0,
        name: "Capital Gate",
        ticker: "CAP"
      })

    definition = %Definition{
      id: "capital-gated",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{
        enabled: true,
        position_size_usd: 100,
        slippage_bps: 50,
        min_wallet_usdc: 500
      }
    }

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, fn options ->
      assert options.wallet_id == "main"
      {:ok, 250.0}
    end)
    |> deny(:buy, 3)

    assert {:error, {:insufficient_wallet_usdc, 250.0, 500}} =
             PositionManager.open_position(definition, "early-microcap", token, "main", now)
  end

  test "telegram notifier formats large units with one decimal in millions" do
    definition = %Definition{
      id: "fmt-m",
      trigger_on_notifier_ids: [],
      wallet_ids: [],
      telegram_channel: "@sniper",
      exit_tiers: []
    }

    token = %{ticker: "FMT", token_address: "fmt-token"}

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main just bought 0.1M $FMT"
      :ok
    end)

    assert :ok = TelegramNotifier.notify_buy_success(definition, "main", token, 100_000_000_000)
  end

  test "telegram notifier formats medium units with one decimal in thousands" do
    definition = %Definition{
      id: "fmt-k",
      trigger_on_notifier_ids: [],
      wallet_ids: [],
      telegram_channel: "@sniper",
      exit_tiers: []
    }

    token = %{ticker: "FMT", token_address: "fmt-token"}

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main just sold 0.7K $FMT"
      :ok
    end)

    assert :ok = TelegramNotifier.notify_sell_success(definition, "main", token, 700_000_000)
  end

  test "telegram notifier keeps dust in raw units" do
    definition = %Definition{
      id: "fmt-dust",
      trigger_on_notifier_ids: [],
      wallet_ids: [],
      telegram_channel: "@sniper",
      exit_tiers: []
    }

    token = %{ticker: "FMT", token_address: "fmt-token"}

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main just sold 99999999 $FMT"
      :ok
    end)

    assert :ok = TelegramNotifier.notify_sell_success(definition, "main", token, 99_999_999)
  end

  test "open_position sends telegram message on buy success" do
    now = ~N[2026-03-18 14:00:00]

    token =
      insert_token!(%{
        token_address: "token-buy-success",
        active: true,
        market_cap: 30_000.0,
        name: "Buy Success",
        ticker: "BYS"
      })

    definition = %Definition{
      id: "buy-success",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, fn %Token{token_address: "token-buy-success"}, 100_000_000, _options ->
      {:ok, %{units: 1_000.0, amount_usd: 100.0, tx_signature: "buy-success"}}
    end)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main just bought 1000 $BYS"
      :ok
    end)

    assert :ok = PositionManager.open_position(definition, "early-microcap", token, "main", now)
  end

  test "open_position sends telegram message on buy failure" do
    now = ~N[2026-03-18 14:00:00]

    token =
      insert_token!(%{
        token_address: "token-buy-failure",
        active: true,
        market_cap: 30_000.0,
        name: "Buy Failure",
        ticker: "BYF"
      })

    definition = %Definition{
      id: "buy-failure",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, fn %Token{token_address: "token-buy-failure"}, 100_000_000, _options ->
      {:error, :quote_failed}
    end)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main failed to buy $BYF (reason: :quote_failed)"
      :ok
    end)

    assert {:error, :quote_failed} =
             PositionManager.open_position(definition, "early-microcap", token, "main", now)
  end

  test "open_position does NOT send telegram message for insufficient_wallet_usdc" do
    now = ~N[2026-03-18 14:00:00]

    token =
      insert_token!(%{
        token_address: "token-insufficient-usdc",
        active: true,
        market_cap: 30_000.0,
        name: "Insufficient USDC",
        ticker: "IU"
      })

    definition = %Definition{
      id: "insufficient-wallet",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: 500}
    }

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, fn options ->
      assert options.wallet_id == "main"
      {:ok, 250.0}
    end)
    # Should NOT call buy since wallet USDC is insufficient
    |> deny(:buy, 3)

    # Should NOT send a telegram message for this fallback error
    Bentley.Telegram.ClientMock
    |> deny(:send_message, 2)

    assert {:error, {:insufficient_wallet_usdc, 250.0, 500}} =
             PositionManager.open_position(definition, "early-microcap", token, "main", now)
  end



  test "reload replaces sniper workers when yaml definitions change" do
    path =
      write_yaml!("""
      snipers:
        - id: alpha
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          exit_tiers:
            - market_cap: 50000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    assert :ok = Snipers.reload()
    first_pid = Snipers.worker_pid("alpha")
    assert is_pid(first_pid)

    File.write!(
      path,
      """
      snipers:
        - id: alpha
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - secondary
          exit_tiers:
            - market_cap: 80000
              sell_percent: 100
      """
    )

    assert :ok = Snipers.reload()
    second_pid = Snipers.worker_pid("alpha")
    assert is_pid(second_pid)
    assert second_pid != first_pid
    assert :sys.get_state(second_pid).wallet_ids == ["secondary"]
  end

  test "trigger opens one position per wallet_id" do
    now = ~N[2026-03-18 14:00:00]

    token =
      insert_token!(%{
        token_address: "token-multi-wallet",
        active: true,
        market_cap: 55_000.0,
        name: "Multi Wallet",
        ticker: "MW"
      })

    path =
      write_yaml!("""
      snipers:
        - id: alpha
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
            - second
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 50
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, 2, fn options ->
      assert options.wallet_id in ["main", "second"]
      {:ok, 500.0}
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, 2, fn %Token{token_address: "token-multi-wallet"}, 100_000_000, options ->
      assert options.wallet_id in ["main", "second"]
      assert options.amount_usdc == 100
      assert options.amount_usdc_raw == 100_000_000
      {:ok, %{units: 1000.0, amount_usd: 100.0, tx_signature: "buy-#{options.wallet_id}"}}
    end)

    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    wait_until(fn ->
      Repo.aggregate(SniperPosition, :count, :id) == 2
    end)

    positions =
      SniperPosition
      |> Repo.all()
      |> Enum.filter(&(&1.sniper_id == "alpha" and &1.token_address == "token-multi-wallet"))

    assert Enum.sort(Enum.map(positions, & &1.wallet_id)) == ["main", "second"]

    assert {:ok, %{processed: 2, sells: 0, closed: 0, failed: 0}} =
             PositionManager.process_open_positions(hd(Snipers.loaded_definitions()), now)
  end

  test "trigger prioritizes highest min_wallet_usdc sniper per wallet" do
    token =
      insert_token!(%{
        token_address: "token-priority-high",
        active: true,
        market_cap: 55_000.0,
        name: "Priority High",
        ticker: "PH"
      })

    path =
      write_yaml!("""
      snipers:
        - id: low-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 100
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
        - id: high-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 500
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, 1, fn options ->
      assert options.wallet_id == "main"
      assert options.sniper_id == "high-threshold"
      {:ok, 600.0}
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, 1, fn %Token{token_address: "token-priority-high"}, 100_000_000, options ->
      assert options.wallet_id == "main"
      assert options.sniper_id == "high-threshold"
      {:ok, %{units: 1000.0, amount_usd: 100.0, tx_signature: "buy-priority-high"}}
    end)

    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    wait_until(fn ->
      Repo.aggregate(SniperPosition, :count, :id) == 1
    end)

    position = Repo.get_by!(SniperPosition, token_address: "token-priority-high", wallet_id: "main")
    assert position.sniper_id == "high-threshold"
  end

  test "trigger falls back to lower min_wallet_usdc sniper when highest is insufficient" do
    token =
      insert_token!(%{
        token_address: "token-priority-fallback",
        active: true,
        market_cap: 55_000.0,
        name: "Priority Fallback",
        ticker: "PF"
      })

    path =
      write_yaml!("""
      snipers:
        - id: low-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 100
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
        - id: high-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 500
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, 2, fn options ->
      assert options.wallet_id == "main"

      case options.sniper_id do
        "high-threshold" -> {:ok, 200.0}
        "low-threshold" -> {:ok, 200.0}
      end
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, 1, fn %Token{token_address: "token-priority-fallback"}, 100_000_000, options ->
      assert options.wallet_id == "main"
      assert options.sniper_id == "low-threshold"
      {:ok, %{units: 900.0, amount_usd: 100.0, tx_signature: "buy-priority-fallback"}}
    end)

    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    wait_until(fn ->
      Repo.aggregate(SniperPosition, :count, :id) == 1
    end)

    position =
      Repo.get_by!(
        SniperPosition,
        token_address: "token-priority-fallback",
        wallet_id: "main"
      )

    assert position.sniper_id == "low-threshold"
  end

  test "stops buying after second-highest threshold succeeds without trying lowest" do
    token =
      insert_token!(%{
        token_address: "token-stop-at-medium",
        active: true,
        market_cap: 55_000.0,
        name: "Stop At Medium",
        ticker: "SAM"
      })

    path =
      write_yaml!("""
      snipers:
        - id: lowest-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 50
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
        - id: medium-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 250
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
        - id: highest-threshold
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 500
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    # Wallet has 300 USDC: enough for medium (250) and lowest (50), but not highest (500)
    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, 2, fn options ->
      assert options.wallet_id == "main"

      case options.sniper_id do
        "highest-threshold" -> {:ok, 300.0}
        "medium-threshold" -> {:ok, 300.0}
      end
    end)

    # Should only call buy once for medium-threshold, NOT for lowest-threshold
    Bentley.Snipers.ExecutorMock
    |> expect(:buy, 1, fn %Token{token_address: "token-stop-at-medium"}, 100_000_000, options ->
      assert options.wallet_id == "main"
      assert options.sniper_id == "medium-threshold"
      {:ok, %{units: 900.0, amount_usd: 100.0, tx_signature: "buy-stop-at-medium"}}
    end)

    # Should never reach lowest-threshold check since medium succeeded
    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    wait_until(fn ->
      Repo.aggregate(SniperPosition, :count, :id) == 1
    end)

    position =
      Repo.get_by!(
        SniperPosition,
        token_address: "token-stop-at-medium",
        wallet_id: "main"
      )

    assert position.sniper_id == "medium-threshold"
  end

  test "trigger does nothing when wallet balance is below all sniper thresholds" do
    token =
      insert_token!(%{
        token_address: "token-all-thresholds-too-high",
        active: true,
        market_cap: 40_000.0,
        name: "No Match",
        ticker: "NM"
      })

    path =
      write_yaml!("""
      snipers:
        - id: threshold-high
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 500
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
        - id: threshold-low
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 200
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    # Wallet only has 50 USDC — below both thresholds (500 and 200)
    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, 2, fn options ->
      assert options.wallet_id == "main"
      {:ok, 50.0}
    end)

    # buy must never be called
    Bentley.Snipers.ExecutorMock
    |> deny(:buy, 3)

    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    # No position is ever created, so we give the async tasks time to finish
    # before asserting the count stays at zero
    Process.sleep(300)

    assert Repo.aggregate(SniperPosition, :count, :id) == 0
  end

  test "trigger resolves overlapping wallet by priority while unique wallet keeps its only sniper" do
    token =
      insert_token!(%{
        token_address: "token-priority-overlap",
        active: true,
        market_cap: 55_000.0,
        name: "Priority Overlap",
        ticker: "PO"
      })

    path =
      write_yaml!("""
      snipers:
        - id: sniper-x
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
            - second
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 100
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
        - id: sniper-z
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 500
          exit_tiers:
            - market_cap: 100000
              sell_percent: 100
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, 2, fn options ->
      case {options.sniper_id, options.wallet_id} do
        {"sniper-z", "main"} -> {:ok, 600.0}
        {"sniper-x", "second"} -> {:ok, 600.0}
      end
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, 2, fn %Token{token_address: "token-priority-overlap"}, 100_000_000, options ->
      assert options.amount_usdc == 100
      assert options.amount_usdc_raw == 100_000_000

      case {options.sniper_id, options.wallet_id} do
        {"sniper-z", "main"} ->
          {:ok, %{units: 1000.0, amount_usd: 100.0, tx_signature: "buy-overlap-main"}}

        {"sniper-x", "second"} ->
          {:ok, %{units: 1000.0, amount_usd: 100.0, tx_signature: "buy-overlap-second"}}
      end
    end)

    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    wait_until(fn ->
      Repo.aggregate(SniperPosition, :count, :id) == 2
    end)

    main_position =
      Repo.get_by!(
        SniperPosition,
        token_address: "token-priority-overlap",
        wallet_id: "main"
      )

    second_position =
      Repo.get_by!(
        SniperPosition,
        token_address: "token-priority-overlap",
        wallet_id: "second"
      )

    assert main_position.sniper_id == "sniper-z"
    assert second_position.sniper_id == "sniper-x"
  end

  test "trigger opens position and skips exit tiers below entry market cap" do
    now = ~N[2026-03-18 14:00:00]

    token =
      insert_token!(%{
        token_address: "token-alpha",
        active: true,
        market_cap: 60_000.0,
        name: "Alpha",
        ticker: "ALP"
      })

    path =
      write_yaml!("""
      snipers:
        - id: alpha
          trigger_on_notifiers:
            - early-microcap
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
            min_wallet_usdc: 50
          exit_tiers:
            - market_cap: 50000
              sell_percent: 25
            - market_cap: 90000
              sell_percent: 75
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    Bentley.Snipers.ExecutorMock
    |> expect(:wallet_usdc_balance, fn options ->
      assert options.wallet_id == "main"
      {:ok, 500.0}
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:buy, fn %Token{token_address: "token-alpha"}, 100_000_000, options ->
      assert options.wallet_id == "main"
      assert options.amount_usdc == 100
      assert options.amount_usdc_raw == 100_000_000
      {:ok, %{units: 1000.0, amount_usd: 100.0, tx_signature: "buy-1"}}
    end)

    assert :ok = Snipers.reload()
    assert :ok = Snipers.trigger_on_notification("early-microcap", token)

    wait_until(fn ->
      Repo.aggregate(SniperPosition, :count, :id) == 1
    end)

    position = Repo.get_by!(SniperPosition, sniper_id: "alpha", token_address: "token-alpha")
    assert position.initial_units == 1000.0
    assert position.remaining_units == 1000.0

    # 50k tier must be skipped because entry market cap is 60k.
    update_token_market_cap!(token.token_address, 95_000.0)

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn %Token{token_address: "token-alpha"}, units, _options ->
      assert_in_delta units, 750.0, 0.0001
      {:ok, %{units: units, amount_usd: 150.0, tx_signature: "sell-1"}}
    end)

    definition = hd(Snipers.loaded_definitions())

    assert {:ok, %{processed: 1, sells: 1, closed: 0, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert_in_delta refreshed.remaining_units, 250.0, 0.0001

    sell_tiers =
      SniperTrade
      |> Repo.all()
      |> Enum.filter(&(&1.trade_type == "sell"))
      |> Enum.map(& &1.tier_index)

    assert sell_tiers == [1]
  end

  test "three tiers summing to 100% fully close position without dust" do
    now = ~N[2026-03-18 14:00:00]
    # Use initial_units that don't divide evenly by the tier percentages,
    # to verify the last tier sells remaining_units (not a fractional nominal).
    token =
      insert_token!(%{
        token_address: "token-dust",
        name: "DustToken",
        symbol: "DUST",
        market_cap: 10_000.0,
        inserted_at: now,
        updated_at: now
      })

    path =
      write_yaml!("""
      snipers:
        - id: dust-test
          trigger_on_notifiers:
            - notifier-a
          wallet_ids:
            - main
          buy_config:
            enabled: true
            position_size_usd: 100
            slippage_bps: 50
          exit_tiers:
            - market_cap: 20000
              sell_percent: 30
            - market_cap: 30000
              sell_percent: 30
            - market_cap: 40000
              sell_percent: 40
      """)

    Application.put_env(:bentley, :snipers_file_path, path)

    {:ok, definitions} = Loader.load_from_file(path)
    definition = hd(definitions)

    # 1_000_000_007 is an odd number that produces float dust when divided by tier percentages.
    initial_units = 1_000_000_007.0

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: "dust-test",
        notifier_id: "notifier-a",
        token_address: "token-dust",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: initial_units,
        remaining_units: initial_units,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    # Tier 1 — 30%
    update_token_market_cap!(token.token_address, 20_000.0)
    expected_tier1 = min(initial_units, initial_units * 0.30)

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn _token, units, _opts ->
      assert_in_delta units, expected_tier1, 1.0
      {:ok, %{units: units, amount_usd: 30.0, tx_signature: "sell-t1"}}
    end)

    {:ok, _} = PositionManager.process_open_positions(definition, now)
    position = Repo.get!(SniperPosition, position.id)
    assert position.status == "open"

    # Tier 2 — 30%
    update_token_market_cap!(token.token_address, 30_000.0)
    expected_tier2 = min(position.remaining_units, initial_units * 0.30)

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn _token, units, _opts ->
      assert_in_delta units, expected_tier2, 1.0
      {:ok, %{units: units, amount_usd: 30.0, tx_signature: "sell-t2"}}
    end)

    {:ok, _} = PositionManager.process_open_positions(definition, now)
    position = Repo.get!(SniperPosition, position.id)
    assert position.status == "open"

    # Tier 3 — 40% nominal, but should sell ALL remaining units due to dust guard.
    update_token_market_cap!(token.token_address, 40_000.0)
    remaining_before_tier3 = position.remaining_units

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn _token, units, _opts ->
      # Must sell exactly remaining_units, not initial_units * 0.40 (which would be less).
      assert_in_delta units, remaining_before_tier3, 0.0001
      {:ok, %{units: units, amount_usd: 40.0, tx_signature: "sell-t3"}}
    end)

    {:ok, _} = PositionManager.process_open_positions(definition, now)
    position = Repo.get!(SniperPosition, position.id)

    assert position.status == "closed"
    assert position.remaining_units <= 1.0e-9
  end

  test "reconciliation closes position when on-chain balance is zero" do
    now = ~N[2026-03-18 14:00:00]
    opened_at = ~N[2026-03-18 13:58:00]

    _token =
      insert_token!(%{
        token_address: "token-reconcile-close",
        active: true,
        market_cap: 80_000.0,
        name: "ReconClose",
        ticker: "RC"
      })

    definition = %Definition{
      id: "reconcile-close",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      exit_tiers: [%{market_cap: 70_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: "reconcile-close",
        notifier_id: "early-microcap",
        token_address: "token-reconcile-close",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 500.0,
        status: "open",
        opened_at: opened_at
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:token_balance, 2, fn %Token{token_address: "token-reconcile-close"}, options ->
      assert options.wallet_id == "main"
      {:ok, 0}
    end)
    |> deny(:sell, 3)

    assert {:ok, %{processed: 1, sells: 0, closed: 1, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "closed"
    assert refreshed.remaining_units == 0.0
  end

  test "reconciliation keeps position open when zero balance is within grace window" do
    # Position opened 10 seconds before now — well inside the 60s grace window.
    # The RPC returning 0 here is the false-close race condition (indexer lag after buy).
    now = ~N[2026-03-18 14:00:00]
    opened_at = ~N[2026-03-18 13:59:50]

    _token =
      insert_token!(%{
        token_address: "token-reconcile-grace",
        active: true,
        market_cap: 50_000.0,
        name: "ReconGrace",
        ticker: "RG"
      })

    definition = %Definition{
      id: "reconcile-grace",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      exit_tiers: [%{market_cap: 70_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: "reconcile-grace",
        notifier_id: "early-microcap",
        token_address: "token-reconcile-grace",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 500.0,
        status: "open",
        opened_at: opened_at
      })
      |> Repo.insert()

    # RPC returns 0, but only called once — no double-check because grace window exits early.
    Bentley.Snipers.ExecutorMock
    |> expect(:token_balance, 1, fn %Token{token_address: "token-reconcile-grace"}, options ->
      assert options.wallet_id == "main"
      {:ok, 0}
    end)
    |> deny(:sell, 3)

    assert {:ok, %{processed: 1, sells: 0, closed: 0, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "open"
    assert refreshed.remaining_units == 500.0
  end

  test "manual sells are reconciled before tier calculations based on initial buy" do
    now = ~N[2026-03-18 14:00:00]

    _token =
      insert_token!(%{
        token_address: "token-manual-sell",
        active: true,
        market_cap: 30_000.0,
        name: "ManualSell",
        ticker: "MS"
      })

    definition = %Definition{
      id: "manual-sell",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      exit_tiers: [
        %{market_cap: 20_000, sell_percent: 30},
        %{market_cap: 30_000, sell_percent: 30},
        %{market_cap: 40_000, sell_percent: 40}
      ],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: "manual-sell",
        notifier_id: "early-microcap",
        token_address: "token-manual-sell",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 1000.0,
        remaining_units: 1000.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:token_balance, fn %Token{token_address: "token-manual-sell"}, _options ->
      # User manually sold half the position outside Bentley.
      {:ok, 500}
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn %Token{token_address: "token-manual-sell"}, units, _options ->
      # Tier 1 target is 30% of initial and is fully covered by manual sell.
      # Tier 2 cumulative target is 60% of initial, so sniper sells only 10% more.
      assert_in_delta units, 100.0, 0.0001
      {:ok, %{units: units, amount_usd: 20.0, tx_signature: "sell-manual-adjusted"}}
    end)

    assert {:ok, %{processed: 1, sells: 1, closed: 0, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "open"
    assert_in_delta refreshed.remaining_units, 400.0, 0.0001
  end

  test "manual buys do not increase managed remaining units" do
    now = ~N[2026-03-18 14:00:00]

    _token =
      insert_token!(%{
        token_address: "token-manual-buy",
        active: true,
        market_cap: 35_000.0,
        name: "ManualBuy",
        ticker: "MB"
      })

    definition = %Definition{
      id: "manual-buy",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      exit_tiers: [
        %{market_cap: 20_000, sell_percent: 30},
        %{market_cap: 30_000, sell_percent: 30}
      ],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: "manual-buy",
        notifier_id: "early-microcap",
        token_address: "token-manual-buy",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 1000.0,
        remaining_units: 700.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:token_balance, fn %Token{token_address: "token-manual-buy"}, _options ->
      # User manually bought more token outside Bentley.
      {:ok, 900}
    end)

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn %Token{token_address: "token-manual-buy"}, units, _options ->
      # Managed state already sold 30% (remaining 700). Tier 2 should sell another 30% of initial.
      assert_in_delta units, 300.0, 0.0001
      {:ok, %{units: units, amount_usd: 60.0, tx_signature: "sell-managed-only"}}
    end)

    assert {:ok, %{processed: 1, sells: 1, closed: 0, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "open"
    assert_in_delta refreshed.remaining_units, 400.0, 0.0001
  end

  test "process_open_positions sends telegram message on sell success" do
    now = ~N[2026-03-18 14:00:00]

    _token =
      insert_token!(%{
        token_address: "token-sell-success",
        active: true,
        market_cap: 70_000.0,
        name: "Sell Success",
        ticker: "SYS"
      })

    definition = %Definition{
      id: "sell-success",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    {:ok, _position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: definition.id,
        notifier_id: "early-microcap",
        token_address: "token-sell-success",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 500.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:token_balance, fn %Token{token_address: "token-sell-success"}, _options ->
      {:ok, 500}
    end)
    |> expect(:sell, fn %Token{token_address: "token-sell-success"}, 500.0, _options ->
      {:ok, %{units: 500.0, amount_usd: 150.0, tx_signature: "sell-success"}}
    end)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main just sold 500 $SYS"
      :ok
    end)

    assert {:ok, %{processed: 1, sells: 1, closed: 1, failed: 0}} =
             PositionManager.process_open_positions(definition, now)
  end

  test "process_open_positions sends telegram message on sell failure" do
    now = ~N[2026-03-18 14:00:00]

    _token =
      insert_token!(%{
        token_address: "token-sell-failure",
        active: true,
        market_cap: 70_000.0,
        name: "Sell Failure",
        ticker: "SYF"
      })

    definition = %Definition{
      id: "sell-failure",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    {:ok, _position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: definition.id,
        notifier_id: "early-microcap",
        token_address: "token-sell-failure",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 500.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:token_balance, fn %Token{token_address: "token-sell-failure"}, _options ->
      {:ok, 500}
    end)
    |> expect(:sell, fn %Token{token_address: "token-sell-failure"}, 500.0, _options ->
      {:error, :sell_quote_failed}
    end)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main failed to sell $SYF (reason: :sell_quote_failed)"
      :ok
    end)

    assert {:ok, %{processed: 1, sells: 0, closed: 0, failed: 1}} =
             PositionManager.process_open_positions(definition, now)
  end

  test "process_open_positions sells all when token row is missing" do
    now = ~N[2026-03-18 14:00:00]

    definition = %Definition{
      id: "missing-token-sell-success",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: definition.id,
        notifier_id: "early-microcap",
        token_address: "token-row-missing-success",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 500.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn %Token{token_address: "token-row-missing-success"}, 500.0, _options ->
      {:ok, %{units: 500.0, amount_usd: 12.0, tx_signature: "sell-missing-token-success"}}
    end)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main just sold 500 token-row-missing-success"
      :ok
    end)

    assert {:ok, %{processed: 1, sells: 1, closed: 1, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "closed"
    assert refreshed.remaining_units == 0.0

    trade = Repo.get_by!(SniperTrade, sniper_position_id: position.id, trade_type: "sell")
    assert trade.reason == "token_row_missing"
    assert trade.market_cap == nil
  end

  test "process_open_positions retries later when token row missing sell fails" do
    now = ~N[2026-03-18 14:00:00]

    definition = %Definition{
      id: "missing-token-sell-failure",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      telegram_channel: "@sniper",
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: definition.id,
        notifier_id: "early-microcap",
        token_address: "token-row-missing-failure",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 500.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> expect(:sell, fn %Token{token_address: "token-row-missing-failure"}, 500.0, _options ->
      {:error, :no_route}
    end)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@sniper", message ->
      assert message == "main failed to sell token-row-missing-failure (reason: :no_route)"
      :ok
    end)

    assert {:ok, %{processed: 1, sells: 0, closed: 0, failed: 1}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "open"
    assert refreshed.remaining_units == 500.0

    assert Repo.aggregate(SniperTrade, :count, :id) == 0
  end

  test "process_open_positions closes missing-token positions with zero remaining units without sell" do
    now = ~N[2026-03-18 14:00:00]

    definition = %Definition{
      id: "missing-token-zero-remaining",
      trigger_on_notifier_ids: ["early-microcap"],
      wallet_ids: ["main"],
      exit_tiers: [%{market_cap: 60_000, sell_percent: 100}],
      buy_config: %{enabled: true, position_size_usd: 100, slippage_bps: 50, min_wallet_usdc: nil}
    }

    {:ok, position} =
      %SniperPosition{}
      |> SniperPosition.changeset(%{
        sniper_id: definition.id,
        notifier_id: "early-microcap",
        token_address: "token-row-missing-zero",
        wallet_id: "main",
        entry_market_cap: 10_000.0,
        position_size_usd: 100.0,
        initial_units: 500.0,
        remaining_units: 0.0,
        status: "open",
        opened_at: now
      })
      |> Repo.insert()

    Bentley.Snipers.ExecutorMock
    |> deny(:sell, 3)

    assert {:ok, %{processed: 1, sells: 0, closed: 1, failed: 0}} =
             PositionManager.process_open_positions(definition, now)

    refreshed = Repo.get!(SniperPosition, position.id)
    assert refreshed.status == "closed"
    assert refreshed.remaining_units == 0.0
  end

  defp insert_token!(attrs) do
    %Token{}
    |> Token.changeset(attrs)
    |> Repo.insert!()
  end

  defp update_token_market_cap!(token_address, market_cap) do
    token = Repo.get_by!(Token, token_address: token_address)

    token
    |> Token.changeset(%{market_cap: market_cap})
    |> Repo.update!()
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, 0) do
    assert fun.()
  end

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp write_yaml!(contents) do
    path = Path.join(System.tmp_dir!(), "snipers_#{System.unique_integer([:positive])}.yml")
    File.write!(path, contents)

    on_exit(fn ->
      File.rm(path)
    end)

    path
  end
end

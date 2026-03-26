defmodule Bentley.Snipers.Executor.JupiterTest do
  use ExUnit.Case, async: true

  import Mox

  alias Bentley.Schema.Token
  alias Bentley.Snipers.Executor.Jupiter

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous_http_client = Application.get_env(:bentley, :jupiter_http_client)
    previous_rpc_http_client = Application.get_env(:bentley, :solana_rpc_http_client)
    previous_jupiter_req_options = Application.get_env(:bentley, :jupiter_req_options)
    previous_rpc_options = Application.get_env(:bentley, :solana_rpc_req_options)
    previous_wallet = System.get_env("SOLANA_WALLET_test")
    previous_requote_attempts = System.get_env("SNIPER_REQUOTE_RETRY_ATTEMPTS")
    previous_requote_delay = System.get_env("SNIPER_REQUOTE_RETRY_DELAY_MS")

    Application.put_env(:bentley, :jupiter_http_client, Bentley.Snipers.JupiterHttpClientMock)
    Application.put_env(:bentley, :solana_rpc_http_client, Bentley.Snipers.SolanaRpcHttpClientMock)
    Application.put_env(:bentley, :jupiter_req_options, [])
    Application.put_env(:bentley, :solana_rpc_req_options, [])

    System.put_env("SOLANA_WALLET_test", Jason.encode!(Enum.to_list(1..32)))

    System.put_env("SNIPER_REQUOTE_RETRY_ATTEMPTS", "1")
    System.put_env("SNIPER_REQUOTE_RETRY_DELAY_MS", "0")

    on_exit(fn ->
      restore_app_env(:jupiter_http_client, previous_http_client)
      restore_app_env(:solana_rpc_http_client, previous_rpc_http_client)
      restore_app_env(:jupiter_req_options, previous_jupiter_req_options)
      restore_app_env(:solana_rpc_req_options, previous_rpc_options)
      restore_system_env("SOLANA_WALLET_test", previous_wallet)
      restore_system_env("SNIPER_REQUOTE_RETRY_ATTEMPTS", previous_requote_attempts)
      restore_system_env("SNIPER_REQUOTE_RETRY_DELAY_MS", previous_requote_delay)
    end)

    :ok
  end

  test "confirmation_succeeded?/1 returns true for finalized tx without error" do
    status = %{"confirmationStatus" => "finalized", "err" => nil}
    assert Jupiter.confirmation_succeeded?(status)
  end

  test "confirmation_succeeded?/1 returns true for confirmed tx without error" do
    status = %{"confirmationStatus" => "confirmed", "err" => nil}
    assert Jupiter.confirmation_succeeded?(status)
  end

  test "confirmation_succeeded?/1 returns false for finalized tx with error" do
    status = %{
      "confirmationStatus" => "finalized",
      "err" => %{"InstructionError" => [4, %{"Custom" => 6001}]}
    }

    refute Jupiter.confirmation_succeeded?(status)
  end

  test "retryable_transaction_failure?/1 returns true for custom 6001" do
    reason = %{"InstructionError" => [4, %{"Custom" => 6001}]}
    assert Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_transaction_failure?/1 returns true for custom 6017" do
    reason = %{"InstructionError" => [4, %{"Custom" => 6017}]}
    assert Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_transaction_failure?/1 returns true for custom string 6001" do
    reason = %{"InstructionError" => [4, %{"Custom" => "6001"}]}
    assert Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_transaction_failure?/1 returns true for custom string 6017" do
    reason = %{"InstructionError" => [4, %{"Custom" => "6017"}]}
    assert Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_transaction_failure?/1 returns false for non-retryable custom error" do
    reason = %{"InstructionError" => [4, %{"Custom" => 7001}]}
    refute Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_transaction_failure?/1 returns false for non-custom instruction errors" do
    reason = %{"InstructionError" => [4, :InsufficientFunds]}
    refute Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_send_transaction_failure?/1 returns true for nested custom 6017" do
    reason = %{
      "code" => -32002,
      "message" => "Transaction simulation failed",
      "data" => %{"err" => %{"InstructionError" => [4, %{"Custom" => 6017}]}}
    }

    assert Jupiter.retryable_send_transaction_failure?(reason)
  end

  test "retryable_send_transaction_failure?/1 returns false for non-retryable nested custom error" do
    reason = %{
      "code" => -32002,
      "message" => "Transaction simulation failed",
      "data" => %{"err" => %{"InstructionError" => [4, %{"Custom" => 7001}]}}
    }

    refute Jupiter.retryable_send_transaction_failure?(reason)
  end

  test "buy/3 requotes and retries once on custom 6017 failure" do
    token = %Token{token_address: "token-6017"}
    initial_quote = %{"outAmount" => "900", "quoteId" => "initial"}
    refreshed_quote = %{"outAmount" => "925", "quoteId" => "refreshed"}
    signed_tx = Base.encode64(<<1, 0::size(64 * 8), 1, 2, 3>>)

    Bentley.Snipers.JupiterHttpClientMock
    |> expect(:get, fn "https://api.jup.ag/swap/v1/quote", options ->
      assert Keyword.get(options, :params)[:amount] == 100_000_000
      {:ok, %{status: 200, body: initial_quote}}
    end)
    |> expect(:post, fn "https://api.jup.ag/swap/v1/swap", options ->
      assert options[:json]["quoteResponse"] == initial_quote
      {:ok, %{status: 200, body: %{"swapTransaction" => signed_tx}}}
    end)
    |> expect(:get, fn "https://api.jup.ag/swap/v1/quote", options ->
      assert Keyword.get(options, :params)[:amount] == 100_000_000
      {:ok, %{status: 200, body: refreshed_quote}}
    end)
    |> expect(:post, fn "https://api.jup.ag/swap/v1/swap", options ->
      assert options[:json]["quoteResponse"] == refreshed_quote
      {:ok, %{status: 200, body: %{"swapTransaction" => signed_tx}}}
    end)

    stub(Bentley.Snipers.SolanaRpcHttpClientMock, :post, fn _url, options ->
      body = options[:json]

      case body["method"] do
        "getTokenAccountsByOwner" ->
          balance_lookup_count = Process.get(:balance_lookup_count, 0)
          Process.put(:balance_lookup_count, balance_lookup_count + 1)

          amount = if balance_lookup_count == 0, do: "0", else: "925"

          {:ok,
           %{
             status: 200,
             body: %{
               "result" => %{
                 "value" => [
                   %{
                     "account" => %{
                       "data" => %{
                         "parsed" => %{
                           "info" => %{
                             "tokenAmount" => %{"amount" => amount}
                           }
                         }
                       }
                     }
                   }
                 ]
               }
             }
           }}

        "sendTransaction" ->
          send(self(), {:send_transaction_attempt, body["params"]})

          send_attempt = Process.get(:send_attempt, 0)
          Process.put(:send_attempt, send_attempt + 1)

          case send_attempt do
            0 ->
              {:ok,
               %{
                 status: 200,
                 body: %{
                   "error" => %{
                     "code" => -32002,
                     "message" => "Transaction simulation failed",
                     "data" => %{
                       "err" => %{"InstructionError" => [4, %{"Custom" => 6017}]}
                     }
                   }
                 }
               }}

            1 ->
              {:ok, %{status: 200, body: %{"result" => "tx-6017-success"}}}
          end

        "getSignatureStatuses" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "result" => %{
                 "value" => [
                   %{
                     "err" => nil,
                     "confirmationStatus" => "confirmed"
                   }
                 ]
               }
             }
           }}
      end
    end)

    assert {:ok, %{units: 925, amount_usd: 100.0, tx_signature: "tx-6017-success"}} =
             Jupiter.buy(token, 100_000_000, %{wallet_id: "test", amount_usdc: 100.0})

    assert_received {:send_transaction_attempt, [_signed_tx, _config]}
    assert_received {:send_transaction_attempt, [_signed_tx, _config]}
  end

  test "derive_buy_units/3 prefers positive balance delta" do
    quote = %{"outAmount" => "900"}
    assert Jupiter.derive_buy_units(1_000, 1_250, quote) == 250
  end

  test "derive_buy_units/3 falls back to quote outAmount when delta is non-positive" do
    quote = %{"outAmount" => "900"}
    assert Jupiter.derive_buy_units(1_000, 1_000, quote) == 900
  end

  test "derive_buy_units/3 returns 0 when delta is non-positive and quote outAmount is invalid" do
    quote = %{"outAmount" => "not-an-int"}
    assert Jupiter.derive_buy_units(1_000, 900, quote) == 0
  end

  test "recover_units_from_balance_delta/2 returns positive delta" do
    assert Jupiter.recover_units_from_balance_delta(200, 260) == {:ok, 60}
  end

  test "recover_units_from_balance_delta/2 returns timeout error when no positive delta" do
    assert Jupiter.recover_units_from_balance_delta(300, 300) == {:error, :buy_unconfirmed_timeout}
    assert Jupiter.recover_units_from_balance_delta(300, 250) == {:error, :buy_unconfirmed_timeout}
  end

  test "recover_sold_units_from_balance_delta/2 returns positive sold delta" do
    assert Jupiter.recover_sold_units_from_balance_delta(260, 200) == {:ok, 60}
  end

  test "recover_sold_units_from_balance_delta/2 returns timeout error when no positive sold delta" do
    assert Jupiter.recover_sold_units_from_balance_delta(300, 300) ==
             {:error, :sell_unconfirmed_timeout}

    assert Jupiter.recover_sold_units_from_balance_delta(250, 300) ==
             {:error, :sell_unconfirmed_timeout}
  end

  test "validate_recovered_delta/2 accepts delta within 5% tolerance of expected" do
    quote = %{"outAmount" => "1000"}
    assert Jupiter.validate_recovered_delta(1000, quote) == :ok
    assert Jupiter.validate_recovered_delta(950, quote) == :ok
    assert Jupiter.validate_recovered_delta(1050, quote) == :ok
  end

  test "validate_recovered_delta/2 rejects delta outside 5% tolerance" do
    quote = %{"outAmount" => "1000"}
    assert Jupiter.validate_recovered_delta(900, quote) == {:error, :delta_mismatch}
    assert Jupiter.validate_recovered_delta(1100, quote) == {:error, :delta_mismatch}
  end

  test "validate_recovered_delta/2 rejects non-positive delta" do
    quote = %{"outAmount" => "1000"}
    assert Jupiter.validate_recovered_delta(0, quote) == {:error, :delta_mismatch}
    assert Jupiter.validate_recovered_delta(-100, quote) == {:error, :delta_mismatch}
  end

  test "validate_recovered_delta/2 rejects invalid quote" do
    quote = %{"outAmount" => "not-an-int"}
    assert Jupiter.validate_recovered_delta(1000, quote) == {:error, :delta_mismatch}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:bentley, key)
  defp restore_app_env(key, value), do: Application.put_env(:bentley, key, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end

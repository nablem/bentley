defmodule Bentley.Snipers.Executor.JupiterTest do
  use ExUnit.Case, async: true

  alias Bentley.Snipers.Executor.Jupiter

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

  test "retryable_transaction_failure?/1 returns false for non-6001 custom error" do
    reason = %{"InstructionError" => [4, %{"Custom" => 7001}]}
    refute Jupiter.retryable_transaction_failure?(reason)
  end

  test "retryable_transaction_failure?/1 returns false for non-custom instruction errors" do
    reason = %{"InstructionError" => [4, :InsufficientFunds]}
    refute Jupiter.retryable_transaction_failure?(reason)
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
end

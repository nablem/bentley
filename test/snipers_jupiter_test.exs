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
end

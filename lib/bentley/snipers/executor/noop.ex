defmodule Bentley.Snipers.Executor.Noop do
  @moduledoc """
  Default sniper executor that does not execute trades.

  Configure `:bentley, :sniper_executor` with a real implementation to enable live trading.
  """

  @behaviour Bentley.Snipers.Executor

  @impl true
  def buy(_token, _amount_usdc_raw, _options), do: {:error, :sniper_executor_not_configured}

  @impl true
  def sell(_token, _units, _options), do: {:error, :sniper_executor_not_configured}

  @impl true
  def wallet_usdc_balance(_options), do: {:error, :sniper_executor_not_configured}
end

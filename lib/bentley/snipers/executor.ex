defmodule Bentley.Snipers.Executor do
  @moduledoc """
  Behaviour for buy/sell execution used by snipers.

  Implementations are selected via `:bentley, :sniper_executor`.
  """

  @type trade_result :: %{
          required(:units) => number(),
          optional(:amount_usd) => number(),
          optional(:tx_signature) => String.t() | nil
        }

  @type options :: %{
          optional(:sniper_id) => String.t(),
          optional(:wallet_id) => String.t(),
          optional(:slippage_bps) => pos_integer(),
          optional(:max_slippage_percent) => number() | nil,
          optional(:trade_type) => :buy | :sell
        }

  @callback buy(struct(), pos_integer(), options()) :: {:ok, trade_result()} | {:error, term()}
  @callback sell(struct(), number(), options()) :: {:ok, trade_result()} | {:error, term()}
  @callback wallet_usdc_balance(options()) :: {:ok, number()} | {:error, term()}
  @callback token_balance(struct(), options()) :: {:ok, number()} | {:error, term()}
end

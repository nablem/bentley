defmodule Bentley.Snipers.Manual do
  @moduledoc """
  Manual live trade helpers for sniper executor operations.

  This module is intended for operator-driven ad-hoc trades from IEx or Mix tasks.
  """

  alias Bentley.Schema.Token

  @usdc_base_unit_scale 1_000_000
  @default_slippage_bps 50

  @spec buy(String.t(), String.t(), number(), keyword()) :: {:ok, map()} | {:error, term()}
  def buy(wallet_id, token_address, amount_usdc, opts \\ [])

  def buy(wallet_id, token_address, amount_usdc, opts)
      when is_binary(wallet_id) and is_binary(token_address) and is_number(amount_usdc) do
    with {:ok, normalized_wallet_id} <- normalize_string(wallet_id, :wallet_id),
         {:ok, normalized_token_address} <- normalize_string(token_address, :token_address),
         {:ok, amount_usdc} <- normalize_amount(amount_usdc),
         {:ok, amount_usdc_raw} <- to_usdc_base_units(amount_usdc) do
      slippage_bps = Keyword.get(opts, :slippage_bps, @default_slippage_bps)
      max_slippage_percent = Keyword.get(opts, :max_slippage_percent)

      executor().buy(%Token{token_address: normalized_token_address}, amount_usdc_raw, %{
        sniper_id: "manual",
        wallet_id: normalized_wallet_id,
        trade_type: :buy,
        amount_usdc: amount_usdc,
        amount_usdc_raw: amount_usdc_raw,
        slippage_bps: slippage_bps,
        max_slippage_percent: max_slippage_percent
      })
    end
  end

  def buy(_wallet_id, _token_address, _amount_usdc, _opts), do: {:error, :invalid_manual_buy_input}

  defp executor do
    Application.get_env(:bentley, :sniper_executor, Bentley.Snipers.Executor.Noop)
  end

  defp normalize_string(value, field) do
    case String.trim(value) do
      "" -> {:error, {:missing_required_value, field}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_amount(amount_usdc) when is_integer(amount_usdc) and amount_usdc > 0,
    do: {:ok, amount_usdc * 1.0}

  defp normalize_amount(amount_usdc) when is_float(amount_usdc) and amount_usdc > 0,
    do: {:ok, amount_usdc}

  defp normalize_amount(_amount_usdc), do: {:error, :invalid_amount_usdc}

  defp to_usdc_base_units(amount_usdc) do
    amount_usdc_raw =
      amount_usdc
      |> to_string()
      |> Decimal.new()
      |> Decimal.mult(Decimal.new(@usdc_base_unit_scale))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    if amount_usdc_raw > 0 do
      {:ok, amount_usdc_raw}
    else
      {:error, :invalid_amount_usdc}
    end
  end
end

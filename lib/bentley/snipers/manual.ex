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

  @spec sell(String.t(), String.t(), number(), keyword()) :: {:ok, map()} | {:error, term()}
  def sell(wallet_id, token_address, units, opts \\ [])

  def sell(wallet_id, token_address, units, opts)
      when is_binary(wallet_id) and is_binary(token_address) and is_number(units) do
    with {:ok, normalized_wallet_id} <- normalize_string(wallet_id, :wallet_id),
         {:ok, normalized_token_address} <- normalize_string(token_address, :token_address),
         {:ok, normalized_units} <- normalize_units(units) do
      slippage_bps = Keyword.get(opts, :slippage_bps, @default_slippage_bps)
      max_slippage_percent = Keyword.get(opts, :max_slippage_percent)

      executor().sell(%Token{token_address: normalized_token_address}, normalized_units, %{
        sniper_id: "manual",
        wallet_id: normalized_wallet_id,
        trade_type: :sell,
        units: normalized_units,
        slippage_bps: slippage_bps,
        max_slippage_percent: max_slippage_percent
      })
    end
  end

  def sell(_wallet_id, _token_address, _units, _opts), do: {:error, :invalid_manual_sell_input}

  @spec token_balance(String.t(), String.t()) :: {:ok, number()} | {:error, term()}
  def token_balance(wallet_id, token_address)
      when is_binary(wallet_id) and is_binary(token_address) do
    with {:ok, normalized_wallet_id} <- normalize_string(wallet_id, :wallet_id),
         {:ok, normalized_token_address} <- normalize_string(token_address, :token_address) do
      executor().token_balance(%Token{token_address: normalized_token_address}, %{
        sniper_id: "manual",
        wallet_id: normalized_wallet_id
      })
    end
  end

  def token_balance(_wallet_id, _token_address), do: {:error, :invalid_token_balance_input}

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

  defp normalize_units(units) when is_integer(units) and units > 0, do: {:ok, units}
  defp normalize_units(units) when is_float(units) and units > 0, do: {:ok, units}
  defp normalize_units(_units), do: {:error, :invalid_units}

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

defmodule Mix.Tasks.Sniper.Buy do
  @shortdoc "Execute a manual live sniper buy"
  @moduledoc """
  Executes a manual live buy using the configured sniper executor.

  Usage:

      mix sniper.buy <wallet_id> <token_address> <amount_usdc> [--slippage-bps 50] [--max-slippage-percent 15]

  Example:

      mix sniper.buy mywallet DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263 200
  """

  use Mix.Task
  @requirements ["app.config"]

  @impl true
  def run(args) do
    ensure_swap_dependencies_started!()

    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [slippage_bps: :integer, max_slippage_percent: :float],
        aliases: [s: :slippage_bps]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    case positional do
      [wallet_id, token_address, amount_usdc_raw] ->
        amount_usdc = parse_amount(amount_usdc_raw)

        opts =
          []
          |> maybe_put(:slippage_bps, options[:slippage_bps])
          |> maybe_put(:max_slippage_percent, options[:max_slippage_percent])

        case Bentley.Snipers.Manual.buy(wallet_id, token_address, amount_usdc, opts) do
          {:ok, result} ->
            Mix.shell().info("Manual buy submitted successfully")
            Mix.shell().info("wallet_id: #{wallet_id}")
            Mix.shell().info("token_address: #{token_address}")
            Mix.shell().info("units_bought(raw): #{inspect(result[:units])}")
            Mix.shell().info("amount_usdc: #{inspect(result[:amount_usd])}")
            Mix.shell().info("tx_signature: #{inspect(result[:tx_signature])}")

          {:error, reason} ->
            Mix.raise("Manual buy failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("Usage: mix sniper.buy <wallet_id> <token_address> <amount_usdc> [--slippage-bps 50] [--max-slippage-percent 15]")
    end
  end

  defp parse_amount(amount_usdc_raw) do
    case Float.parse(amount_usdc_raw) do
      {amount_usdc, ""} when amount_usdc > 0 -> amount_usdc
      _ -> Mix.raise("Invalid amount_usdc: #{inspect(amount_usdc_raw)}")
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp ensure_swap_dependencies_started! do
    case Application.ensure_all_started(:req) do
      {:ok, _started_apps} -> :ok
      {:error, reason} -> Mix.raise("Failed to start swap dependencies: #{inspect(reason)}")
    end
  end
end

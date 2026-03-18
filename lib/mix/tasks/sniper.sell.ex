defmodule Mix.Tasks.Sniper.Sell do
  @shortdoc "Execute a manual live sniper sell"
  @moduledoc """
  Executes a manual live sell using the configured sniper executor.

  Usage:

      mix sniper.sell <wallet_id> <token_address> <units> [--slippage-bps 50] [--max-slippage-percent 15]
      mix sniper.sell <wallet_id> <token_address> --all [--slippage-bps 50] [--max-slippage-percent 15]

  Example:

      mix sniper.sell mywallet DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263 150000
      mix sniper.sell mywallet DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263 --all
  """

  use Mix.Task
  @requirements ["app.config"]

  @impl true
  def run(args) do
    ensure_swap_dependencies_started!()

    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [slippage_bps: :integer, max_slippage_percent: :float, all: :boolean],
        aliases: [s: :slippage_bps]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    case positional do
      [wallet_id, token_address, units_raw] ->
        units =
          if options[:all] do
            Mix.raise("Provide either <units> or --all, not both")
          else
            parse_units(units_raw)
          end

        execute_sell(wallet_id, token_address, units, options)

      [wallet_id, token_address] ->
        if options[:all] do
          units = fetch_all_units(wallet_id, token_address)
          execute_sell(wallet_id, token_address, units, options)
        else
          Mix.raise(
            "Usage: mix sniper.sell <wallet_id> <token_address> <units> [--slippage-bps 50] [--max-slippage-percent 15]\n" <>
              "   or: mix sniper.sell <wallet_id> <token_address> --all [--slippage-bps 50] [--max-slippage-percent 15]"
          )
        end

      _ ->
        Mix.raise(
          "Usage: mix sniper.sell <wallet_id> <token_address> <units> [--slippage-bps 50] [--max-slippage-percent 15]\n" <>
            "   or: mix sniper.sell <wallet_id> <token_address> --all [--slippage-bps 50] [--max-slippage-percent 15]"
        )
    end
  end

  defp execute_sell(wallet_id, token_address, units, options) do
    opts =
      []
      |> maybe_put(:slippage_bps, options[:slippage_bps])
      |> maybe_put(:max_slippage_percent, options[:max_slippage_percent])

    case Bentley.Snipers.Manual.sell(wallet_id, token_address, units, opts) do
      {:ok, result} ->
        Mix.shell().info("Manual sell submitted successfully")
        Mix.shell().info("wallet_id: #{wallet_id}")
        Mix.shell().info("token_address: #{token_address}")
        Mix.shell().info("units_sold(raw): #{inspect(result[:units])}")
        Mix.shell().info("amount_usdc: #{inspect(result[:amount_usd])}")
        Mix.shell().info("tx_signature: #{inspect(result[:tx_signature])}")

      {:error, {:jupiter_quote_failed, 400, %{"errorCode" => "NO_ROUTES_FOUND"} = body}} ->
        Mix.raise(
          "Manual sell failed: #{inspect({:jupiter_quote_failed, 400, body})}\n" <>
            "Hint: <units> is token base units (raw). Value 1 is usually dust and often unroutable. " <>
            "Try a larger raw amount or use --all to sell your full token balance."
        )

      {:error, reason} ->
        Mix.raise("Manual sell failed: #{inspect(reason)}")
    end
  end

  defp fetch_all_units(wallet_id, token_address) do
    case Bentley.Snipers.Manual.token_balance(wallet_id, token_address) do
      {:ok, units} when is_number(units) and units > 0 -> units
      {:ok, units} when is_number(units) -> Mix.raise("Nothing to sell: token balance is #{units}")
      {:error, reason} -> Mix.raise("Failed to fetch token balance for --all: #{inspect(reason)}")
    end
  end

  defp parse_units(units_raw) do
    case Float.parse(units_raw) do
      {units, ""} when units > 0 -> units
      _ -> Mix.raise("Invalid units: #{inspect(units_raw)}")
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

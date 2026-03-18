defmodule Bentley.Snipers.Env do
  @moduledoc """
  Environment variable access helpers for Solana sniper integrations.

  This module standardizes env variable names expected by Solana/Jupiter-based
  sniper executor implementations.
  """

  @jupiter_api_key_var "JUPITER_API_KEY"
  @solana_wallet_prefix "SOLANA_WALLET_"

  @spec jupiter_api_key_var() :: String.t()
  def jupiter_api_key_var, do: @jupiter_api_key_var

  @spec solana_wallet_prefix() :: String.t()
  def solana_wallet_prefix, do: @solana_wallet_prefix

  @spec solana_wallet_var(String.t()) :: String.t()
  def solana_wallet_var(wallet_id) when is_binary(wallet_id) do
    @solana_wallet_prefix <> String.trim(wallet_id)
  end

  @spec fetch_jupiter_api_key() :: {:ok, String.t()} | {:error, :missing_jupiter_api_key}
  def fetch_jupiter_api_key do
    case System.get_env(@jupiter_api_key_var) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_jupiter_api_key}
          key -> {:ok, key}
        end

      _ ->
        {:error, :missing_jupiter_api_key}
    end
  end

  @spec fetch_solana_wallet_private_key(String.t()) ::
          {:ok, String.t()} | {:error, {:missing_solana_wallet, String.t()}}
  def fetch_solana_wallet_private_key(wallet_id) when is_binary(wallet_id) do
    env_var = solana_wallet_var(wallet_id)

    case System.get_env(env_var) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_solana_wallet, env_var}}
          key -> {:ok, key}
        end

      _ ->
        {:error, {:missing_solana_wallet, env_var}}
    end
  end
end

defmodule Bentley.Snipers.EnvTest do
  use ExUnit.Case, async: false

  alias Bentley.Snipers.Env

  test "solana wallet env variable name includes wallet id" do
    assert Env.solana_wallet_var("main") == "SOLANA_WALLET_main"
  end

  test "fetch_jupiter_api_key returns missing when unset" do
    previous = System.get_env("JUPITER_API_KEY")

    System.delete_env("JUPITER_API_KEY")

    assert {:error, :missing_jupiter_api_key} = Env.fetch_jupiter_api_key()

    restore_env("JUPITER_API_KEY", previous)
  end

  test "fetch_solana_wallet_private_key returns missing when unset" do
    previous = System.get_env("SOLANA_WALLET_main")

    System.delete_env("SOLANA_WALLET_main")

    assert {:error, {:missing_solana_wallet, "SOLANA_WALLET_main"}} =
             Env.fetch_solana_wallet_private_key("main")

    restore_env("SOLANA_WALLET_main", previous)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

defmodule Bentley.Repo.Migrations.AddWalletIdToSniperPositionUniqueness do
  use Ecto.Migration

  def change do
    drop_if_exists(index(:sniper_positions, [:sniper_id, :token_address]))

    create unique_index(:sniper_positions, [:sniper_id, :wallet_id, :token_address])
  end
end

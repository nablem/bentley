defmodule Bentley.Repo.Migrations.CreateSniperPositionsAndTrades do
  use Ecto.Migration

  def change do
    create table(:sniper_positions) do
      add :sniper_id, :string, null: false
      add :notifier_id, :string, null: false
      add :token_address, :string, null: false
      add :wallet_id, :string, null: false
      add :entry_market_cap, :float
      add :position_size_usd, :float, null: false
      add :initial_units, :float, null: false
      add :remaining_units, :float, null: false
      add :status, :string, null: false, default: "open"
      add :opened_at, :naive_datetime, null: false
      add :closed_at, :naive_datetime

      timestamps()
    end

    create unique_index(:sniper_positions, [:sniper_id, :token_address])
    create index(:sniper_positions, [:sniper_id, :status])
    create index(:sniper_positions, [:token_address])

    create table(:sniper_trades) do
      add :sniper_position_id, references(:sniper_positions, on_delete: :delete_all), null: false
      add :trade_type, :string, null: false
      add :tier_index, :integer
      add :units, :float, null: false
      add :amount_usd, :float
      add :tx_signature, :string
      add :market_cap, :float
      add :reason, :string
      add :executed_at, :naive_datetime, null: false

      timestamps(updated_at: false)
    end

    create index(:sniper_trades, [:sniper_position_id])
    create index(:sniper_trades, [:trade_type])

    create unique_index(
      :sniper_trades,
      [:sniper_position_id, :tier_index],
      where: "trade_type = 'sell' AND tier_index IS NOT NULL",
      name: :sniper_trades_sell_tier_unique_index
    )
  end
end

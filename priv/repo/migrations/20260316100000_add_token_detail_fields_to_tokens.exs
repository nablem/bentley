defmodule Bentley.Repo.Migrations.AddTokenDetailFieldsToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add :website_url, :string
      add :x_url, :string
      add :telegram_url, :string
      add :boost, :integer
      add :created_on_chain_at, :naive_datetime
      add :name, :string
      add :ticker, :string
      add :change_24h, :float
      add :liquidity, :float
    end
  end
end

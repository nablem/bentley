defmodule Bentley.Repo.Migrations.CreateTokens do
  use Ecto.Migration

  def change do
    create table(:tokens) do
      add :token_address, :string, null: false
      add :url, :string
      add :icon, :string
      add :description, :text
      add :market_cap, :float
      add :volume_1h, :float
      add :volume_6h, :float
      add :volume_24h, :float
      add :change_1h, :float
      add :change_6h, :float
      add :last_checked_at, :naive_datetime

      timestamps()
    end

    create unique_index(:tokens, [:token_address])
  end
end

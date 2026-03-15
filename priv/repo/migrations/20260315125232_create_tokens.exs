defmodule Bentley.Repo.Migrations.CreateTokens do
  use Ecto.Migration

  def change do
    create table(:tokens) do
      add :token_address, :string, null: false
      add :url, :string
      add :icon, :string
      add :description, :text

      timestamps()
    end

    create unique_index(:tokens, [:token_address])
  end
end

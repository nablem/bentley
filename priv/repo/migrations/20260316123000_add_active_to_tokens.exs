defmodule Bentley.Repo.Migrations.AddActiveToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add :active, :boolean, null: false, default: true
    end
  end
end

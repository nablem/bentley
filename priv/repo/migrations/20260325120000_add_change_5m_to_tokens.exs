defmodule Bentley.Repo.Migrations.AddChange5mToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add :change_5m, :float
    end
  end
end

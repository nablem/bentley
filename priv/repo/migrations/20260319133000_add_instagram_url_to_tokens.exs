defmodule Bentley.Repo.Migrations.AddInstagramUrlToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add :instagram_url, :string
    end
  end
end

defmodule Bentley.Repo.Migrations.AddAthToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add(:ath, :float)
    end
  end
end

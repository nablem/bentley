defmodule Bentley.Repo.Migrations.AddInactivityReasonToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add :inactivity_reason, :string
    end
  end
end

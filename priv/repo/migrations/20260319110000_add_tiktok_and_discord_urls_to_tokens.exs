defmodule Bentley.Repo.Migrations.AddTiktokAndDiscordUrlsToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add :tiktok_url, :string
      add :discord_url, :string
    end
  end
end

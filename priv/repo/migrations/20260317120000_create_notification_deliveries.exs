defmodule Bentley.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  def change do
    create table(:notification_deliveries) do
      add :notifier_id, :string, null: false
      add :token_address, :string, null: false
      add :telegram_channel, :string, null: false
      add :message_text, :text, null: false
      add :sent_at, :naive_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:notification_deliveries, [:notifier_id, :token_address])
    create index(:notification_deliveries, [:token_address])
  end
end

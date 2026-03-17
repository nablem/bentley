defmodule Bentley.Schema.NotificationDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notification_deliveries" do
    field(:notifier_id, :string)
    field(:token_address, :string)
    field(:telegram_channel, :string)
    field(:message_text, :string)
    field(:sent_at, :naive_datetime)

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:notifier_id, :token_address, :telegram_channel, :message_text, :sent_at])
    |> validate_required([:notifier_id, :token_address, :telegram_channel, :message_text, :sent_at])
    |> unique_constraint([:notifier_id, :token_address],
      name: :notification_deliveries_notifier_id_token_address_index
    )
  end
end

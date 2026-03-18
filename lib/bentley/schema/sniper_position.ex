defmodule Bentley.Schema.SniperPosition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sniper_positions" do
    field(:sniper_id, :string)
    field(:notifier_id, :string)
    field(:token_address, :string)
    field(:wallet_id, :string)
    field(:entry_market_cap, :float)
    field(:position_size_usd, :float)
    field(:initial_units, :float)
    field(:remaining_units, :float)
    field(:status, :string, default: "open")
    field(:opened_at, :naive_datetime)
    field(:closed_at, :naive_datetime)

    has_many(:trades, Bentley.Schema.SniperTrade)

    timestamps()
  end

  @doc false
  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :sniper_id,
      :notifier_id,
      :token_address,
      :wallet_id,
      :entry_market_cap,
      :position_size_usd,
      :initial_units,
      :remaining_units,
      :status,
      :opened_at,
      :closed_at
    ])
    |> validate_required([
      :sniper_id,
      :notifier_id,
      :token_address,
      :wallet_id,
      :position_size_usd,
      :initial_units,
      :remaining_units,
      :status,
      :opened_at
    ])
    |> validate_inclusion(:status, ["open", "closed"])
    |> validate_number(:position_size_usd, greater_than: 0)
    |> validate_number(:initial_units, greater_than: 0)
    |> validate_number(:remaining_units, greater_than_or_equal_to: 0)
    |> unique_constraint([:sniper_id, :wallet_id, :token_address],
      name: :sniper_positions_sniper_id_wallet_id_token_address_index
    )
  end
end

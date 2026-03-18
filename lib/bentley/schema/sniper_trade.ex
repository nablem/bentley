defmodule Bentley.Schema.SniperTrade do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sniper_trades" do
    field(:trade_type, :string)
    field(:tier_index, :integer)
    field(:units, :float)
    field(:amount_usd, :float)
    field(:tx_signature, :string)
    field(:market_cap, :float)
    field(:reason, :string)
    field(:executed_at, :naive_datetime)

    belongs_to(:sniper_position, Bentley.Schema.SniperPosition)

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(trade, attrs) do
    trade
    |> cast(attrs, [
      :sniper_position_id,
      :trade_type,
      :tier_index,
      :units,
      :amount_usd,
      :tx_signature,
      :market_cap,
      :reason,
      :executed_at
    ])
    |> validate_required([:sniper_position_id, :trade_type, :units, :executed_at])
    |> validate_inclusion(:trade_type, ["buy", "sell"])
    |> validate_number(:units, greater_than: 0)
    |> foreign_key_constraint(:sniper_position_id)
    |> unique_constraint([:sniper_position_id, :tier_index],
      name: :sniper_trades_sell_tier_unique_index
    )
  end
end

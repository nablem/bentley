defmodule Bentley.Schema.Token do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tokens" do
    field(:token_address, :string)
    field(:active, :boolean, default: true)
    field(:inactivity_reason, :string)
    field(:url, :string)
    field(:website_url, :string)
    field(:x_url, :string)
    field(:telegram_url, :string)
    field(:tiktok_url, :string)
    field(:discord_url, :string)
    field(:boost, :integer)
    field(:created_on_chain_at, :naive_datetime)
    field(:icon, :string)
    field(:description, :string)
    field(:market_cap, :float)
    field(:name, :string)
    field(:ticker, :string)
    field(:volume_1h, :float)
    field(:volume_6h, :float)
    field(:volume_24h, :float)
    field(:change_1h, :float)
    field(:change_6h, :float)
    field(:change_24h, :float)
    field(:liquidity, :float)
    field(:ath, :float)
    field(:last_checked_at, :naive_datetime)

    timestamps()
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_address,
      :active,
      :inactivity_reason,
      :url,
      :website_url,
      :x_url,
      :telegram_url,
      :tiktok_url,
      :discord_url,
      :boost,
      :created_on_chain_at,
      :icon,
      :description,
      :market_cap,
      :name,
      :ticker,
      :volume_1h,
      :volume_6h,
      :volume_24h,
      :change_1h,
      :change_6h,
      :change_24h,
      :liquidity,
      :ath,
      :last_checked_at
    ])
    |> validate_required([:token_address])
    |> unique_constraint(:token_address)
  end
end

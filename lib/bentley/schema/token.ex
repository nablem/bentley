defmodule Bentley.Schema.Token do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tokens" do
    field(:token_address, :string)
    field(:url, :string)
    field(:icon, :string)
    field(:description, :string)
    field(:market_cap, :float)
    field(:volume_1h, :float)
    field(:volume_6h, :float)
    field(:volume_24h, :float)
    field(:change_1h, :float)
    field(:change_6h, :float)
    field(:last_checked_at, :naive_datetime)

    timestamps()
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_address,
      :url,
      :icon,
      :description,
      :market_cap,
      :volume_1h,
      :volume_6h,
      :volume_24h,
      :change_1h,
      :change_6h,
      :last_checked_at
    ])
    |> validate_required([:token_address])
    |> unique_constraint(:token_address)
  end
end

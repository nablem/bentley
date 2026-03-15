defmodule Bentley.Schema.Token do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tokens" do
    field(:token_address, :string)
    field(:url, :string)
    field(:icon, :string)
    field(:description, :string)

    timestamps()
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_address, :url, :icon, :description])
    |> validate_required([:token_address])
    |> unique_constraint(:token_address)
  end
end

defmodule Bentley.Repo do
  use Ecto.Repo,
    otp_app: :bentley,
    adapter: Ecto.Adapters.SQLite3
end

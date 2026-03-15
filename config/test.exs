import Config

config :bentley,
  start_recorder: false

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

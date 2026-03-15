import Config

config :bentley,
  start_recorder: false,
  start_updater: false

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

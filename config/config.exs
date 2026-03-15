import Config

config :bentley,
  ecto_repos: [Bentley.Repo]

config :bentley,
  start_recorder: true

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_dev.db",
  pool_size: 5

import_config "#{config_env()}.exs"

import Config

config :bentley,
  ecto_repos: [Bentley.Repo]

config :bentley,
  start_recorder: true

config :bentley,
  start_updater: true

config :bentley,
  start_notifiers: true,
  notifiers_file_path: nil,
  telegram_bot_token: nil,
  telegram_api_base_url: "https://api.telegram.org",
  telegram_client: Bentley.Telegram.HTTPClient

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_dev.db",
  pool_size: 5

import_config "#{config_env()}.exs"

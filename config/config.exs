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
  start_snipers: true,
  snipers_file_path: nil,
  claude_api_key: nil,
  claude_client: Bentley.Claude.HTTPClient,
  telegram_bot_token: nil,
  telegram_client: Bentley.Telegram.HTTPClient,
  sniper_executor: Bentley.Snipers.Executor.Jupiter

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_dev.db",
  pool_size: 1

import_config "#{config_env()}.exs"

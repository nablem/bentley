import Config

config :bentley,
  start_recorder: false,
  start_updater: false,
  telegram_client: Bentley.Telegram.ClientMock,
  notifiers_file_path: nil,
  telegram_bot_token: "test-bot-token"

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_test.db",
  pool: Ecto.Adapters.SQL.Sandbox

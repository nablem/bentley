import Config

config :bentley,
  start_recorder: false,
  start_updater: false,
  start_snipers: true,
  telegram_client: Bentley.Telegram.ClientMock,
  sniper_executor: Bentley.Snipers.ExecutorMock,
  notifiers_file_path: nil,
  snipers_file_path: nil,
  telegram_bot_token: "test-bot-token"

config :bentley, Bentley.Repo,
  database: "priv/repo/bentley_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 20,
  queue_target: 15_000,
  queue_interval: 15_000

ExUnit.start()

Mox.defmock(Bentley.TelegramClientMock, for: Bentley.TelegramClient)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Bentley.Repo, fn repo ->
    Ecto.Migrator.run(repo, :up, all: true)
  end)

Ecto.Adapters.SQL.Sandbox.mode(Bentley.Repo, :manual)

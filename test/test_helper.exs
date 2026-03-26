ExUnit.start()

Mox.defmock(Bentley.Snipers.JupiterHttpClientMock, for: Bentley.Snipers.JupiterHttpClient)
Mox.defmock(Bentley.Snipers.SolanaRpcHttpClientMock, for: Bentley.Snipers.JupiterHttpClient)
Mox.defmock(Bentley.Telegram.ClientMock, for: Bentley.Telegram.Client)
Mox.defmock(Bentley.Snipers.ExecutorMock, for: Bentley.Snipers.Executor)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Bentley.Repo, fn repo ->
    Ecto.Migrator.run(repo, :up, all: true)
  end)

Ecto.Adapters.SQL.Sandbox.mode(Bentley.Repo, :manual)

ExUnit.start()

{:ok, _, _} =
  Ecto.Migrator.with_repo(Bentley.Repo, fn repo ->
    Ecto.Migrator.run(repo, :up, all: true)
  end)

Ecto.Adapters.SQL.Sandbox.mode(Bentley.Repo, :manual)

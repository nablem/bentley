# lib/bentley/application.ex
defmodule Bentley.Application do
  use Application

  def start(_type, _args) do
    start_recorder? = Application.get_env(:bentley, :start_recorder, true)
    start_updater? = Application.get_env(:bentley, :start_updater, true)

    children = [
      Bentley.Repo,
      Bentley.RateLimiter
    ] ++
      if(start_recorder?, do: [Bentley.Recorder], else: []) ++
      if(start_updater?, do: [Bentley.Updater], else: [])

    opts = [strategy: :one_for_one, name: Bentley.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

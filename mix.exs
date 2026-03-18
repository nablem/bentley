defmodule Bentley.MixProject do
  use Mix.Project

  def project do
    [
      app: :bentley,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Bentley.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dotenvy, "~> 0.2", only: :dev},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.12"},
      {:b58, "~> 1.0.3"},
      {:ed25519, "~> 1.5"},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end

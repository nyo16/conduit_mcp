defmodule Examples.ObanTasksServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :oban_tasks_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Examples.ObanTasks.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:conduit_mcp, path: "../.."},
      {:bandit, "~> 1.9"},
      # Pinned to the 2.22.x line: Rescuer.rescue_executing/0 issues raw SQL
      # against Oban's internal oban_jobs table (columns/state strings), which
      # are not a public API and can change in a minor bump. Re-verify the raw
      # SQL before relaxing to ~> 2.23.
      {:oban, "~> 2.22.0"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.20"},
      {:req, "~> 0.5", only: [:dev, :test]}
    ]
  end
end

defmodule Examples.AsyncTasks.Application do
  @moduledoc """
  Supervision tree for the async tasks example.

  Includes:

  - `Task.Supervisor` for spawning background render workers
  - `ConduitMcp.Tasks.Janitor` to prune terminal-state tasks
  - `Bandit` serving `Examples.AsyncTasksServer` on port 4040

  Run with:

      iex -S mix run -e "Examples.AsyncTasks.Application.start(:normal, [])"
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Examples.AsyncTasks.Workers},
      {ConduitMcp.Tasks.Janitor, ttl: :timer.hours(1), interval: :timer.minutes(5)},
      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP, server_module: Examples.AsyncTasksServer},
       port: 4040}
    ]

    opts = [strategy: :one_for_one, name: Examples.AsyncTasks.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

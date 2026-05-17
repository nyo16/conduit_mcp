defmodule Examples.ObanTasks.Application do
  @moduledoc false

  use Application

  @port 4041

  @impl true
  def start(_type, _args) do
    Examples.ObanTasks.Telemetry.attach()

    children = [
      # 1. Repo first — Oban introspects it on start.
      Examples.ObanTasks.Repo,

      # 2. Run inline migrations (Oban schema + mcp_tasks table). One-shot
      #    GenServer that exits cleanly after migrations are applied.
      Examples.ObanTasks.Migrator,

      # 3. Oban supervisor — pulls config from :oban_tasks_server app env.
      {Oban, Application.fetch_env!(:oban_tasks_server, Oban)},

      # 4. Periodically prune terminal-state task rows. The Oban pruner
      #    above handles the oban_jobs table; this one handles ours.
      {ConduitMcp.Tasks.Janitor, ttl: :timer.hours(1), interval: :timer.minutes(5)},

      # 5. HTTP transport — serves the MCP wire protocol.
      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP, server_module: Examples.ObanTasksServer},
       port: @port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Examples.ObanTasks.Sup)
  end
end

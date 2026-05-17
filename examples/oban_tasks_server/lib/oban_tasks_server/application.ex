defmodule Examples.ObanTasks.Application do
  @moduledoc false

  use Application

  @port 4041

  @impl true
  def start(_type, _args) do
    children = [
      {ConduitMcp.Tasks.Janitor, ttl: :timer.hours(1), interval: :timer.minutes(5)},
      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP, server_module: Examples.ObanTasksServer},
       port: @port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Examples.ObanTasks.Sup)
  end
end

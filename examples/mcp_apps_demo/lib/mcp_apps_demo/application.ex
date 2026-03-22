defmodule McpAppsDemo.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT") || "4001")

    children = [
      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP, server_module: McpAppsDemo.Server}, port: port}
    ]

    Logger.info("MCP Apps Demo starting on http://localhost:#{port}")

    Supervisor.start_link(children, strategy: :one_for_one, name: McpAppsDemo.Supervisor)
  end
end

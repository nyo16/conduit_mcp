defmodule Examples.SimpleToolsServer.Application do
  @moduledoc """
  Application module for the simple tools MCP server example.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4001"))
    transport = System.get_env("TRANSPORT", "streamable_http")

    Logger.info("Starting Simple Tools MCP Server on port #{port} with #{transport} transport")

    # Choose transport based on environment variable
    plug_module =
      case transport do
        "sse" -> {ConduitMcp.Transport.SSE, server_module: Examples.SimpleToolsServer}
        _ -> {ConduitMcp.Transport.StreamableHTTP, server_module: Examples.SimpleToolsServer}
      end

    children = [
      # Start the HTTP server with chosen transport
      # No need to start the server module - it's just functions!
      {Bandit, plug: plug_module, port: port}
    ]

    opts = [strategy: :one_for_one, name: Examples.SimpleToolsServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

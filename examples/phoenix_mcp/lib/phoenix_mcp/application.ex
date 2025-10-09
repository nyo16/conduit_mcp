defmodule PhoenixMcp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixMcpWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:phoenix_mcp, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PhoenixMcp.PubSub},
      # Start the MCP server
      {PhoenixMcp.MCPServer, []},
      # Start to serve requests, typically the last entry
      PhoenixMcpWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixMcpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

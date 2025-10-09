defmodule PhoenixMcpWeb.Router do
  use PhoenixMcpWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhoenixMcpWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # MCP pipeline - NO JSON parsing! MCP transport handles it
  pipeline :mcp do
    # Option 1: No auth (development only!)
    plug PhoenixMcpWeb.Plugs.MCPAuth, enabled: false

    # Option 2: Static bearer token (uncomment and set token)
    # plug PhoenixMcpWeb.Plugs.MCPAuth, token: System.get_env("MCP_AUTH_TOKEN") || "your-secret-token"

    # Option 3: Custom verification function (uncomment and implement)
    # plug PhoenixMcpWeb.Plugs.MCPAuth,
    #   verify_token: &PhoenixMcp.Auth.verify_mcp_token/1
  end

  scope "/", PhoenixMcpWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # MCP endpoints - integrated into Phoenix router
  scope "/mcp" do
    pipe_through :mcp

    # Forward to MCP Streamable HTTP transport
    forward "/", ConduitMcp.Transport.StreamableHTTP,
      server_module: PhoenixMcp.MCPServer

    # Alternative: Use SSE transport (uncomment to use)
    # forward "/", ConduitMcp.Transport.SSE,
    #   server_module: PhoenixMcp.MCPServer
  end
end

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

  scope "/", PhoenixMcpWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # MCP endpoints - integrated into Phoenix router
  # Authentication is configured directly in the transport options
  scope "/mcp" do
    # Forward to MCP Streamable HTTP transport with auth
    forward "/", ConduitMcp.Transport.StreamableHTTP,
      server_module: PhoenixMcp.MCPServer,
      auth: [
        # Option 1: No auth (development only!)
        enabled: false

        # Option 2: Static bearer token (uncomment to use)
        # enabled: true,
        # strategy: :bearer_token,
        # token: System.get_env("MCP_AUTH_TOKEN") || "your-secret-token"

        # Option 3: Static API key (uncomment to use)
        # enabled: true,
        # strategy: :api_key,
        # api_key: "your-api-key",
        # header: "x-api-key"

        # Option 4: Custom verification function (uncomment to use)
        # enabled: true,
        # strategy: :function,
        # verify: &PhoenixMcp.Auth.verify_token/1,
        # assign_as: :current_user

        # Option 5: Database token lookup (uncomment to use)
        # enabled: true,
        # strategy: :function,
        # verify: fn token ->
        #   case PhoenixMcp.Accounts.get_user_by_token(token) do
        #     %User{} = user -> {:ok, user}
        #     nil -> {:error, "Invalid token"}
        #   end
        # end
      ]

    # Alternative: Use SSE transport (uncomment to use)
    # forward "/", ConduitMcp.Transport.SSE,
    #   server_module: PhoenixMcp.MCPServer,
    #   auth: [enabled: false]
  end
end

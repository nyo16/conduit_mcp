# Phoenix MCP Integration Example

This example demonstrates how to integrate MCP (Model Context Protocol) endpoints directly into a Phoenix application, without running a separate MCP server.

## Features

- ✅ **MCP in Phoenix Router** - MCP endpoints at `/mcp/` within your Phoenix app
- ✅ **Configurable Authentication** - Bearer token auth with multiple options
- ✅ **Echo & Reverse Tools** - Example MCP tools
- ✅ **Single Server** - No need for separate MCP server process
- ✅ **Production Ready** - Includes auth plug and CORS configuration

## Architecture

```
Phoenix App (port 4000)
├── /                  → Phoenix pages
├── /api               → Your API endpoints
└── /mcp/              → MCP Streamable HTTP transport
    ├── POST /mcp/     → MCP JSON-RPC requests
    ├── GET  /mcp/     → Health check
    └── GET  /mcp/health → Health endpoint
```

## Quick Start

### 1. Install Dependencies

```bash
cd examples/phoenix_mcp
mix deps.get
```

### 2. Start the Server

```bash
mix phx.server
```

The server starts on `http://localhost:4000`

### 3. Test MCP Endpoints

```bash
# Test tools/list
curl -X POST http://localhost:4000/mcp/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# Test echo tool
curl -X POST http://localhost:4000/mcp/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello"}}}'

# Test reverse_string tool
curl -X POST http://localhost:4000/mcp/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reverse_string","arguments":{"text":"Phoenix"}}}'
```

## Configuration

### Authentication Options

Authentication is configured directly in the transport options in `lib/phoenix_mcp_web/router.ex`:

#### Option 1: No Authentication (Development Only)

```elixir
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  auth: [enabled: false]
```

#### Option 2: Static Bearer Token

```elixir
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  auth: [
    strategy: :bearer_token,
    token: System.get_env("MCP_AUTH_TOKEN") || "your-secret-token"
  ]
```

**Usage:**
```bash
curl -X POST http://localhost:4000/mcp/ \
  -H 'Authorization: Bearer your-secret-token' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

#### Option 3: Custom Verification Function

```elixir
# First, implement your verification function in lib/phoenix_mcp/auth.ex
defmodule PhoenixMcp.Auth do
  def verify_token(token) do
    # Your custom logic here
    case MyApp.Repo.get_by(ApiToken, token: token) do
      %ApiToken{user: user} -> {:ok, user}
      nil -> {:error, "Invalid token"}
    end
  end
end

# Then use it in the router
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  auth: [
    strategy: :function,
    verify: &PhoenixMcp.Auth.verify_token/1,
    assign_as: :current_user
  ]
```

#### Option 4: API Key Authentication

```elixir
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  auth: [
    strategy: :api_key,
    api_key: "your-api-key",
    header: "x-api-key"
  ]
```

**Usage:**
```bash
curl -X POST http://localhost:4000/mcp/ \
  -H 'X-API-Key: your-api-key' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

### Transport Options

#### Streamable HTTP (Default, Recommended)

Already configured in `lib/phoenix_mcp_web/router.ex`:

```elixir
forward "/", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer
```

**Client Config:**
```json
{
  "url": "http://localhost:4000/mcp/"
}
```

#### SSE Transport (Alternative)

Uncomment in router:

```elixir
forward "/", ConduitMcp.Transport.SSE,
  server_module: PhoenixMcp.MCPServer
```

**Client Config:**
```json
{
  "url": "http://localhost:4000/mcp/sse",
  "transport": {"type": "sse"}
}
```

### CORS Configuration

Configure CORS for production in `router.ex`:

```elixir
forward "/", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  cors_origin: "https://your-frontend.com",
  cors_methods: "POST, OPTIONS",
  cors_headers: "content-type, authorization"
```

## Adding Custom Tools

### 1. Define Tool in MCP Server

Edit `lib/phoenix_mcp/mcp_server.ex`:

```elixir
defmodule PhoenixMcp.MCPServer do
  use ConduitMcp.Server

  @tools [
    # ... existing tools ...
    %{
      "name" => "get_user",
      "description" => "Get user information",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "user_id" => %{"type" => "string"}
        },
        "required" => ["user_id"]
      }
    }
  ]

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end
end
```

### 2. Implement Tool Handler

```elixir
@impl true
def handle_call_tool(_conn, "get_user", %{"user_id" => id}) do
  # Access your Phoenix app context
  user = PhoenixMcp.Accounts.get_user(id)

  {:ok, %{
    "content" => [
      %{"type" => "text", "text" => "User: #{user.name}"}
    ]
  }}
end
```

## Integration with VS Code / Cursor

Add to your MCP settings:

```json
{
  "mcpServers": {
    "phoenix-mcp": {
      "url": "http://localhost:4000/mcp/"
    }
  }
}
```

With authentication:

```json
{
  "mcpServers": {
    "phoenix-mcp": {
      "url": "http://localhost:4000/mcp/",
      "headers": {
        "Authorization": "Bearer your-token"
      }
    }
  }
}
```

## Production Deployment

### 1. Enable Authentication

Configure authentication directly in transport options in `router.ex`:

```elixir
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  auth: [
    strategy: :bearer_token,
    token: System.get_env("MCP_AUTH_TOKEN")
  ]
```

Or use custom verification:

```elixir
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  auth: [
    strategy: :function,
    verify: &PhoenixMcp.Auth.verify_token/1
  ]
```

### 2. Configure CORS

Restrict CORS to your domains:

```elixir
forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  cors_origin: "https://your-app.com",
  auth: [
    strategy: :bearer_token,
    token: System.get_env("MCP_AUTH_TOKEN")
  ]
```

### 3. Set Environment Variables

```bash
export MCP_AUTH_TOKEN="your-production-token"
export SECRET_KEY_BASE="your-secret-key"
MIX_ENV=prod mix phx.server
```

## File Structure

```
lib/
├── phoenix_mcp/
│   ├── application.ex           # Phoenix application
│   ├── mcp_server.ex            # MCP tools implementation (stateless)
│   ├── auth.ex                  # Example auth verification functions
│   └── telemetry.ex             # Telemetry handlers and metrics
└── phoenix_mcp_web/
    └── router.ex                # Routes /mcp/ to MCP transport with auth
```

## Available Tools

### echo
Echoes back the input message.

**Input:**
```json
{
  "message": "Hello, MCP!"
}
```

**Output:**
```json
{
  "content": [{"type": "text", "text": "Hello, MCP!"}]
}
```

### reverse_string
Reverses a string.

**Input:**
```json
{
  "text": "Phoenix"
}
```

**Output:**
```json
{
  "content": [{"type": "text", "text": "xineohP"}]
}
```

## Development

### Running Tests

```bash
mix test
```

### Interactive Development

```bash
iex -S mix phx.server
```

### Viewing Routes

```bash
mix phx.routes | grep mcp
```

## Troubleshooting

### Port Already in Use

Change the port in `config/dev.exs`:

```elixir
config :phoenix_mcp, PhoenixMcpWeb.Endpoint,
  http: [port: 4001]  # Change port here
```

### JSON Parsing Errors

The MCP transport handles JSON parsing automatically - no pipeline configuration needed:

```elixir
# In router.ex - no pipeline needed!
scope "/mcp" do
  forward "/", ConduitMcp.Transport.StreamableHTTP,
    server_module: PhoenixMcp.MCPServer,
    auth: [enabled: false]
end
```

### Authentication 401 Errors

Check that:
1. Auth is configured correctly in transport options (`auth: [enabled: false]` for dev)
2. You're sending the correct bearer token or API key
3. Custom verification function returns `{:ok, user}` or `{:error, reason}`

## Next Steps

- Add more tools that interact with your Phoenix app (database queries, etc.)
- Implement resources for data access
- Add prompts for LLM interactions
- Deploy to production with proper authentication
- Monitor MCP usage with Phoenix telemetry

## Resources

- [Parent ConduitMCP README](../../README.md)
- [MCP Specification](https://modelcontextprotocol.io/specification/)
- [Phoenix Documentation](https://hexdocs.pm/phoenix/)

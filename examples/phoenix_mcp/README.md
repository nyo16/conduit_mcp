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

Edit `lib/phoenix_mcp_web/router.ex` to configure authentication:

#### Option 1: No Authentication (Development Only)

```elixir
pipeline :mcp do
  plug PhoenixMcpWeb.Plugs.MCPAuth, enabled: false
end
```

#### Option 2: Static Bearer Token

```elixir
pipeline :mcp do
  plug PhoenixMcpWeb.Plugs.MCPAuth,
    token: System.get_env("MCP_AUTH_TOKEN") || "your-secret-token"
end
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
# First, implement your verification function
defmodule PhoenixMcp.Auth do
  def verify_mcp_token(token) do
    # Your custom logic here
    if valid_token?(token) do
      {:ok, %{user_id: "123", scopes: ["tools:read"]}}
    else
      :error
    end
  end
end

# Then use it in the pipeline
pipeline :mcp do
  plug PhoenixMcpWeb.Plugs.MCPAuth,
    verify_token: &PhoenixMcp.Auth.verify_mcp_token/1
end
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
def mcp_init(_opts) do
  tools = [
    # ... existing tools ...
    %{
      "name" => "get_user",
      "description" => "Get user information",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "user_id" => %{"type": "string"}
        },
        "required" => ["user_id"]
      }
    }
  ]
  {:ok, %{tools: tools}}
end
```

### 2. Implement Tool Handler

```elixir
@impl true
def handle_call_tool("get_user", %{"user_id" => id}, state) do
  # Access your Phoenix app context
  user = PhoenixMcp.Accounts.get_user(id)

  result = %{
    "content" => [
      %{"type" => "text", "text" => "User: #{user.name}"}
    ]
  }
  {:reply, result, state}
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

Uncomment and configure bearer token in `router.ex`:

```elixir
pipeline :mcp do
  plug PhoenixMcpWeb.Plugs.MCPAuth,
    token: System.get_env("MCP_AUTH_TOKEN")
end
```

### 2. Configure CORS

Restrict CORS to your domains:

```elixir
forward "/", ConduitMcp.Transport.StreamableHTTP,
  server_module: PhoenixMcp.MCPServer,
  cors_origin: "https://your-app.com"
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
│   ├── application.ex           # Starts MCP server in supervision tree
│   └── mcp_server.ex            # MCP tools implementation
└── phoenix_mcp_web/
    ├── router.ex                # Routes /mcp/ to MCP transport
    └── plugs/
        └── mcp_auth.ex          # Bearer token authentication
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

Make sure the MCP pipeline does NOT include JSON parsing - the MCP transport handles it:

```elixir
pipeline :mcp do
  # Only auth, no :accepts or JSON parsing!
  plug PhoenixMcpWeb.Plugs.MCPAuth, enabled: false
end
```

### Authentication 401 Errors

Check that:
1. Auth is disabled for development (`enabled: false`)
2. Or you're sending the correct bearer token
3. Token verification function returns `{:ok, metadata}` not just `:ok`

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

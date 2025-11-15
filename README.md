# ConduitMCP

An Elixir implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification (version 2025-06-18). Build MCP servers to expose tools, resources, and prompts to LLM applications like Claude Desktop and VS Code extensions.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.2.0"}
  ]
end
```

Or from GitHub:

```elixir
def deps do
  [
    {:conduit_mcp, github: "nyo16/conduit_mcp"}
  ]
end
```

## Quick Start

### Standalone Server

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  @impl true
  def mcp_init(_opts) do
    tools = [
      %{
        "name" => "greet",
        "description" => "Greet someone",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"}
          },
          "required" => ["name"]
        }
      }
    ]
    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_list_tools(state) do
    {:reply, %{"tools" => state.tools}, state}
  end

  @impl true
  def handle_call_tool("greet", %{"name" => name}, state) do
    {:reply, %{
      "content" => [%{"type" => "text", "text" => "Hello, #{name}!"}]
    }, state}
  end
end
```

Start the server:

```elixir
children = [
  {MyApp.MCPServer, []},
  {Bandit,
   plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
   port: 4001}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Phoenix Integration

Add MCP endpoints directly to your Phoenix application:

```elixir
# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  @impl true
  def mcp_init(_opts) do
    tools = [
      %{
        "name" => "get_user",
        "description" => "Get user information from database",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "user_id" => %{"type" => "string"}
          },
          "required" => ["user_id"]
        }
      }
    ]
    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_list_tools(state) do
    {:reply, %{"tools" => state.tools}, state}
  end

  @impl true
  def handle_call_tool("get_user", %{"user_id" => id}, state) do
    user = MyApp.Accounts.get_user(id)
    {:reply, %{
      "content" => [%{"type" => "text", "text" => "User: #{user.name}"}]
    }, state}
  end
end
```

Add to your router:

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :mcp do
    # Optional: Add authentication
    plug MyAppWeb.Plugs.MCPAuth, enabled: false
  end

  scope "/mcp", MyAppWeb do
    pipe_through :mcp

    forward "/", ConduitMcp.Transport.StreamableHTTP,
      server_module: MyApp.MCPServer
  end
end
```

Add server to your application supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.MCPServer,
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

See the [Phoenix Integration Example](examples/phoenix_mcp/README.md) for a complete working example with authentication.

## Client Configuration

### VS Code / Cursor

Add to your MCP settings:

```json
{
  "mcpServers": {
    "my-app": {
      "url": "http://localhost:4001/"
    }
  }
}
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "my-app": {
      "command": "elixir",
      "args": ["/path/to/your/server.exs"]
    }
  }
}
```

## Features

- Full MCP specification 2025-06-18 implementation
- Dual transport support (Streamable HTTP and SSE)
- JSON-RPC 2.0 compliant
- Support for tools, resources, and prompts
- Configurable CORS and authentication
- Phoenix integration support
- Telemetry events for monitoring
- Production ready with comprehensive test coverage (82%)

## Testing

```bash
# Run tests
mix test

# Run with coverage
mix coveralls

# Test with curl
curl -X POST http://localhost:4001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Documentation

- [Simple Server Example](examples/simple_tools_server/README.md)
- [Phoenix Integration Example](examples/phoenix_mcp/README.md)
- [MCP Specification](https://modelcontextprotocol.io/specification/)

## Requirements

- Elixir 1.18+
- Erlang/OTP 27+

## License

Apache License 2.0

# ConduitMCP

An Elixir implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification (version 2025-06-18). Build MCP servers to expose tools, resources, and prompts to LLM applications like Claude Desktop and VS Code extensions.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.4.0"}
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

## What's New in v0.4.0

**🚀 Stateless Architecture for Maximum Concurrency**

- Removed GenServer bottleneck - all requests now processed concurrently
- Callbacks simplified - no more state passing/returning
- Config initialized once and stored immutably
- Each HTTP request runs in parallel (limited only by Bandit's process pool)

**⚠️ Breaking Changes**

The API has been simplified. Update your callbacks:

```elixir
# v0.3.0 (old)
def handle_list_tools(state) do
  {:reply, %{"tools" => state.tools}, state}
end

# v0.4.0 (new)
def handle_list_tools(config) do
  {:ok, %{"tools" => config.tools}}
end
```

See the migration guide below for details.

## Quick Start

### Standalone Server

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  @impl true
  def mcp_init(_opts) do
    config = %{
      tools: [
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
    }
    {:ok, config}
  end

  @impl true
  def handle_list_tools(config) do
    {:ok, %{"tools" => config.tools}}
  end

  @impl true
  def handle_call_tool("greet", %{"name" => name}, _config) do
    {:ok, %{
      "content" => [%{"type" => "text", "text" => "Hello, #{name}!"}]
    }}
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
    config = %{
      tools: [
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
    }
    {:ok, config}
  end

  @impl true
  def handle_list_tools(config) do
    {:ok, %{"tools" => config.tools}}
  end

  @impl true
  def handle_call_tool("get_user", %{"user_id" => id}, _config) do
    user = MyApp.Accounts.get_user(id)
    {:ok, %{
      "content" => [%{"type" => "text", "text" => "User: #{user.name}"}]
    }}
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

## Migration Guide (v0.3.x → v0.4.0)

Update your callback return values:

| Callback | v0.3.x | v0.4.0 |
|----------|--------|--------|
| `handle_list_tools/1` | `{:reply, result, state}` | `{:ok, result}` |
| `handle_call_tool/3` | `{:reply, result, state}` or `{:error, error, state}` | `{:ok, result}` or `{:error, error}` |
| `handle_list_resources/1` | `{:reply, result, state}` | `{:ok, result}` |
| `handle_read_resource/2` | `{:reply, result, state}` or `{:error, error, state}` | `{:ok, result}` or `{:error, error}` |
| `handle_list_prompts/1` | `{:reply, result, state}` | `{:ok, result}` |
| `handle_get_prompt/3` | `{:reply, result, state}` or `{:error, error, state}` | `{:ok, result}` or `{:error, error}` |

**Key changes:**
1. Rename `state` to `config` (both are the same - just clearer naming)
2. Change `{:reply, result, state}` to `{:ok, result}`
3. Change `{:error, error, state}` to `{:error, error}`
4. Error maps now use string keys: `%{"code" => -32000, "message" => "..."}` instead of atoms

**Handling Mutable State**

If you need mutable state (e.g., counters, caches), use external mechanisms:

```elixir
# Option 1: ETS
def mcp_init(_opts) do
  :ets.new(:my_counter, [:set, :public, :named_table])
  :ets.insert(:my_counter, {:count, 0})
  {:ok, %{tools: [...]}}
end

def handle_call_tool("count", _params, config) do
  :ets.update_counter(:my_counter, :count, 1)
  count = :ets.lookup(:my_counter, :count) |> hd() |> elem(1)
  {:ok, %{"content" => [%{"type" => "text", "text" => "Count: #{count}"}]}}
end

# Option 2: Agent
def mcp_init(_opts) do
  {:ok, _} = Agent.start_link(fn -> 0 end, name: :my_counter)
  {:ok, %{tools: [...]}}
end

def handle_call_tool("count", _params, config) do
  count = Agent.get_and_update(:my_counter, fn c -> {c + 1, c + 1} end)
  {:ok, %{"content" => [%{"type" => "text", "text" => "Count: #{count}"}]}}
end
```

## Features

- Full MCP specification 2025-06-18 implementation
- **Stateless architecture for maximum concurrency**
- Dual transport support (Streamable HTTP and SSE)
- JSON-RPC 2.0 compliant
- Support for tools, resources, and prompts
- Configurable CORS and authentication
- Phoenix integration support
- Telemetry events for monitoring
- Production ready with comprehensive test coverage

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

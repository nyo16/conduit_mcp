# ConduitMCP

An Elixir implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification (version 2025-06-18). Build MCP servers to expose tools, resources, and prompts to LLM applications like Claude Desktop and VS Code extensions.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.4.5"}
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

  @tools [
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

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "greet", %{"name" => name}) do
    {:ok, %{
      "content" => [%{"type" => "text", "text" => "Hello, #{name}!"}]
    }}
  end
end
```

Start the server:

```elixir
children = [
  # No need to start the server module - it's just functions!
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

  @tools [
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

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "get_user", %{"user_id" => id}) do
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

That's it! No need to add the server to your supervision tree - it's just a module with functions.

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

Update your callback signatures and return values:

| Callback | v0.3.x | v0.4.0 |
|----------|--------|--------|
| `mcp_init/1` | Required | Removed (use module attributes instead) |
| `handle_list_tools/1` | `handle_list_tools(config)` → `{:reply, result, config}` | `handle_list_tools(conn)` → `{:ok, result}` |
| `handle_call_tool/3` | `handle_call_tool(name, params, config)` → `{:reply, result, config}` | `handle_call_tool(conn, name, params)` → `{:ok, result}` |
| `handle_list_resources/1` | `handle_list_resources(config)` → `{:reply, result, config}` | `handle_list_resources(conn)` → `{:ok, result}` |
| `handle_read_resource/2` | `handle_read_resource(uri, config)` → `{:reply, result, config}` | `handle_read_resource(conn, uri)` → `{:ok, result}` |
| `handle_list_prompts/1` | `handle_list_prompts(config)` → `{:reply, result, config}` | `handle_list_prompts(conn)` → `{:ok, result}` |
| `handle_get_prompt/3` | `handle_get_prompt(name, args, config)` → `{:reply, result, config}` | `handle_get_prompt(conn, name, args)` → `{:ok, result}` |

**Key changes:**
1. No more `mcp_init/1` - use module attributes like `@tools` instead
2. Callbacks receive `conn` (Plug.Conn) as first parameter instead of config
3. Change `{:reply, result, state}` to `{:ok, result}`
4. Change `{:error, error, state}` to `{:error, error}`
5. Error maps now use string keys: `%{"code" => -32000, "message" => "..."}` instead of atoms
6. **Remove server from supervision tree** - it's just functions now!

**Example Migration:**

```elixir
# v0.3.x
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  @impl true
  def mcp_init(_opts) do
    {:ok, %{tools: [...]}}
  end

  @impl true
  def handle_list_tools(config) do
    {:reply, %{"tools" => config.tools}, config}
  end

  @impl true
  def handle_call_tool("echo", %{"msg" => msg}, config) do
    {:reply, %{"content" => [...]}, config}
  end
end

# Supervision tree
children = [
  {MyApp.MCPServer, []},  # ← Remove this!
  {Bandit, ...}
]

# v0.4.0
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  @tools [...]  # Define as module attribute

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "echo", %{"msg" => msg}) do
    {:ok, %{"content" => [...]}}
  end
end

# Supervision tree
children = [
  {Bandit, ...}  # Just Bandit!
]
```

**Handling Mutable State**

If you need mutable state (e.g., counters, caches), use external mechanisms:

```elixir
# Option 1: ETS (fastest for concurrent reads/writes)
def handle_call_tool(_conn, "increment", _params) do
  :ets.update_counter(:my_counter, :count, 1)
  count = :ets.lookup_element(:my_counter, :count, 2)
  {:ok, %{"content" => [%{"type" => "text", "text" => "Count: #{count}"}]}}
end

# Option 2: Agent/GenServer (for complex state)
def handle_call_tool(_conn, "get_cache", %{"key" => key}) do
  value = MyApp.Cache.get(key)
  {:ok, %{"content" => [%{"type" => "text", "text" => value}]}}
end

# Option 3: Database (for persistent state)
def handle_call_tool(_conn, "save_data", %{"data" => data}) do
  MyApp.Repo.insert(%Data{value: data})
  {:ok, %{"content" => [%{"type" => "text", "text" => "Saved!"}]}}
end
```

**Using Connection Context:**

The `conn` parameter provides access to request context:

```elixir
def handle_call_tool(conn, "private_data", _params) do
  # Access authentication info
  user_id = conn.assigns[:user_id]

  # Check headers
  auth = Plug.Conn.get_req_header(conn, "authorization")

  {:ok, %{"content" => [%{"type" => "text", "text" => "User: #{user_id}"}]}}
end
```

## Features

- Full MCP specification 2025-06-18 implementation
- **Pure stateless architecture - just compiled functions!**
  - No GenServer, no Agent, no process overhead
  - No supervision tree required
  - Maximum concurrency - limited only by Bandit's process pool
- **Flexible authentication** - Bearer tokens, API keys, custom verification
- Dual transport support (Streamable HTTP and SSE)
- JSON-RPC 2.0 compliant
- Support for tools, resources, and prompts
- Connection context access for authentication/headers
- Configurable CORS and authentication
- Phoenix integration support
- Telemetry events for monitoring
- Production ready with comprehensive test coverage

## Authentication

ConduitMCP includes a flexible authentication plug supporting multiple strategies:

### Development (No Auth)

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        auth: [enabled: false]},
 port: 4001}
```

### Static Bearer Token

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        auth: [
          strategy: :bearer_token,
          token: System.get_env("MCP_SECRET_TOKEN")
        ]},
 port: 4001}
```

### Static API Key

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        auth: [
          strategy: :api_key,
          api_key: "your-api-key",
          header: "x-api-key"  # Optional, defaults to "x-api-key"
        ]},
 port: 4001}
```

### Custom Verification Function

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        auth: [
          strategy: :function,
          verify: fn token ->
            case MyApp.Auth.verify_token(token) do
              {:ok, user} -> {:ok, user}
              _ -> {:error, "Invalid token"}
            end
          end,
          assign_as: :current_user  # Optional, defaults to :current_user
        ]},
 port: 4001}
```

### Database Token Lookup

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        auth: [
          strategy: :function,
          verify: fn token ->
            case MyApp.Repo.get_by(ApiToken, token: token, active: true) do
              %ApiToken{user: user} -> {:ok, user}
              nil -> {:error, "Invalid or expired token"}
            end
          end
        ]},
 port: 4001}
```

### MFA (Module, Function, Args)

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        auth: [
          strategy: :function,
          verify: {MyApp.Auth, :verify_mcp_token, []}
        ]},
 port: 4001}

# In MyApp.Auth module:
def verify_mcp_token(token) do
  # Your verification logic
  {:ok, user} | {:error, reason}
end
```

### Using Authenticated User in Tools

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  @impl true
  def handle_call_tool(conn, "get_profile", _params) do
    # Access authenticated user from conn.assigns
    case conn.assigns[:current_user] do
      nil ->
        {:error, %{"code" => -32000, "message" => "Not authenticated"}}

      user ->
        {:ok, %{
          "content" => [%{
            "type" => "text",
            "text" => "User: #{user.name}, Email: #{user.email}"
          }]
        }}
    end
  end
end
```

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

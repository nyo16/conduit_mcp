# ConduitMCP

An Elixir implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification (version 2025-06-18).

ConduitMCP provides a lightweight, flexible framework for building MCP servers that can expose tools, resources, and prompts to LLM applications like Claude Desktop, VS Code extensions, and other MCP clients.

## Features

- ✅ **MCP Specification 2025-06-18** - Full implementation of the latest protocol
- ✅ **Dual Transport Support** - Both SSE and Streamable HTTP transports
- ✅ **Simple Server Behaviour** - Easy-to-use behaviour for building MCP servers
- ✅ **JSON-RPC 2.0** - Standards-compliant message protocol
- ✅ **Tools, Resources, Prompts** - Support for all MCP primitives
- ✅ **CORS Enabled** - Ready for web-based clients
- ✅ **Working Examples** - Complete example server with tests

## Quick Start

### 1. Add to your project

```elixir
def deps do
  [
    {:conduit_mcp, path: "/path/to/conduit_mcp"}
  ]
end
```

### 2. Create a simple server

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
            "name" => %{"type" => "string", "description" => "Name to greet"}
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
    result = %{
      "content" => [
        %{"type" => "text", "text" => "Hello, #{name}!"}
      ]
    }
    {:reply, result, state}
  end
end
```

### 3. Implement additional callbacks (optional)

```elixir
# Add resources
@impl true
def handle_list_resources(state) do
  resources = [
    %{
      "uri" => "file:///config",
      "name" => "App Configuration",
      "description" => "Current application configuration",
      "mimeType" => "application/json"
    }
  ]
  {:reply, %{"resources" => resources}, state}
end

@impl true
def handle_read_resource("file:///config", state) do
  config = Application.get_all_env(:my_app)
  {:reply, %{
    "contents" => [%{
      "uri" => "file:///config",
      "mimeType" => "application/json",
      "text" => Jason.encode!(config)
    }]
  }, state}
end

# Add prompts
@impl true
def handle_list_prompts(state) do
  prompts = [
    %{
      "name" => "code_review",
      "description" => "Review code for best practices",
      "arguments" => [
        %{
          "name" => "code",
          "description" => "Code to review",
          "required" => true
        }
      ]
    }
  ]
  {:reply, %{"prompts" => prompts}, state}
end

@impl true
def handle_get_prompt("code_review", %{"code" => code}, state) do
  messages = [
    %{
      "role" => "user",
      "content" => %{
        "type" => "text",
        "text" => "Please review this code:\n\n#{code}"
      }
    }
  ]
  {:reply, %{"messages" => messages}, state}
end
```

### 4. Run your server

See `examples/simple_tools_server/` for a complete working example.

## Transport Options

### Streamable HTTP (Recommended)

The modern, simpler transport. Single POST endpoint for all communication.

```elixir
# Start server with Streamable HTTP
children = [
  {MyApp.MCPServer, []},
  {Bandit,
   plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
   port: 4001}
]
```

**Client Config:**
```json
{
  "url": "http://localhost:4001/"
}
```

### SSE (Server-Sent Events)

Legacy transport using SSE for server-to-client messages and HTTP POST for client-to-server.

```elixir
# Start server with SSE
children = [
  {MyApp.MCPServer, []},
  {Bandit,
   plug: {ConduitMcp.Transport.SSE, server_module: MyApp.MCPServer},
   port: 4001}
]
```

**Client Config:**
```json
{
  "url": "http://localhost:4001/sse",
  "transport": {
    "type": "sse"
  }
}
```

## Example Server

A complete example server with echo and reverse_string tools is included:

```bash
# Run the example
cd examples/simple_tools_server
elixir run.exs

# Test with the provided script
./test_client.sh
```

See [`examples/simple_tools_server/README.md`](examples/simple_tools_server/README.md) for detailed usage.

## Integration

### VS Code / Cursor

Add to your MCP settings:

```json
{
  "mcpServers": {
    "my-server": {
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
    "my-server": {
      "command": "elixir",
      "args": ["/path/to/your/server.exs"]
    }
  }
}
```

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  MCP Client │────▶│   Transport  │────▶│ MCP Server  │
│  (Claude)   │     │  (HTTP/SSE)  │     │  (Tools)    │
└─────────────┘     └──────────────┘     └─────────────┘
     JSON-RPC 2.0 Messages
```

### Core Modules

- **`ConduitMcp.Protocol`** - JSON-RPC 2.0 and MCP message definitions
- **`ConduitMcp.Server`** - Behaviour for implementing MCP servers
- **`ConduitMcp.Handler`** - Request router and method dispatcher
- **`ConduitMcp.Transport.SSE`** - Server-Sent Events transport
- **`ConduitMcp.Transport.StreamableHTTP`** - Streamable HTTP transport

## Testing

```bash
# Run tests
mix test

# Run the example server
cd examples/simple_tools_server
elixir run.exs

# Test with curl
curl -X POST http://localhost:4001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Documentation

- **Implementation Guide**: See [`elixir_mcp_implementation_guide.md`](elixir_mcp_implementation_guide.md)
- **Example Server**: See [`examples/simple_tools_server/README.md`](examples/simple_tools_server/README.md)
- **Testing Guide**: See [`examples/simple_tools_server/TESTING.md`](examples/simple_tools_server/TESTING.md)
- **VS Code Setup**: See [`examples/simple_tools_server/VSCODE_SETUP.md`](examples/simple_tools_server/VSCODE_SETUP.md)

## Resources

- [MCP Specification](https://modelcontextprotocol.io/specification/)
- [MCP Documentation](https://modelcontextprotocol.io/docs)
- [Hermes MCP](https://github.com/cloudwalk/hermes-mcp) (Inspiration)

## Requirements

- Elixir 1.18 or later
- Erlang/OTP 27 or later

## Dependencies

- `jason` - JSON encoding/decoding
- `plug` - HTTP composable modules
- `bandit` - HTTP server

## License

Apache License 2.0 - See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Status

🚧 **Early Development** - This library is functional but still in active development. The API may change.

## Roadmap

- [ ] OAuth 2.1 authentication
- [ ] Resource support enhancements
- [ ] Prompts implementation
- [ ] Client implementation
- [ ] WebSocket transport
- [ ] Comprehensive test suite
- [ ] HexDocs publication

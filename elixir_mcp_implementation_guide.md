# Elixir MCP Implementation Guide

## Project Name Suggestions
**Recommended**: **Mercury MCP** or **Iris MCP**
- Mercury: Roman messenger god (equivalent to Hermes)
- Iris: Greek goddess of communication and rainbow bridges

## Overview
Model Context Protocol (MCP) is an open standard that enables seamless integration between LLM applications and external data sources/tools. It provides a standardized way to connect AI systems with context through a client-server architecture.

## Latest Specification Version
- **Current Version**: 2025-06-18
- **Next Version**: 2025-11-25 (RC on 2025-11-11)
- Recent updates include OAuth Resource Server classification, mandatory Resource Indicators (RFC 8707), and enhanced security guidelines

## Core Architecture

### Protocol Layers
MCP follows a client-host-server architecture built on JSON-RPC 2.0, providing a stateful session protocol with capability-based negotiation

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  AI Client  │────▶│     Host     │────▶│  MCP Server │
│  (Claude)   │     │  (Your App)  │     │   (Tools)   │
└─────────────┘     └──────────────┘     └─────────────┘
     JSON-RPC 2.0 over Transport Layer (SSE/HTTP/stdio)
```

### Key Primitives
1. **Resources**: Data access without side effects (GET-like)
2. **Tools**: Functions that can perform actions (side effects allowed)
3. **Prompts**: Reusable templates for LLM interactions
4. **Sampling**: Server-initiated LLM completions (new)

## Project Structure

```bash
# Create new Elixir project
mix new mercury_mcp --sup
cd mercury_mcp
```

### Dependencies (mix.exs)
```elixir
defp deps do
  [
    # Core dependencies
    {:jason, "~> 1.4"},
    {:tesla, "~> 1.8"},
    {:gen_state_machine, "~> 3.0"},
    
    # Transport layers
    {:plug, "~> 1.15"},
    {:bandit, "~> 1.5"},  # or {:plug_cowboy, "~> 2.7"}
    {:mint, "~> 1.6"},    # HTTP client
    
    # Optional: WebSocket support
    {:websockex, "~> 0.4.3"},
    
    # Development
    {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.31", only: :dev, runtime: false}
  ]
end
```

## Implementation Scaffolding

### 1. Core Protocol Module
```elixir
# lib/mercury_mcp/protocol.ex
defmodule MercuryMCP.Protocol do
  @protocol_version "2025-06-18"
  
  # Define message types
  @type request :: %{
    jsonrpc: String.t(),
    id: String.t() | integer(),
    method: String.t(),
    params: map()
  }
  
  @type response :: %{
    jsonrpc: String.t(),
    id: String.t() | integer(),
    result: any()
  } | %{
    jsonrpc: String.t(),
    id: String.t() | integer(),
    error: error()
  }
  
  @type notification :: %{
    jsonrpc: String.t(),
    method: String.t(),
    params: map() | nil
  }
  
  # Core methods to implement
  def methods do
    %{
      # Lifecycle
      "initialize" => :initialize,
      "notifications/initialized" => :initialized,
      "ping" => :ping,
      
      # Tools
      "tools/list" => :list_tools,
      "tools/call" => :call_tool,
      
      # Resources
      "resources/list" => :list_resources,
      "resources/read" => :read_resource,
      "resources/subscribe" => :subscribe_resource,
      "resources/unsubscribe" => :unsubscribe_resource,
      
      # Prompts
      "prompts/list" => :list_prompts,
      "prompts/get" => :get_prompt,
      
      # Sampling (new)
      "sampling/createMessage" => :create_message,
      
      # Logging
      "logging/setLevel" => :set_log_level
    }
  end
end
```

### 2. Server Behaviour
```elixir
# lib/mercury_mcp/server.ex
defmodule MercuryMCP.Server do
  @moduledoc """
  Behaviour for MCP server implementations
  """
  
  @type state :: map()
  @type client_info :: %{
    name: String.t(),
    version: String.t()
  }
  
  # Lifecycle callbacks
  @callback init(client_info(), state()) :: {:ok, state()}
  @callback terminate(reason :: any(), state()) :: :ok
  
  # Tool callbacks
  @callback handle_tool_call(name :: String.t(), params :: map(), state()) ::
    {:reply, result :: any(), state()} |
    {:error, error :: map(), state()}
    
  # Resource callbacks
  @callback handle_resource_read(uri :: String.t(), state()) ::
    {:ok, content :: any(), state()} |
    {:error, error :: map(), state()}
    
  # Prompt callbacks
  @callback handle_prompt_get(name :: String.t(), args :: map(), state()) ::
    {:ok, messages :: list(), state()} |
    {:error, error :: map(), state()}
    
  # Optional callbacks
  @optional_callbacks [
    handle_tool_call: 3,
    handle_resource_read: 2,
    handle_prompt_get: 3
  ]
end
```

### 3. Client Implementation
```elixir
# lib/mercury_mcp/client.ex
defmodule MercuryMCP.Client do
  use GenServer
  
  defstruct [
    :transport,
    :connection,
    :session_id,
    :server_capabilities,
    :client_capabilities,
    :protocol_version,
    requests: %{},
    request_id: 1
  ]
  
  # Client API
  def start_link(opts), do: # Implementation
  def initialize(client, capabilities \\ %{}), do: # Implementation
  def call_tool(client, name, params), do: # Implementation
  def read_resource(client, uri), do: # Implementation
  def get_prompt(client, name, args \\ %{}), do: # Implementation
  
  # Callbacks to implement
end
```

### 4. Transport Layer - SSE (Most Common)
```elixir
# lib/mercury_mcp/transport/sse.ex
defmodule MercuryMCP.Transport.SSE do
  use Plug.Router
  
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch
  
  # SSE endpoint
  get "/sse" do
    # Set headers for SSE
    # Stream endpoint information
    # Keep connection alive
  end
  
  # Message endpoint
  post "/message" do
    # Handle JSON-RPC messages
    # Route to appropriate handler
    # Return response
  end
end
```

### 5. Transport Layer - Streamable HTTP (New Standard)
```elixir
# lib/mercury_mcp/transport/streamable_http.ex
defmodule MercuryMCP.Transport.StreamableHTTP do
  use Plug.Router
  
  # Single endpoint for bidirectional streaming
  post "/" do
    # Handle streaming HTTP transport
    # Support request batching
  end
end
```

### 6. Security - OAuth 2.1 Implementation
```elixir
# lib/mercury_mcp/auth/oauth.ex
defmodule MercuryMCP.Auth.OAuth do
  @moduledoc """
  OAuth 2.1 Resource Server implementation
  Required by 2025-06-18 spec
  """
  
  # Resource indicators (RFC 8707) - MANDATORY
  def validate_resource_indicators(token, requested_resources) do
    # Prevent token misuse by validating resource indicators
  end
  
  # Token validation
  def validate_access_token(conn) do
    # Extract and validate Bearer token
  end
  
  # Protected resource metadata
  def resource_metadata do
    %{
      resource: "https://your-server.com",
      scopes_supported: ["tools:execute", "resources:read"],
      bearer_methods_supported: ["header", "body"]
    }
  end
end
```

### 7. Capability Negotiation
```elixir
# lib/mercury_mcp/capabilities.ex
defmodule MercuryMCP.Capabilities do
  @server_capabilities %{
    tools: %{listChanged: true},
    resources: %{
      subscribe: true,
      listChanged: true
    },
    prompts: %{listChanged: true},
    logging: %{},
    # New in latest spec
    sampling: %{}
  }
  
  @client_capabilities %{
    sampling: %{},
    roots: %{listChanged: true},
    # New: experimental features
    experimental: %{}
  }
end
```

### 8. Lifecycle Management
MCP defines three lifecycle phases: Initialization (capability negotiation), Operation (normal communication), and Shutdown (graceful termination)

```elixir
# lib/mercury_mcp/lifecycle.ex
defmodule MercuryMCP.Lifecycle do
  use GenStateMachine
  
  # States: :connecting, :initializing, :ready, :shutting_down
  
  def handle_event(:internal, :connect, :connecting, data) do
    # Establish connection
  end
  
  def handle_event({:call, from}, :initialize, :initializing, data) do
    # Send initialize request
    # Negotiate capabilities
    # Send initialized notification
  end
end
```

## Implementation Examples

### Simple Tool Implementation
```elixir
# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use MercuryMCP.Server
  
  @impl true
  def init(_client_info, state) do
    tools = [
      %{
        name: "get_weather",
        description: "Get current weather for a location",
        inputSchema: %{
          type: "object",
          properties: %{
            location: %{
              type: "string",
              description: "City, Country"
            }
          },
          required: ["location"]
        }
      }
    ]
    
    {:ok, Map.put(state, :tools, tools)}
  end
  
  @impl true
  def handle_tool_call("get_weather", %{"location" => loc}, state) do
    # Implementation
    {:reply, %{temperature: 22, condition: "sunny"}, state}
  end
end
```

### Resource Implementation
```elixir
defmodule MyApp.ResourceServer do
  use MercuryMCP.Server
  
  @impl true
  def handle_resource_read("file:///" <> path, state) do
    case File.read(path) do
      {:ok, content} -> 
        {:ok, %{
          contents: [
            %{
              uri: "file:///#{path}",
              mimeType: "text/plain",
              text: content
            }
          ]
        }, state}
      {:error, reason} ->
        {:error, %{code: -32602, message: to_string(reason)}, state}
    end
  end
end
```

## Testing Strategy

### 1. Protocol Compliance Tests
```elixir
# test/protocol_test.exs
defmodule MercuryMCP.ProtocolTest do
  use ExUnit.Case
  
  test "initialize handshake follows spec" do
    # Test capability negotiation
    # Verify protocol version handling
    # Check initialized notification
  end
  
  test "handles unknown methods correctly" do
    # Should return -32601 Method not found
  end
end
```

### 2. Integration Tests
```elixir
# test/integration_test.exs
defmodule MercuryMCP.IntegrationTest do
  use ExUnit.Case
  
  setup do
    # Start server and client
    # Perform initialization
  end
  
  test "full tool execution flow" do
    # List tools
    # Call tool
    # Verify response
  end
end
```

## Deployment Considerations

### 1. Supervision Tree
```elixir
# lib/mercury_mcp/application.ex
defmodule MercuryMCP.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # Registry for tracking connections
      {Registry, keys: :unique, name: MercuryMCP.Registry},
      
      # Transport supervisor
      {DynamicSupervisor, strategy: :one_for_one, name: MercuryMCP.TransportSupervisor},
      
      # Server endpoint (if running as server)
      {Bandit, plug: MercuryMCP.Transport.SSE, port: 4000}
    ]
    
    opts = [strategy: :one_for_one, name: MercuryMCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 2. Configuration
```elixir
# config/config.exs
import Config

config :mercury_mcp,
  protocol_version: "2025-06-18",
  transport: :sse,
  port: 4000,
  # OAuth configuration
  oauth: [
    issuer: "https://auth.example.com",
    audience: "https://your-mcp-server.com",
    jwks_uri: "https://auth.example.com/.well-known/jwks.json"
  ]

# Runtime configuration
# config/runtime.exs
import Config

if config_env() == :prod do
  config :mercury_mcp,
    port: System.get_env("PORT", "4000") |> String.to_integer(),
    auth_token: System.fetch_env!("MCP_AUTH_TOKEN")
end
```

## Key Implementation Notes

### Latest Spec Changes (2025-06-18)
1. **OAuth 2.1 Resource Server**: Servers are now OAuth Resource Servers
2. **Resource Indicators (RFC 8707)**: Mandatory for preventing token misuse
3. **Structured Tool Outputs**: Enhanced response formatting
4. **Sampling API**: Server-initiated LLM completions
5. **Security Enhancements**: Improved authentication/authorization

### Transport Priority
1. **Streamable HTTP** (recommended for new implementations)
2. **SSE** (widely supported, good for web clients)
3. **stdio** (for CLI tools)
4. **WebSocket** (for real-time bidirectional)

### Error Codes (JSON-RPC 2.0)
- `-32700`: Parse error
- `-32600`: Invalid Request
- `-32601`: Method not found
- `-32602`: Invalid params
- `-32603`: Internal error
- `-32000 to -32099`: Server-defined errors

## Testing Tools

### MCP Inspector
```bash
# Install globally
npm install -g @modelcontextprotocol/inspector

# Test your server
mcp-inspector --transport sse --url http://localhost:4000/sse
```

### Manual Testing with curl
```bash
# Initialize connection
curl -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": {
        "name": "test-client",
        "version": "1.0.0"
      }
    }
  }'
```

## Resources
- Official Specification: https://modelcontextprotocol.io/specification/
- GitHub: https://github.com/modelcontextprotocol/modelcontextprotocol
- Community Forum: Discussion forums for MCP implementers
- Example Servers: Reference implementations in various languages

## Next Steps
1. Choose transport layer (SSE or Streamable HTTP)
2. Implement core protocol handlers
3. Add OAuth 2.1 authentication
4. Create your tools/resources/prompts
5. Test with MCP Inspector
6. Integrate with Claude Desktop or other MCP clients

## Production Checklist
- [ ] OAuth 2.1 Resource Server implementation
- [ ] Resource Indicators (RFC 8707) validation
- [ ] Rate limiting
- [ ] Request timeout handling
- [ ] Graceful shutdown
- [ ] Health check endpoint
- [ ] Telemetry and monitoring
- [ ] Error recovery and retries
- [ ] Connection pooling (for client)
- [ ] Documentation

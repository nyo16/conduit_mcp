# Simple Tools MCP Server Example

This example demonstrates a minimal MCP (Model Context Protocol) server implementation using the ConduitMcp library. It provides two simple tools: `echo` and `reverse_string`.

## Features

- **Echo Tool**: Returns the input message unchanged
- **Reverse String Tool**: Reverses the input text
- **SSE Transport**: Uses Server-Sent Events for server-to-client communication
- **HTTP POST**: Accepts JSON-RPC 2.0 messages via POST /message

## Prerequisites

- Elixir 1.18 or later
- Mix dependencies installed

## Setup

1. From the project root, install dependencies:

```bash
mix deps.get
mix compile
```

## Running the Server

### Option 1: Using the run script (Recommended)

```bash
elixir examples/simple_tools_server/run.exs
```

### Option 2: Using Mix

First, update your `mix.exs` to use the example application:

```elixir
def application do
  [
    mod: {Examples.SimpleToolsServer.Application, []},
    # ...
  ]
end
```

Then run:

```bash
iex -S mix
```

The server will start on `http://localhost:4001` by default.

## Testing the Server

### 1. Health Check

```bash
curl http://localhost:4001/health
```

Expected response:
```json
{"status":"ok"}
```

### 2. Initialize Connection

```bash
curl -X POST http://localhost:4001/message \
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

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "serverInfo": {
      "name": "conduit-mcp",
      "version": "0.1.0"
    },
    "capabilities": {
      "tools": {},
      "resources": {},
      "prompts": {}
    }
  }
}
```

### 3. List Available Tools

```bash
curl -X POST http://localhost:4001/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
    "params": {}
  }'
```

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "echo",
        "description": "Echoes back the input message",
        "inputSchema": {
          "type": "object",
          "properties": {
            "message": {
              "type": "string",
              "description": "The message to echo back"
            }
          },
          "required": ["message"]
        }
      },
      {
        "name": "reverse_string",
        "description": "Reverses a string",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": {
              "type": "string",
              "description": "The text to reverse"
            }
          },
          "required": ["text"]
        }
      }
    ]
  }
}
```

### 4. Call the Echo Tool

```bash
curl -X POST http://localhost:4001/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "echo",
      "arguments": {
        "message": "Hello, MCP!"
      }
    }
  }'
```

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Hello, MCP!"
      }
    ]
  }
}
```

### 5. Call the Reverse String Tool

```bash
curl -X POST http://localhost:4001/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "reverse_string",
      "arguments": {
        "text": "Elixir is awesome"
      }
    }
  }'
```

Expected response:
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "emosewa si rixilE"
      }
    ]
  }
}
```

## Using with MCP Inspector

You can also test the server using the official MCP Inspector tool:

```bash
# Install MCP Inspector
npm install -g @modelcontextprotocol/inspector

# Run inspector
npx @modelcontextprotocol/inspector
```

Then configure it to connect to `http://localhost:4001/sse`.

## Project Structure

```
examples/simple_tools_server/
├── README.md          # This file
├── server.ex          # Server implementation with tools
├── application.ex     # Application supervisor
└── run.exs           # Standalone runner script
```

## Customization

To add your own tools, modify `server.ex`:

1. Add tool definition to the `@tools` module attribute
2. Implement the tool logic in `handle_call_tool/3`

Example:

```elixir
defmodule Examples.SimpleToolsServer do
  use ConduitMcp.Server

  @tools [
    %{
      "name" => "my_tool",
      "description" => "My custom tool",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "param" => %{"type" => "string", "description" => "Input parameter"}
        },
        "required" => ["param"]
      }
    }
  ]

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "my_tool", %{"param" => value}) do
    {:ok, %{
      "content" => [
        %{"type" => "text", "text" => "Result: #{value}"}
      ]
    }}
  end
end
```

## Protocol Information

- **Protocol Version**: 2025-06-18
- **Transport**: SSE (Server-Sent Events)
- **Message Format**: JSON-RPC 2.0
- **Endpoints**:
  - `GET /sse` - Server-Sent Events endpoint
  - `POST /message` - JSON-RPC message endpoint
  - `GET /health` - Health check endpoint

## Troubleshooting

### Port already in use

If port 4001 is already in use, set the PORT environment variable:

```bash
PORT=4002 elixir examples/simple_tools_server/run.exs
```

### Dependencies not found

Make sure you've compiled the project:

```bash
mix deps.get
mix compile
```

## Next Steps

- Explore the main implementation guide: `elixir_mcp_implementation_guide.md`
- Add more complex tools with side effects
- Implement resources for data access
- Add prompts for LLM interactions
- Integrate with Claude Desktop or other MCP clients

## Resources

- [MCP Specification](https://modelcontextprotocol.io/specification/)
- [ConduitMcp Documentation](../../README.md)
- [Hermes MCP (Inspiration)](https://github.com/cloudwalk/hermes-mcp)

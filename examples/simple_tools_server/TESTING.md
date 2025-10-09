# Testing the MCP Server

This guide shows you different ways to test your MCP server implementation.

## Method 1: MCP Inspector (Recommended)

The **MCP Inspector** is an official Node.js tool that provides a graphical interface to explore and test MCP servers.

### Install

```bash
npm install -g @modelcontextprotocol/inspector
```

### Usage

1. Start your MCP server:
```bash
elixir examples/simple_tools_server/run.exs
```

2. In another terminal, launch the inspector:
```bash
npx @modelcontextprotocol/inspector
```

3. In the inspector UI, configure:
   - **Transport**: SSE
   - **URL**: `http://localhost:4001/sse`

4. Click "Connect" and you'll see:
   - Available tools list
   - Ability to call tools interactively
   - Request/response history
   - JSON-RPC message details

## Method 2: Automated Test Script

We've provided a bash script that tests all endpoints:

```bash
# Make sure server is running first
elixir examples/simple_tools_server/run.exs &

# Run the test script
./examples/simple_tools_server/test_server.sh
```

This will test:
- Health check endpoint
- Initialize handshake
- List tools
- Call echo tool
- Call reverse_string tool

## Method 3: Manual curl Commands

### 1. Health Check

```bash
curl http://localhost:4001/health
```

Expected: `{"status":"ok"}`

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

### 4. Call Echo Tool

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

### 5. Call Reverse String Tool

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

## Method 4: SSE Stream Endpoint

You can also test the SSE endpoint directly:

```bash
curl -N http://localhost:4001/sse
```

You should see:
```
event: endpoint
data: {"type":"endpoint","endpoint":"/message"}

: keepalive
```

The server sends keepalive messages every 15 seconds.

## Method 5: Using IEx for Interactive Testing

Instead of the standalone script, you can use IEx for debugging:

```bash
iex -S mix
```

Then manually test:

```elixir
# The server should be started automatically by the application

# Manually call the server (for debugging)
GenServer.call(Examples.SimpleToolsServer, {:list_tools})
GenServer.call(Examples.SimpleToolsServer, {:call_tool, "echo", %{"message" => "test"}})
GenServer.call(Examples.SimpleToolsServer, {:call_tool, "reverse_string", %{"text" => "hello"}})
```

## Troubleshooting

### Port Already in Use

```bash
# Find what's using port 4001
lsof -i :4001

# Kill the process
kill -9 <PID>

# Or use a different port
PORT=4002 elixir examples/simple_tools_server/run.exs
```

### Server Not Responding

1. Check if server is running:
   ```bash
   ps aux | grep elixir
   ```

2. Check server logs in the terminal where you started it

3. Verify port is listening:
   ```bash
   lsof -i :4001
   ```

### Invalid JSON Responses

Make sure you're sending proper JSON-RPC 2.0 formatted requests with:
- `jsonrpc`: "2.0"
- `id`: unique request ID
- `method`: valid MCP method name
- `params`: parameters object (can be empty `{}`)

## Next Steps

After testing locally, you can:

1. **Integrate with Claude Desktop**: Add your server to Claude Desktop's MCP configuration
2. **Deploy**: Host your server and make it accessible to MCP clients
3. **Add More Tools**: Extend the server with additional functionality
4. **Add OAuth**: Implement OAuth 2.1 authentication for production use

## Resources

- [MCP Specification](https://modelcontextprotocol.io/specification/)
- [MCP Inspector GitHub](https://github.com/modelcontextprotocol/inspector)
- [Claude Desktop MCP Guide](https://docs.anthropic.com/claude/docs/mcp)

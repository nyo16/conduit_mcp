# VS Code / Claude Desktop MCP Setup

This guide shows how to test your MCP server with VS Code extensions and Claude Desktop.

## Option 1: VS Code with Cline Extension

### 1. Install Cline Extension

In VS Code:
- Press `Cmd+Shift+X` (Extensions)
- Search for "Cline" or "Claude Dev"
- Install the extension

### 2. Configure MCP Server

Open Cline settings and add this configuration:

**Location**: VS Code Settings → Extensions → Cline → Edit MCP Settings

**Or manually edit**: `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`

```json
{
  "mcpServers": {
    "simple-tools": {
      "url": "http://localhost:4001/",
      "transport": "http"
    }
  }
}
```

### 3. Start Your Server

```bash
cd /Users/niko/Source/conduit_mcp
elixir examples/simple_tools_server/run.exs
```

### 4. Use in Cline

Open Cline in VS Code and you should see the tools available:
- `echo` - Echo back messages
- `reverse_string` - Reverse strings

## Option 2: Claude Desktop

### 1. Locate Claude Desktop Config

The configuration file is at:
```
~/Library/Application Support/Claude/claude_desktop_config.json
```

### 2. Add Server Configuration

Edit the file and add (or merge with existing mcpServers):

```json
{
  "mcpServers": {
    "simple-tools": {
      "command": "elixir",
      "args": [
        "/Users/niko/Source/conduit_mcp/examples/simple_tools_server/run.exs"
      ],
      "env": {
        "PORT": "4001",
        "TRANSPORT": "streamable_http"
      }
    }
  }
}
```

### 3. Restart Claude Desktop

Quit and restart Claude Desktop completely for the changes to take effect.

### 4. Test in Claude

In a new conversation in Claude Desktop, you should be able to use:
- The `echo` tool
- The `reverse_string` tool

Claude will automatically discover and use these tools when relevant.

## Option 3: Direct HTTP Testing (Simplest!)

You already have working test scripts:

### Test with Shell Script

```bash
./examples/simple_tools_server/test_client.sh
```

Output:
```
=== Testing MCP Server ===

1. Connecting to SSE endpoint...
   ✓ Got endpoint: http://localhost:4001/message

2. Initializing connection...
   ✓ Server: conduit-mcp
   ✓ Protocol: 2025-06-18

3. Listing available tools...
   ✓ Found 2 tools:
     - echo: Echoes back the input message
     - reverse_string: Reverses a string

4. Testing echo tool...
   ✓ Echo tool works!

5. Testing reverse_string tool...
   ✓ Reverse tool works!

=== All Tests Passed! ===
```

### Test with curl + jq

```bash
# Initialize
curl -X POST http://localhost:4001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | jq

# List tools
curl -X POST http://localhost:4001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | jq '.result.tools'

# Call echo
curl -X POST http://localhost:4001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello!"}}}' | jq '.result.content[0].text'

# Call reverse_string
curl -X POST http://localhost:4001/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"reverse_string","arguments":{"text":"Testing"}}}' | jq '.result.content[0].text'
```

## Transport Modes

Your server supports both transports:

### Streamable HTTP (Default, Recommended)
```bash
elixir examples/simple_tools_server/run.exs
# or
TRANSPORT=streamable_http elixir examples/simple_tools_server/run.exs
```

Endpoint: `http://localhost:4001/`

### SSE (Legacy)
```bash
TRANSPORT=sse elixir examples/simple_tools_server/run.exs
```

Endpoints:
- SSE Stream: `http://localhost:4001/sse`
- Messages: `http://localhost:4001/message`

## Troubleshooting

### Server Not Starting

Check if port is in use:
```bash
lsof -i :4001
```

Kill and restart:
```bash
pkill -f "elixir.*simple_tools"
elixir examples/simple_tools_server/run.exs
```

### VS Code Extension Not Finding Server

1. Make sure server is running first
2. Check VS Code extension logs for errors
3. Try restarting VS Code
4. Verify the config file path is correct

### Testing Connection

Quick test:
```bash
curl http://localhost:4001/health
# Should return: {"status":"ok"}
```

## Files

- `mcp_config.json` - Generic MCP configuration
- `claude_desktop_config.json` - Claude Desktop specific format
- `test_client.sh` - Automated test script
- `VSCODE_SETUP.md` - This file

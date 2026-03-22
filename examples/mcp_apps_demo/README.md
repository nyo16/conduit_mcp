# MCP Apps Demo

A standalone MCP server demonstrating [MCP Apps](https://modelcontextprotocol.io/docs/extensions/apps) — interactive UI rendered as sandboxed iframes in host clients.

## Quick Start

```bash
cd examples/mcp_apps_demo
mix deps.get
mix run --no-halt
```

The server starts on `http://localhost:4001` (override with `PORT=5000 mix run --no-halt`).

## Connect with Claude Desktop

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "mcp-apps-demo": {
      "url": "http://localhost:4001/"
    }
  }
}
```

Restart Claude Desktop, then ask Claude to use the `server_health` tool. The host will see the `_meta.ui` field and render the dashboard as an interactive iframe.

## What's in the box

- **`server_health` tool** — returns BEAM metrics (memory, processes, uptime) and links to the dashboard UI via `_meta.ui.resourceUri`
- **`ui://server-health/dashboard.html` resource** — serves the self-contained HTML dashboard
- **`get_live_metrics` tool** — the UI can call this for refreshed data

## How it works

```
tools/list response:
{
  "name": "server_health",
  "_meta": { "ui": { "resourceUri": "ui://server-health/dashboard.html" } }
}

Host sees _meta.ui → fetches resource via resources/read → renders in iframe
```

## Project structure

```
├── mix.exs                              # Deps on conduit_mcp (path: "../..")
├── lib/mcp_apps_demo/
│   ├── application.ex                   # Starts Bandit on port 4001
│   └── server.ex                        # MCP server with tools + ui:// resource
└── priv/mcp_apps/
    └── dashboard.html                   # Self-contained HTML dashboard
```

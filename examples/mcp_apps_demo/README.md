# MCP Apps Demo

This example demonstrates how to build an MCP server with interactive UI using the [MCP Apps extension](https://modelcontextprotocol.io/docs/extensions/apps).

## What is MCP Apps?

MCP Apps lets tools return interactive HTML UI that hosts render as sandboxed iframes. The pattern:

1. A **tool** declares `_meta.ui.resourceUri` pointing to a `ui://` resource
2. A **resource** serves self-contained HTML at that URI
3. The host fetches the HTML via `resources/read` and renders it in an iframe

## Files

- `server.ex` — MCP server with a health dashboard tool and linked `ui://` resource
- `priv/mcp_apps/dashboard.html` — Self-contained HTML dashboard

## How It Works

### Server Side (Elixir)

```elixir
# Link tool to UI via ui/1 macro
tool "server_health", "Live server health dashboard" do
  ui "ui://server-health/dashboard.html"
  handle fn _conn, _params -> json(metrics) end
end

# Serve the HTML file as a ui:// resource
resource "ui://server-health/dashboard.html" do
  mime_type "text/html"
  read fn _conn, _params, _opts ->
    raw_resource(File.read!("priv/mcp_apps/dashboard.html"), "text/html")
  end
end
```

### Client Side (JavaScript)

The HTML file uses `@modelcontextprotocol/ext-apps` to communicate with the host:

```javascript
import { App } from "@modelcontextprotocol/ext-apps";
const app = new App({ name: "Server Health", version: "1.0.0" });

app.ontoolresult = (result) => {
  // Render initial tool result
  renderMetrics(JSON.parse(result.content[0].text));
};

// Call back to the server for live updates
const result = await app.callServerTool({
  name: "get_live_metrics",
  arguments: {}
});

app.connect();
```

## Building Production UIs

For production MCP Apps, bundle your UI into a single HTML file:

1. Create a JS/TS project with `@modelcontextprotocol/ext-apps`
2. Use [Vite](https://vitejs.dev/) + [vite-plugin-singlefile](https://www.npmjs.com/package/vite-plugin-singlefile) to bundle
3. Place the output `.html` in `priv/mcp_apps/`
4. Register the `ui://` resource in your MCP server

See the [MCP Apps Guide](../../guides/mcp_apps.md) for detailed instructions.

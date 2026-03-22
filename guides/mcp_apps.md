# MCP Apps

MCP Apps is the first official [MCP extension](https://modelcontextprotocol.io/docs/extensions/apps). It lets your tools return **interactive UI** that hosts (Claude, VS Code Copilot, Goose, etc.) render as sandboxed iframes right in the conversation.

Today when a tool returns text/JSON, the LLM reads and summarizes it. With MCP Apps, a tool can *also* point to a live HTML widget — a dashboard, form, chart, map — that the user interacts with directly.

## How It Works

1. A tool declares `_meta.ui.resourceUri` linking to a `ui://` resource
2. The host pre-fetches the resource HTML at connection time
3. When the tool is called, the host renders the HTML in a sandboxed iframe
4. The iframe runs the `ui/initialize` handshake, then receives the tool result
5. The app can call server tools, update model context, and respond to user interaction

## Quick Start

### DSL Mode — `ui/1` macro

Add `ui` inside a `tool` block, then define the matching resource.

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  # Tool with linked UI
  tool "dashboard", "Server health dashboard" do
    ui "ui://dashboard/app.html"

    handle fn _conn, _params ->
      json(%{cpu: 42, memory: 128, processes: 350})
    end
  end

  # Resource serving the HTML
  resource "ui://dashboard/app.html" do
    description "Dashboard UI"
    mime_type "text/html;profile=mcp-app"

    read fn _conn, _params, _opts ->
      html = File.read!(Application.app_dir(:my_app, "priv/mcp_apps/dashboard.html"))
      app_html(html)
    end
  end

  # A tool the UI can call back into for live data
  tool "get_live_metrics", "Fetch current metrics" do
    handle fn _conn, _params ->
      json(%{cpu: 55, memory: 256, timestamp: DateTime.utc_now()})
    end
  end
end
```

The `ui/1` macro sets `_meta.ui.resourceUri` on the tool. In the `tools/list` response:

```json
{
  "name": "dashboard",
  "_meta": {
    "ui": { "resourceUri": "ui://dashboard/app.html" }
  }
}
```

### Resource Helpers

`app_html/1` returns HTML content with the required MCP Apps MIME type:

```elixir
app_html(html_content)
# => {:ok, %{"contents" => [%{"mimeType" => "text/html;profile=mcp-app", "text" => html_content}]}}
```

The MIME type `text/html;profile=mcp-app` is required by the spec — hosts use it to identify renderable MCP App content.

For non-HTML resources, `raw_resource/2` accepts any MIME type:

```elixir
raw_resource(xml_content, "application/xml")
```

### Generic Metadata — `meta/1` macro

To attach arbitrary `_meta` fields (not just UI), use `meta/1`:

```elixir
tool "analytics", "Analytics with custom metadata" do
  meta %{
    ui: %{resourceUri: "ui://analytics/app.html"},
    custom_field: "any value"
  }

  handle fn _conn, _params -> json(%{ok: true}) end
end
```

## The `app/2` Convenience Macro

For quick prototyping, register both tool and resource in one declaration:

```elixir
app "metrics", "Server metrics view" do
  param :range, :string, "Time range", default: "1h"
  view "priv/mcp_apps/metrics.html"

  handle fn _conn, _params ->
    json(%{cpu: 42, memory: 128})
  end
end
```

This expands to a tool with `_meta.ui.resourceUri` and a resource serving the HTML file.

## Component Mode — `ui:` option

In Endpoint/Component mode, pass `ui:` in the component options:

```elixir
defmodule MyApp.Dashboard do
  use ConduitMcp.Component,
    type: :tool,
    description: "Health dashboard",
    ui: "ui://dashboard/app.html"

  schema do
    field :format, :string, "Output format"
  end

  @impl true
  def execute(_params, _conn) do
    json(%{status: "ok", cpu: 42})
  end
end

defmodule MyApp.DashboardUI do
  use ConduitMcp.Component,
    type: :resource,
    uri: "ui://dashboard/app.html",
    description: "Dashboard UI",
    mime_type: "text/html;profile=mcp-app"

  @impl true
  def execute(_params, _conn) do
    html = File.read!(Application.app_dir(:my_app, "priv/mcp_apps/dashboard.html"))
    app_html(html)
  end
end
```

## Building Interactive UIs

MCP Apps run inside sandboxed iframes and communicate with the host via JSON-RPC over `postMessage`. There are two approaches:

### Option 1: Inline Protocol (No Dependencies)

For simple apps, implement the protocol directly in your HTML. This is fully self-contained — no npm, no build step.

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
  body { font-family: system-ui; padding: 16px; background: #fff; }
  .metric { font-size: 2rem; font-weight: 700; color: #2563eb; }
  button { padding: 8px 16px; border-radius: 6px; border: none;
           background: #3b82f6; color: #fff; cursor: pointer; }
</style>
</head>
<body>
<h2>My Dashboard</h2>
<div class="metric" id="value">—</div>
<button id="refresh">Refresh</button>
<script>
(function() {
  var reqId = 0, pending = {}, notifHandlers = {}, reqHandlers = {};

  function send(msg) { window.parent.postMessage(msg, "*"); }

  function request(method, params) {
    return new Promise(function(resolve, reject) {
      var id = ++reqId;
      pending[id] = { resolve: resolve, reject: reject };
      send({ jsonrpc: "2.0", id: id, method: method, params: params || {} });
    });
  }

  function notification(method, params) {
    send({ jsonrpc: "2.0", method: method, params: params || {} });
  }

  window.addEventListener("message", function(ev) {
    var msg = ev.data;
    if (!msg || msg.jsonrpc !== "2.0") return;
    // Response to our request
    if (msg.id != null && pending[msg.id]) {
      var p = pending[msg.id]; delete pending[msg.id];
      msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
      return;
    }
    // Request from host (respond immediately)
    if (msg.id != null && msg.method) {
      var h = reqHandlers[msg.method];
      send({ jsonrpc: "2.0", id: msg.id, result: h ? h(msg.params) : {} });
      return;
    }
    // Notification from host
    if (msg.method) {
      var nh = notifHandlers[msg.method];
      if (nh) nh(msg.params);
    }
  });

  // Handle ping
  reqHandlers["ping"] = function() { return {}; };

  // --- Your app logic ---

  // Receive tool result from host
  notifHandlers["ui/notifications/tool-result"] = function(params) {
    var text = findText(params);
    if (text) render(JSON.parse(text));
  };

  function findText(params) {
    if (!params || !params.content) return null;
    for (var i = 0; i < params.content.length; i++)
      if (params.content[i].type === "text") return params.content[i].text;
    return null;
  }

  function render(data) {
    document.getElementById("value").textContent = data.cpu + "% CPU";
  }

  // Refresh button calls a server tool
  document.getElementById("refresh").addEventListener("click", function() {
    request("tools/call", { name: "get_live_metrics", arguments: {} })
      .then(function(result) {
        var text = findText(result);
        if (text) render(JSON.parse(text));
      });
  });

  // MCP Apps handshake
  request("ui/initialize", {
    appInfo: { name: "My Dashboard", version: "1.0.0" },
    appCapabilities: {},
    protocolVersion: "2026-01-26"
  }).then(function() {
    notification("ui/notifications/initialized");
  });
})();
</script>
</body>
</html>
```

#### Protocol Summary

The iframe communicates with the host via `postMessage` JSON-RPC:

| Direction | Method | Purpose |
|-----------|--------|---------|
| App → Host | `ui/initialize` | Handshake — app sends `appInfo`, `protocolVersion` |
| App → Host | `ui/notifications/initialized` | Confirms handshake complete |
| Host → App | `ui/notifications/tool-result` | Pushes tool result data to app |
| Host → App | `ui/notifications/tool-input` | Streams tool input as it's typed |
| App → Host | `tools/call` | Calls a server tool from the UI |
| App → Host | `ui/update-model-context` | Tells the LLM what the user did |
| App → Host | `ui/notifications/size-changed` | Reports iframe content size |
| Host → App | `ping` | Health check (respond with `{}`) |

### Option 2: SDK + Vite Build (Production)

For complex apps, use the official SDK with a build step:

```bash
mkdir my-mcp-app && cd my-mcp-app
npm init -y
npm install @modelcontextprotocol/ext-apps
npm install -D vite vite-plugin-singlefile typescript
```

**src/app.ts:**
```typescript
import { App } from "@modelcontextprotocol/ext-apps";

const app = new App({ name: "My App", version: "1.0.0" });

app.ontoolresult = (result) => {
  const text = result.content?.find(c => c.type === "text")?.text;
  if (text) renderData(JSON.parse(text));
};

document.getElementById("refresh")?.addEventListener("click", async () => {
  const result = await app.callServerTool({
    name: "get_live_metrics",
    arguments: {}
  });
  const text = result.content?.find(c => c.type === "text")?.text;
  if (text) renderData(JSON.parse(text));

  // Tell the LLM what the user did
  await app.updateModelContext({
    content: [{ type: "text", text: "User refreshed metrics" }]
  });
});

await app.connect();
```

**vite.config.ts:**
```typescript
import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

export default defineConfig({
  plugins: [viteSingleFile()],
  build: { rollupOptions: { input: "app.html" }, outDir: "dist" }
});
```

Build and copy to your Elixir project:
```bash
npx vite build
cp dist/app.html /path/to/priv/mcp_apps/
```

## Example Apps

### Metrics Dashboard

A live dashboard showing BEAM metrics with auto-refresh:

**Server (Elixir):**
```elixir
tool "server_health", "Live server health dashboard" do
  ui "ui://server-health/dashboard.html"

  handle fn _conn, _params ->
    json(%{
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      processes: :erlang.system_info(:process_count),
      uptime_sec: div(elem(:erlang.statistics(:wall_clock), 0), 1000),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end

tool "get_live_metrics", "Get current server metrics" do
  handle fn _conn, _params ->
    json(%{
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      processes: :erlang.system_info(:process_count),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
```

See `examples/mcp_apps_demo/` for the complete runnable project with HTML dashboard.

### Configuration Form

A tool that returns a settings form the user fills out:

**Server:**
```elixir
tool "configure_deploy", "Configure deployment settings" do
  ui "ui://deploy/config-form.html"

  handle fn _conn, params ->
    json(%{
      regions: ["us-east-1", "eu-west-1", "ap-southeast-1"],
      instance_types: ["t3.micro", "t3.small", "t3.medium"],
      current: %{region: "us-east-1", instance_type: "t3.small", replicas: 2}
    })
  end
end
```

**HTML (key parts):**
```html
<form id="form">
  <select id="region"></select>
  <select id="instance"></select>
  <input type="number" id="replicas" min="1" max="10">
  <button type="submit">Deploy</button>
</form>
<script>
notifHandlers["ui/notifications/tool-result"] = function(params) {
  var data = JSON.parse(findText(params));
  // Populate form dropdowns from data.regions, data.instance_types
  // Set current values from data.current
};

document.getElementById("form").addEventListener("submit", function(e) {
  e.preventDefault();
  // Call deploy tool with form values
  request("tools/call", {
    name: "run_deploy",
    arguments: {
      region: document.getElementById("region").value,
      instance_type: document.getElementById("instance").value,
      replicas: parseInt(document.getElementById("replicas").value)
    }
  });
});
</script>
```

### Data Visualization

A tool that renders a chart from query results:

**Server:**
```elixir
tool "sales_chart", "Interactive sales chart" do
  ui "ui://sales/chart.html"
  param :period, :string, "Time period", enum: ["7d", "30d", "90d"], default: "30d"

  handle fn _conn, params ->
    period = params["period"] || "30d"
    data = MyApp.Analytics.sales_by_day(period)
    json(%{period: period, data: data})
  end
end
```

**HTML (using inline Chart.js from CDN via CSP):**
```html
<canvas id="chart" width="400" height="200"></canvas>
<script>
notifHandlers["ui/notifications/tool-result"] = function(params) {
  var result = JSON.parse(findText(params));
  // Render chart with result.data
  drawBarChart(result.data);
};
</script>
```

> **Note:** To load external scripts (Chart.js, D3, etc.), the resource needs `_meta.ui.csp` configured to allow the CDN origin. See the [MCP Apps spec](https://modelcontextprotocol.io/docs/extensions/apps) for CSP details.

## Host Support

MCP Apps is supported by:
- **VS Code** (GitHub Copilot) — full support, `url` key in settings
- **Claude** (claude.ai) — supported via Custom Connectors
- **Claude Desktop** — supported (use `mcp-remote` bridge for HTTP servers)
- **Goose** — supported
- **Postman** — supported

See the [client matrix](https://modelcontextprotocol.io/extensions/client-matrix) for the full list.

## Testing with VS Code

The simplest way to test locally:

1. Start your server: `mix run --no-halt`
2. Add to VS Code settings (JSON):
```json
{
  "mcp": {
    "servers": {
      "my-server": {
        "url": "http://localhost:4001/"
      }
    }
  }
}
```
3. Open Copilot Chat and ask to use your tool

## Security

- All UI runs in **sandboxed iframes** with restricted permissions
- HTML is **pre-declared as resources** — hosts can inspect before rendering
- UI-to-host communication goes through **loggable JSON-RPC**
- Hosts can require **user consent** for UI-initiated tool calls
- Use `_meta.ui.csp` to control which external origins the app can load from

## References

- [MCP Apps Docs](https://modelcontextprotocol.io/docs/extensions/apps)
- [SDK (npm)](https://www.npmjs.com/package/@modelcontextprotocol/ext-apps) — `@modelcontextprotocol/ext-apps`
- [Examples](https://github.com/modelcontextprotocol/ext-apps/tree/main/examples) — React, Vue, Svelte, vanilla JS starters
- [Specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)
- [Build Guide](https://modelcontextprotocol.io/extensions/apps/build)

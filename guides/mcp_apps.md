# MCP Apps

MCP Apps is the first official [MCP extension](https://modelcontextprotocol.io/docs/extensions/apps). It lets your tools return **interactive UI** that hosts (Claude, ChatGPT, VS Code, Goose, etc.) render as sandboxed iframes right in the conversation.

Today when a tool returns text/JSON, the LLM reads and summarizes it. With MCP Apps, a tool can *also* point to a live HTML widget — a dashboard, form, chart, map — that the user interacts with directly.

## How It Works

1. A tool declares `_meta.ui.resourceUri` linking to a `ui://` resource
2. The resource serves a self-contained HTML file
3. When the host calls the tool, it fetches the resource and renders it in a sandboxed iframe
4. The iframe communicates back via JSON-RPC over `postMessage`

## Quick Start

### DSL Mode — `ui/1` macro

The simplest way: add `ui` inside a `tool` block, then define the matching resource.

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
    mime_type "text/html"

    read fn _conn, _params, _opts ->
      html = File.read!(Application.app_dir(:my_app, "priv/mcp_apps/dashboard.html"))
      raw_resource(html, "text/html")
    end
  end

  # A tool the UI can call back into
  tool "get_live_metrics", "Fetch current metrics" do
    handle fn _conn, _params ->
      json(%{cpu: 55, memory: 256, timestamp: DateTime.utc_now()})
    end
  end
end
```

The `ui/1` macro sets `_meta.ui.resourceUri` on the tool. In the `tools/list` response, this appears as:

```json
{
  "name": "dashboard",
  "description": "Server health dashboard",
  "inputSchema": { ... },
  "_meta": {
    "ui": {
      "resourceUri": "ui://dashboard/app.html"
    }
  }
}
```

### Generic Metadata — `meta/1` macro

If you need to attach arbitrary `_meta` fields (not just UI), use `meta/1`:

```elixir
tool "analytics", "Analytics with custom metadata" do
  meta %{
    ui: %{resourceUri: "ui://analytics/app.html"},
    custom_field: "any value"
  }

  handle fn _conn, _params -> json(%{ok: true}) end
end
```

Atom keys are automatically converted to string keys in the JSON output.

### Resource Helper — `raw_resource/2`

The `raw_resource/2` helper makes it easy to return content with a MIME type from resource handlers:

```elixir
raw_resource(html_content, "text/html")
# => {:ok, %{"contents" => [%{"mimeType" => "text/html", "text" => html_content}]}}
```

## The `app/2` Convenience Macro

For quick prototyping, the `app` macro registers both the tool and resource in one declaration:

```elixir
app "metrics", "Server metrics view" do
  param :range, :string, "Time range", default: "1h"
  view "priv/mcp_apps/metrics.html"

  handle fn _conn, _params ->
    json(%{cpu: 42, memory: 128})
  end
end
```

This expands to:
- A tool named `"metrics"` with `_meta.ui.resourceUri` set to `"ui://metrics/metrics.html"`
- A resource at `"ui://metrics/metrics.html"` that reads the HTML file

The `view` path is read with `File.read!/1` at runtime. For OTP releases where the working directory may differ, use the explicit `tool` + `resource` pair with `Application.app_dir/2` instead.

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
    mime_type: "text/html"

  @impl true
  def execute(_params, _conn) do
    html = File.read!(Application.app_dir(:my_app, "priv/mcp_apps/dashboard.html"))
    raw_resource(html, "text/html")
  end
end

defmodule MyApp.MCPServer do
  use ConduitMcp.Endpoint, name: "My App", version: "1.0.0"

  component MyApp.Dashboard
  component MyApp.DashboardUI
end
```

The `_meta` flows through automatically — no Endpoint changes needed.

## Building the Client-Side UI

The HTML file must be **self-contained** (all CSS/JS inlined). The recommended workflow:

### 1. Create a JS/TS project

```bash
mkdir my-mcp-app-ui && cd my-mcp-app-ui
npm init -y
npm install @modelcontextprotocol/ext-apps
npm install -D vite vite-plugin-singlefile typescript
```

### 2. Write your app

**src/app.ts:**
```typescript
import { App } from "@modelcontextprotocol/ext-apps";

const app = new App({ name: "My App", version: "1.0.0" });

app.ontoolresult = (result) => {
  const text = result.content?.find(c => c.type === "text")?.text;
  if (text) {
    const data = JSON.parse(text);
    // Use safe DOM methods to render data
    const el = document.getElementById("app")!;
    el.textContent = JSON.stringify(data, null, 2);
  }
};

document.getElementById("refresh")?.addEventListener("click", async () => {
  const result = await app.callServerTool({
    name: "get_live_metrics",
    arguments: {}
  });
  // Re-render with fresh data...

  await app.updateModelContext({
    content: [{ type: "text", text: "User refreshed metrics" }]
  });
});

app.connect();
```

**app.html:**
```html
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>My App</title></head>
<body>
  <div id="app">Loading...</div>
  <button id="refresh">Refresh</button>
  <script type="module" src="/src/app.ts"></script>
</body>
</html>
```

### 3. Configure Vite

**vite.config.ts:**
```typescript
import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    rollupOptions: { input: "app.html" },
    outDir: "dist"
  }
});
```

### 4. Build and deploy

```bash
npx vite build
cp dist/app.html /path/to/your/elixir/priv/mcp_apps/
```

The output is a single HTML file with all JS/CSS inlined — ready to serve as a `ui://` resource.

## App API

The `@modelcontextprotocol/ext-apps` SDK provides:

| Method | Description |
|--------|-------------|
| `app.ontoolresult` | Callback receiving the initial tool result |
| `app.callServerTool({ name, arguments })` | Call any MCP tool from the UI |
| `app.updateModelContext({ content })` | Push context to the model (so the LLM knows about user actions) |
| `app.connect()` | Establish connection with the host |

All communication uses JSON-RPC over `postMessage`.

## Security

- All UI runs in **sandboxed iframes** with restricted permissions
- HTML is **pre-declared as resources** — hosts can inspect before rendering
- UI-to-host communication goes through **loggable JSON-RPC**
- Hosts can require **user consent** for UI-initiated tool calls

## References

- [MCP Apps Blog Post](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/)
- [MCP Apps Docs](https://modelcontextprotocol.io/docs/extensions/apps)
- [SDK (npm)](https://www.npmjs.com/package/@modelcontextprotocol/ext-apps)
- [Examples](https://github.com/modelcontextprotocol/ext-apps/tree/main/examples)
- [Specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)

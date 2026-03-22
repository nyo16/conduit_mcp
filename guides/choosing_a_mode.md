# Choosing a Mode

ConduitMCP offers three ways to build MCP servers. Each mode gives you a different level of abstraction and control.

## Comparison

| Feature | DSL Mode | Manual Mode | Endpoint Mode |
|---------|----------|-------------|---------------|
| **Server definition** | Single module with macros | Single module with callbacks | Endpoint + separate component modules |
| **Tool definition** | `tool "name" do ... end` | Raw JSON Schema maps | One module per tool |
| **Schema generation** | Automatic at compile time | Manual (you build the maps) | Automatic from `schema do field ... end` |
| **Validation** | Automatic | Manual | Automatic |
| **Response helpers** | `text/1`, `json/1`, `error/1` | Build maps yourself | `text/1`, `json/1`, `error/1` |
| **Rate limiting** | Transport option | Transport option | Declarative in `use` opts |
| **Params format** | String-keyed maps | String-keyed maps | Atom-keyed maps |
| **Best for** | Quick setup, small servers | Maximum control, custom schemas | Larger servers, team projects |

## When to Use Each

### DSL Mode (`use ConduitMcp.Server`)

Best when you want to get started quickly. Tools, prompts, and resources are defined inline with macros. Schemas and validation are generated automatically.

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  tool "greet", "Greet someone" do
    param :name, :string, "Name", required: true
    handle fn _conn, %{"name" => name} -> text("Hello, #{name}!") end
  end
end
```

**Choose DSL when:** You have a small-to-medium server, want minimal boilerplate, and don't need tools as separate modules.

### Manual Mode (`use ConduitMcp.Server, dsl: false`)

Best when you need full control over JSON Schema definitions and callback implementations. No compile-time magic.

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server, dsl: false

  @impl true
  def handle_list_tools(_conn), do: {:ok, %{"tools" => [...]}}

  @impl true
  def handle_call_tool(_conn, "greet", %{"name" => name}), do: ...
end
```

**Choose Manual when:** You need custom JSON Schema features not supported by the DSL, or you want explicit control over every callback.

### Endpoint Mode (`use ConduitMcp.Endpoint`)

Best for larger servers where each tool, resource, or prompt is its own module. Rate limiting and auth are declarative. Params arrive as atom-keyed maps.

```elixir
defmodule MyApp.Echo do
  use ConduitMcp.Component, type: :tool, description: "Echoes text"

  schema do
    field :text, :string, "Text to echo", required: true
  end

  @impl true
  def execute(%{text: text}, _conn), do: text(text)
end

defmodule MyApp.MCPServer do
  use ConduitMcp.Endpoint,
    name: "My Server",
    version: "1.0.0",
    rate_limit: [backend: MyApp.RateLimiter, limit: 60, scale: 60_000]

  component MyApp.Echo
end
```

**Choose Endpoint when:** You want each tool as its own module (better for testing, code organization, team collaboration), or you want rate limiting built into the server definition.

## Mixing Modes

The three modes are **independent alternatives** — you pick one per server module. However, you can have multiple server modules in the same application, each using a different mode.

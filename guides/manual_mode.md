# Manual Mode

Manual mode gives you full control over callback implementations and JSON Schema definitions. No compile-time macros — you build everything yourself.

## Setup

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server, dsl: false

  # You implement callbacks directly
end
```

This gives you default stub implementations for all 6 callbacks (returning empty lists). Override the ones you need.

## Callbacks

| Callback | Purpose |
|----------|---------|
| `handle_list_tools(conn)` | Return tool schemas |
| `handle_call_tool(conn, name, params)` | Execute a tool |
| `handle_list_resources(conn)` | Return resource schemas |
| `handle_read_resource(conn, uri)` | Read a resource |
| `handle_list_prompts(conn)` | Return prompt schemas |
| `handle_get_prompt(conn, name, args)` | Get prompt messages |

Optional callbacks: `handle_complete/3`, `handle_set_log_level/2`, `handle_subscribe_resource/2`, `handle_unsubscribe_resource/2`.

## Example

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server, dsl: false

  @tools [
    %{
      "name" => "greet",
      "description" => "Greet someone",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Person's name"},
          "formal" => %{"type" => "boolean", "description" => "Use formal greeting"}
        },
        "required" => ["name"]
      }
    },
    %{
      "name" => "add",
      "description" => "Add two numbers",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number"},
          "b" => %{"type" => "number"}
        },
        "required" => ["a", "b"]
      }
    }
  ]

  @impl true
  def handle_list_tools(_conn), do: {:ok, %{"tools" => @tools}}

  @impl true
  def handle_call_tool(_conn, "greet", %{"name" => name} = params) do
    greeting = if params["formal"], do: "Good day", else: "Hey"
    {:ok, %{"content" => [%{"type" => "text", "text" => "#{greeting}, #{name}!"}]}}
  end

  def handle_call_tool(_conn, "add", %{"a" => a, "b" => b}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "#{a + b}"}]}}
  end

  def handle_call_tool(_conn, name, _params) do
    {:error, %{"code" => -32601, "message" => "Tool not found: #{name}"}}
  end
end
```

## Return Format

All callbacks must return `{:ok, map()}` or `{:error, map()}` with **string keys**:

```elixir
# Success
{:ok, %{"content" => [%{"type" => "text", "text" => "Hello!"}]}}

# Error
{:error, %{"code" => -32601, "message" => "Not found"}}
```

## When to Use Manual Mode

- You need JSON Schema features not supported by the DSL (e.g., `oneOf`, `allOf`, `$ref`)
- You want to load tool definitions dynamically at runtime
- You need precise control over every response map
- You're wrapping an existing API and generating schemas programmatically

# Manual Mode

Manual mode gives you full control over callback implementations and JSON Schema definitions. No compile-time macros — you build everything yourself.

## Setup

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server, dsl: false

  # You implement callbacks directly
end
```

This gives you default implementations for all 6 callbacks. The list callbacks return empty lists; `handle_call_tool/3` and `handle_get_prompt/3` answer `-32602` ("Unknown tool"/"Unknown prompt"), and `handle_read_resource/2` answers the legacy resource-not-found code `-32002`. Override the ones you need.

`use ConduitMcp.Server, dsl: false, instructions: "..."` sets the server's instructions, returned by `initialize` and `server/discover` (a transport's `:instructions` option overrides it):

```elixir
use ConduitMcp.Server, dsl: false, instructions: "Call search before fetch."
```

## Callbacks

| Callback | Purpose |
|----------|---------|
| `handle_list_tools(conn)` | Return tool schemas |
| `handle_call_tool(conn, name, params)` | Execute a tool |
| `handle_list_resources(conn)` | Return resource schemas |
| `handle_read_resource(conn, uri)` | Read a resource |
| `handle_list_prompts(conn)` | Return prompt schemas |
| `handle_get_prompt(conn, name, args)` | Get prompt messages |

Optional callbacks: `handle_complete/3`, `handle_set_log_level/2`, `handle_subscribe_resource/2`, `handle_unsubscribe_resource/2`. `handle_set_log_level/2` and the subscribe callbacks serve the legacy era only; modern clients send a per-request `logLevel` and use `subscriptions/listen` (see [Protocol Eras](protocol_eras.md) and [Subscriptions](subscriptions.md)).

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
    {:error, %{"code" => ConduitMcp.Errors.invalid_params(), "message" => "Unknown tool: #{name}"}}
  end
end
```

An unknown tool is `-32602`, as the MCP specification prescribes. Don't use `-32601`: on the modern era it means "method not found" and is answered with HTTP 404.

## Return Format

All callbacks must return `{:ok, map()}` or `{:error, map()}` with **string keys**:

```elixir
# Success
{:ok, %{"content" => [%{"type" => "text", "text" => "Hello!"}]}}

# Error
{:error, %{"code" => ConduitMcp.Errors.invalid_params(), "message" => "Bad input"}}
```

On a modern-era request, two more returns are accepted:

| Return | From | See |
|---|---|---|
| `{:input_required, input_requests, state}` | `handle_call_tool/3`, `handle_read_resource/2`, `handle_get_prompt/3` | [MRTR](mrtr.md) |
| `{:task, attrs}` | `handle_call_tool/3` | [Tasks Extension](tasks_extension.md) |

On a legacy request, and from any other callback, both are answered with `-32603`.

For a missing resource, return `ConduitMcp.Protocol.Legacy.resource_not_found()` (`-32002`). Modern clients get `-32602`, because `ConduitMcp.Protocol.Modern` rewrites the code.

## Header annotations

To mirror a tool argument into an `Mcp-Param-*` header, add `"x-mcp-header"` to its property:

```elixir
"properties" => %{
  "region" => %{"type" => "string", "x-mcp-header" => "Region"}
}
```

`ConduitMcp.Plugs.HeaderValidation` reads the annotations from your `handle_list_tools` (following `nextCursor`) on the first `tools/call`, and caches them per server module in `:persistent_term`. Unlike DSL and Component servers, manual servers aren't checked at compile time. A tool whose annotations are invalid is logged at `:error` when the cache is built (naming the tool and header, never values) and is left out of header validation.

If your tool list changes at runtime, drop the cache after the change:

```elixir
ConduitMcp.Plugs.HeaderValidation.invalidate(MyApp.MCPServer)
```

The next `tools/call` rebuilds it. `:persistent_term` updates trigger a global GC pass, so this suits tool lists that change rarely. To tell connected modern clients, call `ConduitMcp.notify_tools_changed/0`.

## Cache hints

Modern `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read` and `server/discover` results carry `ttlMs` and `cacheScope`. A manual server gets the global defaults:

```elixir
config :conduit_mcp, cache_ttl_ms: 60_000, cache_scope: :private
```

Scoped items are still kept private. To override per item, define `__cache_hints__/0`:

```elixir
def __cache_hints__ do
  %{
    tools: %{"catalog" => %{ttl_ms: 5_000, scope: :public}},
    prompts: %{},
    resources: [{"docs://{page}", %{ttl_ms: 300_000, scope: nil}}]
  }
end
```

A `nil` value falls back to the default. Resources are listed in dispatch order, as `{uri_or_template, hint}`. See `ConduitMcp.CacheHints`.

## Calling the handler directly

Transports call `ConduitMcp.Handler.dispatch/3`. To drive a server without HTTP (tests, a custom transport), you have two entry points:

| | `dispatch/3` | `handle_request/3` |
|---|---|---|
| Returns | `{:reply, response}`, `{:stream, %ConduitMcp.StreamSpec{}}` or `:noreply` | a response map, or `:ok` for a notification or a JSON-RPC response |
| Streamed `tools/call` (`progressToken` / `logLevel`) | `{:stream, spec}`, which you run | run to completion in the calling process; notifications dropped |
| `subscriptions/listen` | `{:stream, %StreamSpec{kind: :listen}}` | `-32601`: a map can't hold a stream open |

```elixir
request = %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "method" => "tools/call",
  "params" => %{"name" => "greet", "arguments" => %{"name" => "Ada"}}
}

ConduitMcp.Handler.handle_request(request, MyApp.MCPServer, conn)
#=> %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"content" => [...]}}

case ConduitMcp.Handler.dispatch(request, MyApp.MCPServer, conn) do
  {:reply, response} -> response
  {:stream, %ConduitMcp.StreamSpec{kind: :response} = spec} -> ConduitMcp.StreamSpec.run(spec)
  {:stream, %ConduitMcp.StreamSpec{kind: :listen}} -> :needs_a_streaming_transport
  :noreply -> :ok
end
```

Both classify the request's era themselves when given a conn. `ConduitMcp.Progress.report/3` and `ConduitMcp.Log.log/4` do nothing under `handle_request/3` or `StreamSpec.run/1`, so tools can call them unconditionally.

## When to Use Manual Mode

- You need JSON Schema features not supported by the DSL (e.g., `oneOf`, `allOf`, `$ref`)
- You want to load tool definitions dynamically at runtime
- You need precise control over every response map
- You're wrapping an existing API and generating schemas programmatically

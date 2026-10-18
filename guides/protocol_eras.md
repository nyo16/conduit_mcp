# Protocol Eras

ConduitMCP serves two generations of MCP on the same endpoint:

| Era | Versions | How the version is chosen |
|---|---|---|
| **Modern** | `2026-07-28` | Every request carries its version and client capabilities in `params._meta`. No handshake, no sessions. |
| **Legacy** | `2025-11-25`, `2025-06-18` | `initialize` negotiates a version once; later requests may share an `Mcp-Session-Id`. |

Your server module doesn't change. The same callbacks serve both eras, and
the request body decides which era a request belongs to. This guide covers
what differs on the wire and the modern-only features.

```elixir
ConduitMcp.Protocol.supported_versions()
#=> ["2026-07-28", "2025-11-25", "2025-06-18"]

ConduitMcp.Protocol.modern_versions()  #=> ["2026-07-28"]
ConduitMcp.Protocol.legacy_versions()  #=> ["2025-11-25", "2025-06-18"]
```

`initialize` only ever negotiates a legacy version. A modern client never
calls it.

## Classifying a request

`ConduitMcp.Era.classify/2` looks at two `_meta` keys:

- `pv` is `params._meta["io.modelcontextprotocol/protocolVersion"]`
- `caps` is `params._meta["io.modelcontextprotocol/clientCapabilities"]`

| `_meta` carries | method | result |
|---|---|---|
| `pv` and `caps` | any (including `initialize`) | modern |
| only one of `pv` and `caps` | any | `-32602`, HTTP 400 |
| neither | `server/discover` | modern (era-exempt, no version) |
| neither | anything else | legacy |

A request that carries only one of the two keys is rejected rather than
guessed at (`-32602`, HTTP 400). A modern request is also rejected with
`-32602` when:

- `pv` is not a string;
- `caps` is not an object;
- `io.modelcontextprotocol/clientInfo` is present but not an object;
- `io.modelcontextprotocol/logLevel` is present but not an MCP logging level.

These error messages name the key, never its value.

Callbacks read the result from the conn:

```elixir
def handle_call_tool(conn, "whoami", _params) do
  case ConduitMcp.Ctx.from_conn(conn) do
    %ConduitMcp.Ctx{era: :modern, version: v, client_info: info} ->
      text("modern #{v}: #{inspect(info)}")

    %ConduitMcp.Ctx{era: :legacy} ->
      text("legacy client")
  end
end
```

`client_info` is whatever the client says about itself. Never base a
security decision on it. The other `ConduitMcp.Ctx` fields are
`client_capabilities`, `extensions`, `log_level`, `principal`, `request_id`,
`server_info` and the W3C trace-context keys (`traceparent`, `tracestate`,
`baggage`). Invalid trace-context values are dropped, not rejected.

### Mixed requests

The `Mcp-Session-Id` header never changes the era. A modern request that
sends one anyway is still modern, and its session is ignored. Cancellation
scoping then falls back to the principal, and after that to the client IP.

There is one exception. If the header names a live session that recorded a
principal, the modern request must come from that same principal. Otherwise
it is rejected with `-32600` (HTTP 400), so a session id can't be carried
over to a different caller.

## `server/discover`

`server/discover` tells a client which versions and capabilities a server
has, without a handshake. It is era-exempt: it is served as modern even
with no `_meta`, because a client may call it to find out which era the
server speaks.

```json
{"jsonrpc": "2.0", "id": 1, "method": "server/discover"}
```

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "supportedVersions": ["2026-07-28", "2025-11-25", "2025-06-18"],
    "capabilities": {
      "tools": {"listChanged": true},
      "resources": {"listChanged": true, "subscribe": true},
      "logging": {}
    },
    "instructions": "Use search before fetch.",
    "resultType": "complete",
    "ttlMs": 60000,
    "cacheScope": "private",
    "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "my-server", "version": "1.0.0"}}
  }
}
```

`server/discover` is authenticated like every other POST, because
capabilities can depend on who is asking. On the modern era, every
advertised `tools`, `prompts` and `resources` capability gets
`listChanged: true`, and `resources` also gets `subscribe: true`, because
every modern server answers `subscriptions/listen` (see
[Subscriptions](subscriptions.md)). `logging` is always declared, because
any tool can send log messages (see "Per-request logging"). `instructions`
is left out when there are none.

### Instructions

`instructions` is free-text guidance for the client. It is returned by both
`server/discover` and the legacy `initialize`. Set it in one of three
places; the transport option wins:

```elixir
use ConduitMcp.Server, instructions: "Use search before fetch."

use ConduitMcp.Endpoint, name: "My Server", version: "1.0.0",
  instructions: "Use search before fetch."

{ConduitMcp.Transport.StreamableHTTP,
 server_module: MyApp.MCPServer,
 instructions: "Use search before fetch."}
```

The transport raises `ArgumentError` at `init/1` if `:instructions` is not
a string.

## Request headers

Over Streamable HTTP, a modern client copies selected body fields into HTTP
headers, so proxies and gateways can route without parsing JSON.
`ConduitMcp.Plugs.HeaderValidation` checks them against the body. A header
that disagrees with the body could send a request somewhere its body didn't
intend, so every failure is HTTP 400.

```http
POST / HTTP/1.1
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: tools/call
Mcp-Name: get_weather
Mcp-Param-Region: eu-west

{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
 "params": {"name": "get_weather", "arguments": {"region": "eu-west"},
            "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                      "io.modelcontextprotocol/clientCapabilities": {}}}}
```

The checks run in this order:

1. `MCP-Protocol-Version` is present, appears once, and equals the `_meta`
   version. Otherwise `-32020`.
2. That version is one this server implements. Otherwise `-32022`, with
   `data.supported` and `data.requested`. Check 1 runs first, so a header
   that disagrees with the body is `-32020` even when neither version is
   supported.
3. `Mcp-Method` is present, appears once, and equals the body `method`.
   Otherwise `-32020`.
4. `Mcp-Name` is required on `tools/call` and `prompts/get` (equal to
   `params.name`), on `resources/read` (equal to `params.uri`), and on the
   tasks extension's `tasks/get`, `tasks/update` and `tasks/cancel` (equal
   to `params.taskId`). Otherwise `-32020`.
5. On `tools/call`, each `Mcp-Param-{Name}` header must match its argument.
   The header must be present when the argument has a non-null value, and
   absent when it doesn't. Otherwise `-32020`.

Error messages name the header, never its value. Nothing in this plug logs
a header value.

A legacy request skips these checks, with one rule of its own: if it sends
an `MCP-Protocol-Version` header naming a version this server doesn't
support, it gets HTTP 400 with `-32600` and `data.supported`. `initialize`
is exempt from that rule, and a request without the header is served.

### Value encoding

Strings are sent as they are, integers in decimal, and booleans as
`true`/`false`. A string that isn't plain header-safe ASCII is sent as
`=?base64?{Base64 of its UTF-8 bytes}?=`. That covers bytes outside
`0x20..0x7E`, a leading or trailing space, and a string that could be
mistaken for that wrapper. `ConduitMcp.Headers.encode_value/1` and
`decode_value/1` implement the encoding. Integers compare numerically:
body values `42` and `42.0` both match the header `"42"`.

### `Mcp-Param-*`: the `header:` option

To have a tool argument mirrored into a header, give the param a `header:`
name. It publishes `"x-mcp-header"` on the property in `tools/list`, and
modern clients then send the header.

```elixir
# DSL
tool "get_weather", "Weather by region" do
  param :region, :string, "Region", required: true, header: "Region"
  handle fn _conn, %{"region" => region} -> text("Sunny in #{region}") end
end

# Component
schema do
  field :region, :string, "Region", required: true, header: "Region"
end
```

If the annotation is invalid, the build fails with a `CompileError`. The
param must be `:string`, `:integer` or `:boolean`, and reachable through
object properties only, never inside array `items`. The name must be an
RFC 9110 token, unique within the tool regardless of case. `header:` on a
prompt argument, or on a prompt or resource component, is also a compile
error.

Manual-mode servers write `"x-mcp-header"` into their own `inputSchema`.
`HeaderValidation` reads the annotations from the server's `tools/list` the
first time a `tools/call` comes in, and caches them per server module. A
tool with invalid annotations is logged at `:error` and left out of the
header checks. A server whose tool list changes at runtime calls
`ConduitMcp.Plugs.HeaderValidation.invalidate/1` (see
[Manual Mode](manual_mode.md)).

> #### Browsers and CORS {: .info}
>
> `access-control-allow-headers` has no wildcard that works for
> credentialed requests. The defaults cover `content-type`,
> `authorization`, `mcp-session-id`, `mcp-protocol-version`, `mcp-method`
> and `mcp-name`. A browser client of a tool with `header:` params needs
> those names added to `:cors_headers`:
>
> ```elixir
> {ConduitMcp.Transport.StreamableHTTP,
>  server_module: MyApp.MCPServer,
>  cors_origin: "https://app.example",
>  cors_headers:
>    "content-type, authorization, mcp-session-id, mcp-protocol-version, " <>
>      "mcp-method, mcp-name, mcp-param-region"}
> ```

## HTTP status codes

A modern response's status depends on the outcome, not always 200:

| Outcome | Status |
|---|---|
| Result, or a method error such as an unknown tool's `-32602` | 200 |
| Notification | 202, no body |
| Any rejection before the method runs (`Era.classify/2`, `HeaderValidation`) | 400 |
| `-32020`, `-32021`, `-32022` | 400 |
| `-32601` (unknown method, including every legacy-only method) | 404 |
| Insufficient scope under `strategy: :oauth` | 403 with an `insufficient_scope` challenge |
| `subscriptions/listen` without `text/event-stream` in `Accept` | 406 |
| `subscriptions/listen` over `:max_listens_per_principal` | 429 |
| `subscriptions/listen` when `:max_streams` is full | 503 |

`ConduitMcp.Protocol.Modern.http_status/1` maps a response to its status.
The modern response echoes the request's version in `mcp-protocol-version`.
A legacy JSON-RPC response is sent at 200 (202 for a notification), except
for the 403 OAuth challenge. The legacy checks that run before dispatch
answer with their own status: the unsupported-version 400 and the session
400/404.

Authentication and HTTP rate limiting run before era classification, so
their 401 and 429 responses look the same in both eras. A modern request
rejected by classification or header validation is not counted by
`:message_rate_limit`.

## Results and cache hints

Every modern result carries `"resultType"` (`"complete"`,
`"input_required"` or `"task"`) and the server's name and version in
`_meta["io.modelcontextprotocol/serverInfo"]`.

Six results also carry cache hints: `server/discover`, `tools/list`,
`prompts/list`, `resources/list`, `resources/templates/list` and
`resources/read`. Each gets `"ttlMs"` and `"cacheScope"`. The defaults come
from the application environment and are checked at boot:

```elixir
config :conduit_mcp, cache_ttl_ms: 60_000, cache_scope: :private
```

A tool, prompt or resource can override them:

```elixir
# DSL, inside a tool, prompt or resource block
tool "catalog", "Public catalog" do
  cache ttl_ms: 5_000, scope: :public
  handle fn _conn, _params -> text("...") end
end

# Component
use ConduitMcp.Component, type: :tool, description: "Public catalog",
  cache: [ttl_ms: 5_000, scope: :public]
```

The hints resolve as follows (`ConduitMcp.CacheHints`):

- A list result takes the **minimum** TTL across its items. It is `private`
  if **any** item is private or has a `scope`. A scoped item is never
  cached as public, even when the global default is `:public`.
- `resources/read` uses the hint of the resource that serves the URI: its
  exact static URI, otherwise the first matching template. It is `private`
  when that resource is scoped.
- `server/discover` uses the defaults.

Declaring both `scope` and `cache scope: :public` on one item is a compile
error. Manual-mode servers get the defaults, with the scoped-means-private
rule still applied, and may define `__cache_hints__/0` to declare
overrides. `input_required` and `task` results never carry cache hints.

## Per-request logging

A modern client asks for log messages on one request at a time, with
`_meta["io.modelcontextprotocol/logLevel"]`; `logging/setLevel` belongs to
the legacy era. Without a `logLevel`, the server must not send
`notifications/message` for that request. `ConduitMcp.Ctx.log?/2` applies
this rule, and `ConduitMcp.Log.log/4` checks it for you. Every modern
`server/discover` declares the `logging` capability, which the spec requires
of a server that sends log messages; the legacy `initialize` declares it only
when the server module defines `handle_set_log_level/2`.

## Streamed tool responses

A modern `tools/call` whose `_meta` carries a `progressToken` or a
`logLevel` may be answered as a Server-Sent Events stream, if the client's
`Accept` includes `text/event-stream`. The stream carries
`notifications/progress` and `notifications/message` before the result,
with `:\r\n` keep-alive comments in between.

```elixir
tool "import", "Import rows" do
  param :rows, :array, "Rows", required: true do
    items :string
  end

  handle fn conn, %{"rows" => rows} ->
    total = length(rows)

    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {row, done}, :ok ->
      if ConduitMcp.Cancellation.cancelled?(conn) do
        {:halt, :cancelled}
      else
        MyApp.Importer.import_row(row)
        ConduitMcp.Progress.report(conn, done, total: total, message: "row #{done}")
        {:cont, :ok}
      end
    end)
    |> case do
      :ok ->
        ConduitMcp.Log.log(conn, :info, %{"imported" => total}, logger: "import")
        text("imported #{total} rows")

      :cancelled ->
        error("Cancelled", ConduitMcp.Errors.request_cancelled())
    end
  end
end
```

- `ConduitMcp.Progress.report/3` takes the options `:total` and `:message`.
- `ConduitMcp.Log.log/4` takes a level as an atom or a string, any
  JSON-encodable `data`, and the option `:logger`. It sends only when the
  level is at least the requested `logLevel`. The client receives `data`
  as it is, so never log secrets.
- Both return `:ok` and send nothing when there is no stream to send on:
  no `progressToken` (or no `logLevel`), a legacy request, a client that
  didn't accept `text/event-stream`, or a call made through
  `ConduitMcp.Handler.handle_request/3`. Tools can call them
  unconditionally.

How the stream behaves:

- **The tool runs in a linked task.** The request process relays its
  notifications.
- **The stream opens late.** It opens on the first notification or
  keep-alive tick. A result that arrives first goes out as plain JSON.
- **At the cap.** Once `:max_streams` is reached, a response that would
  open a stream is sent as plain JSON instead, without its notifications.
  The client is never refused.
- **Disconnect is cancellation.** The modern HTTP transport has no
  `notifications/cancelled`; a client cancels by closing the stream. When
  a write fails, the request is marked cancelled and
  `ConduitMcp.Cancellation.cancelled?/1` turns `true` for the tool. A tool
  that hasn't returned within `:stream_cancel_timeout` is killed.
- **A raising tool** produces a `-32603` error event, then the stream
  closes.

| Transport option | Default | Meaning |
|---|---|---|
| `:keep_alive_interval` | `15_000` | ms between `:\r\n` keep-alive comments |
| `:max_streams` | `1_000` | concurrent streams, including `subscriptions/listen` |
| `:max_stream_lifetime` | 1 hour | after this, the request is cancelled; the response is `-32603` unless the tool returns within `:stream_cancel_timeout` |
| `:stream_cancel_timeout` | `5_000` | ms a cancelled tool gets to return before it is killed |

These options must be positive integers, or `init/1` raises
`ArgumentError`.

## What the modern era leaves out

| Legacy | Modern |
|---|---|
| `initialize` / `notifications/initialized` | none; `server/discover` if the client wants it |
| `ping` | none (`-32601`, HTTP 404) |
| `logging/setLevel` | per-request `logLevel` |
| `resources/subscribe` / `unsubscribe` | `subscriptions/listen` ([Subscriptions](subscriptions.md)) |
| `Mcp-Session-Id` sessions | none; never minted, required or looked up |
| `notifications/cancelled` | closing the response stream; every modern notification is dropped |
| Server-to-client sampling, elicitation, roots | `input_required` results ([MRTR](mrtr.md)) |
| `tasks/result`, `tasks/list` (`ConduitMcp.Tasks`) | the tasks extension ([Tasks Extension](tasks_extension.md)) |

The modern routing table has `server/discover`, `tools/list`, `tools/call`,
`resources/list`, `resources/templates/list`, `resources/read`,
`prompts/list`, `prompts/get`, `completion/complete` and
`subscriptions/listen`. `tasks/get`, `tasks/update` and `tasks/cancel` are
added while the tasks extension is enabled. Every other method returns
`-32601`.

### GET and DELETE

`GET` and `DELETE` carry no `_meta`, so they keep their legacy behaviour:

- **`GET /` with `Accept: text/event-stream`** returns 405 with an `allow`
  header, because this server offers no standalone server-to-client stream.
  Any other `GET /` returns a JSON info document.
- **`DELETE /`** ends the legacy session named by `Mcp-Session-Id` (200).
  An unknown id is 404 and a missing one is 400. With sessions off it is
  405.

The legacy `ConduitMcp.Transport.SSE` answers modern requests on
`POST /message`, but `GET /sse` is legacy-only. Point modern clients at
`ConduitMcp.Transport.StreamableHTTP`.

## Error codes

| Code | Function | Meaning |
|---|---|---|
| `-32700` | `Errors.parse_error/0` | Invalid JSON |
| `-32600` | `Errors.invalid_request/0` | Not a valid request; also a session bound to another principal, an unsupported legacy `MCP-Protocol-Version` header (400), and a listen without `text/event-stream` (406) |
| `-32601` | `Errors.method_not_found/0` | Unknown method; HTTP 404 on the modern era |
| `-32602` | `Errors.invalid_params/0` | Invalid params; also invalid modern `_meta` (400), an invalid `requestState`, and a missing resource on the modern era |
| `-32603` | `Errors.internal_error/0` | Internal error |
| `-32000` | `Errors.server_error/0` | Generic server error; also insufficient scope and the listen 429/503 bodies |
| `-32002` | `Protocol.Legacy.resource_not_found/0` | Resource not found, legacy era only |
| `-32004` | `Errors.task_not_ready/0` | Legacy `tasks/result` before the task finished |
| `-32020` | `Errors.header_mismatch/0` | A header is missing, duplicated, malformed or disagrees with the body (400) |
| `-32021` | `Errors.missing_required_client_capability/0` | The request needs a client capability it didn't declare; `data.requiredCapabilities` (400) |
| `-32022` | `Errors.unsupported_protocol_version/0` | Modern `_meta` version not implemented; `data.supported`, `data.requested` (400) |
| `-32800` | `Errors.request_cancelled/0` | Request cancelled |

`Errors.modern_task_not_ready/0` (`-31004`) is the modern counterpart of
`-32004`.

### Resource not found

The two eras use different codes for a missing resource. `2025-11-25` and
earlier use `-32002`, and `2026-07-28` forbids `-32002` and uses `-32602`.
Callbacks don't need to know which era they're serving. Keep returning the
legacy code:

```elixir
def handle_read_resource(_conn, uri) do
  {:error,
   %{"code" => ConduitMcp.Protocol.Legacy.resource_not_found(),
     "message" => "Resource not found: #{uri}"}}
end
```

`ConduitMcp.Protocol.Modern` rewrites `-32002` to `-32602` on every modern
response, so a legacy client sees `-32002` and a modern client sees
`-32602`. `ConduitMcp.Protocol.Modern.resource_not_found/0` returns
`-32602`.

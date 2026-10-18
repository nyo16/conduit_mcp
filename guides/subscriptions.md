# Subscriptions

On MCP `2026-07-28`, change notifications have one delivery path. The client
opens a long-lived `subscriptions/listen` stream that says what it wants to
hear about, and the server pushes to it. Without sessions, there is no other
channel a notification could travel on.

Every modern server answers `subscriptions/listen`; there is nothing to
enable. Your code only has to say when something changed:

```elixir
ConduitMcp.notify_tools_changed()
ConduitMcp.notify_prompts_changed()
ConduitMcp.notify_resources_changed()
ConduitMcp.notify_resource_updated("file:///project/config.json")
```

Each returns `:ok` and reaches the matching streams **on the local node**
(see [Multi-node](#multi-node)). A server that never calls them simply sends
nothing.

## The request

```http
POST / HTTP/1.1
Content-Type: application/json
Accept: text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: subscriptions/listen

{"jsonrpc": "2.0", "id": 7, "method": "subscriptions/listen",
 "params": {
   "notifications": {
     "toolsListChanged": true,
     "resourceSubscriptions": ["file:///project/config.json"]
   },
   "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
             "io.modelcontextprotocol/clientCapabilities": {}}}}
```

`Accept` must include `text/event-stream`. A listen has no JSON form, so
without it the request is answered with HTTP 406 and `-32600`.

## The filter

| Field | Value | Delivers | Honoured when |
|---|---|---|---|
| `toolsListChanged` | boolean | `notifications/tools/list_changed` | the server advertises `tools` |
| `promptsListChanged` | boolean | `notifications/prompts/list_changed` | the server advertises `prompts` |
| `resourcesListChanged` | boolean | `notifications/resources/list_changed` | the server advertises `resources` |
| `resourceSubscriptions` | up to 1 000 URIs | `notifications/resources/updated` | the server advertises `resources` |
| `taskIds` | up to 1 000 task ids | `notifications/tasks` | `ConduitMcp.Ext.Tasks` is enabled ([Tasks Extension](tasks_extension.md#status-notifications)) |

- `false`, or a field the server doesn't honour, subscribes to nothing and
  is left out of the acknowledgment. For example, an Endpoint without
  prompts omits `promptsListChanged`.
- Unknown fields, such as a newer revision's or an extension's this server
  doesn't enable, are ignored and left out of the acknowledgment.
- A field of the wrong type, a `notifications` value that isn't an object,
  or more than 1 000 URIs or task ids is `-32602`. It comes back as a plain
  JSON-RPC error, and no stream is opened.

### Resource subscriptions

- **Exact match.** A resource topic matches its URI exactly:
  `notify_resource_updated("file:///a/b")` does not reach a stream
  subscribed to `"file:///a"`.
- **Authorized when the stream opens.** Each URI is checked against the
  resource's `scope`, the same check `resources/read` uses. A URI the caller
  may not read is dropped from the acknowledgment silently, exactly as if it
  had not been requested. The acknowledgment never reveals more than the
  caller could read.
- **Deduplicated.** Duplicate URIs are collapsed. If no URI survives, the
  field is left out of the acknowledgment.

## On the wire

The response is a Server-Sent Events stream. Each frame is one `message`
event carrying one JSON-RPC message.

1. **Acknowledgment first.** `notifications/subscriptions/acknowledged`
   lists only the fields honoured, each with the value honoured.
2. **Notifications** as the server publishes them, with `:\r\n` keep-alive
   comments in between.
3. **Every message is tagged.** Each one carries
   `_meta["io.modelcontextprotocol/subscriptionId"]`, set to the listen
   request's id.

```
event: message
data: {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["file:///project/config.json"]},"_meta":{"io.modelcontextprotocol/subscriptionId":7}}}

:

event: message
data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///project/config.json","_meta":{"io.modelcontextprotocol/subscriptionId":7}}}
```

The stream registers its topics before it sends the acknowledgment, so
nothing published after the acknowledgment is missed.

## How a stream ends

| Who ends it | Why | What is sent |
|---|---|---|
| Client | disconnects | nothing |
| Server | `:max_stream_lifetime` reached | `notifications/cancelled` for the listen id, then the closing result |
| Server | the OAuth bearer token's `exp` passed, if that comes before the lifetime | the same |
| Server | `:listen_idle_timeout` with no notification delivered | the same |
| Server | a newer listen of the same principal arrived at `:max_listens_per_principal`; this stream is that principal's oldest | the same |

On a server-side close, the order is fixed: first `notifications/cancelled`
(with `requestId` set to the listen id and a `reason`), then the
`subscriptions/listen` result (`resultType: "complete"`, tagged with the
`subscriptionId`), and then the stream ends. Clients reconnect with a new
listen.

A stream never outlives the credential that opened it. Only OAuth tokens
carry an `exp`; for other strategies the lifetime cap applies. Keep-alives
don't count as activity for the idle timeout. The idle timeout is checked on
each keep-alive tick, so it can fire up to `:keep_alive_interval` late.

When a stream's process ends, it removes its registry entries and its
stream slot. A process that is killed leaks neither.

## Limits

| Transport option | Default | Over the limit |
|---|---|---|
| `:max_listens_per_principal` | `4` | admitted; the principal's **oldest** stream is ended gracefully (reason `:superseded`) |
| `:max_streams` | `1_000` | HTTP **503**, JSON-RPC `-32000`, no stream |
| `:listen_idle_timeout` | 30 minutes | graceful close |
| `:max_stream_lifetime` | 1 hour | graceful close |
| `:keep_alive_interval` | `15_000` ms | — |

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        max_listens_per_principal: 2,
        listen_idle_timeout: :timer.minutes(10)},
 port: 4001}
```

- **Per-principal cap.** The principal is
  `ConduitMcp.Principal.rate_limit_key/1`: the authenticated id, otherwise
  the client's address bucket. This cap is always on and needs no Hammer
  backend. It is never answered 429: a client's dead streams are only noticed
  on their next write, so a client that opens a listen per run would lock
  itself out. Instead the new listen is admitted and the principal's oldest
  stream gets `notifications/cancelled`, then the closing result, then
  closes. Admission is serialized per principal, so even a burst never holds
  more than the cap live; another principal's streams are never touched.
- **Server-wide cap.** `:max_streams` is shared with streamed `tools/call`
  responses. A full server is a capacity problem, not something the client
  did, so it is answered 503 (and supersedes nothing).

These options must be positive integers, or `init/1` raises
`ArgumentError`. See [Rate Limiting](rate_limiting.md#listen-streams)
for how these caps relate to the Hammer limiters.

## Where listen is not served

- **Legacy era.** `subscriptions/listen` is not in the legacy routing table,
  so a legacy request gets `-32601`.
- **`ConduitMcp.Handler.handle_request/3`.** A map-returning call can't hold
  a stream open, so it answers `-32601` ("requires a streaming transport").
  Only the HTTP transports serve listen; the client's
  `ConduitMcp.Client.Transport.InProcess` answers it `-32601` too.
- **`GET /sse`** on the legacy SSE transport. Modern clients should use
  `ConduitMcp.Transport.StreamableHTTP`.

## Capabilities

On the modern era, `server/discover` sets `listChanged: true` on each of
`tools`, `prompts` and `resources` that the server advertises, and
`subscribe: true` on `resources`. Legacy `initialize` capabilities don't
change: there is no legacy delivery path for list-changed notifications, and
legacy `resources.subscribe` is advertised only when the server defines
`handle_subscribe_resource/2`.

## Telemetry

A listen whose stream opened emits these events instead of
`[:conduit_mcp, :request, :stop]`, because its duration is a lifetime, not
a latency. A listen refused with 406 or 503 emits neither.

| Event | Measurements | Metadata |
|---|---|---|
| `[:conduit_mcp, :subscription, :start]` | `system_time`, `resource_subscriptions` (count) | `filters`, `server_module` |
| `[:conduit_mcp, :subscription, :stop]` | `duration` (native units) | `filters`, `server_module`, `reason` (`:client_closed`, `:max_lifetime`, `:token_expired`, `:idle_timeout`, `:superseded`) |

`filters` is a list of atoms: `:tools_list_changed`,
`:prompts_list_changed`, `:resources_list_changed`,
`:resource_subscriptions` and `:task_ids`. `reason` is `:client_closed`,
`:max_lifetime`, `:token_expired` or `:idle_timeout`. The events never
include URIs, ids or principals.

## Multi-node

The registry behind the streams, `ConduitMcp.Subscriptions`, is node-local:
a notification reaches only the streams served by the node that published
it. On a cluster, broadcast the change on your own PubSub and call
`ConduitMcp.notify_*` on every node:

```elixir
# wherever the change happens
Phoenix.PubSub.broadcast(MyApp.PubSub, "mcp", {:resource_updated, uri})

# a process subscribed to "mcp" on every node
defmodule MyApp.McpRelay do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok = Phoenix.PubSub.subscribe(MyApp.PubSub, "mcp")
    {:ok, nil}
  end

  @impl true
  def handle_info(:tools_changed, state) do
    ConduitMcp.notify_tools_changed()
    {:noreply, state}
  end

  def handle_info({:resource_updated, uri}, state) do
    ConduitMcp.notify_resource_updated(uri)
    {:noreply, state}
  end
end
```

`Phoenix.PubSub.broadcast/3` also delivers to the local node, so publish
only through PubSub. Don't also call `notify_*` directly, or local streams
get the notification twice.

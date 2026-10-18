# MCP Client

`ConduitMcp.Client` connects to one MCP server and speaks whichever protocol
era it supports: modern (`2026-07-28`) or legacy (`2025-11-25`,
`2025-06-18`). One client is one supervised connection to one server. To put
many servers behind one tool list, see the Hub guide
([client_hub.md](client_hub.md)).

```elixir
children = [
  {ConduitMcp.Client,
   name: MyApp.Files,
   transport:
     {ConduitMcp.Client.Transport.Stdio,
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"]}}
]

Supervisor.start_link(children, strategy: :one_for_one)

:ok = ConduitMcp.Client.await_ready(MyApp.Files, 10_000)
{:ok, tools} = ConduitMcp.Client.list_all_tools(MyApp.Files)
{:ok, result} = ConduitMcp.Client.call_tool(MyApp.Files, "read_file", %{"path" => "/srv/data/a.txt"})
```

The rest of this guide covers starting a client, eras, requests and results,
server input (sampling, elicitation, roots), notifications, tasks,
reconnects, caching, the three transports, testing and telemetry. Governing
calls (policy, hooks, approvals) is covered in
[client_permissions_and_hooks.md](client_permissions_and_hooks.md), handing
tools to a model in [client_llm_adapters.md](client_llm_adapters.md), and
the threat model in [client_security.md](client_security.md). OAuth is
covered in [client_oauth.md](client_oauth.md).

## Starting a client

Add `{ConduitMcp.Client, opts}` to your own supervision tree. The
application starts no clients; it only runs the registry they register in.

```elixir
{ConduitMcp.Client,
 name: {MyApp.GitHub, tenant_id},
 server_id: "github",
 transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/mcp"},
 handler: MyApp.MCPHandler}
```

- `:name` is required and may be **any term**. It is a key in
  `ConduitMcp.Client.Registry`, never an atom-registered name, so
  `{MyApp.GitHub, tenant_id}` works and no atom is created. Every
  `ConduitMcp.Client` function takes it. The child id is
  `{ConduitMcp.Client, name}`, so one supervisor can hold many clients.
- `:server_id` is the operator-assigned id stamped on every `Tool`,
  `Resource` and `Prompt` the client returns. It defaults to `:name` when that
  is a string, else `inspect(name)`.
- Options are validated when the child spec is built
  (`ConduitMcp.Client.Config`), so a typo raises an `ArgumentError` naming the
  key at boot, never at the first request.

Starting never blocks on the server. The connection is set up in the
background, and requests made before it is ready wait for it within their
own timeout. When you need the handshake to be done first:

```elixir
:ok = ConduitMcp.Client.await_ready(MyApp.Files, 5_000)
# {:error, %ConduitMcp.Client.Error{kind: :timeout}} after the timeout,
# or the :closed error at once if the connection gave up

{:ok, %{state: :ready, era: :modern, version: "2026-07-28", reason: nil}} =
  ConduitMcp.Client.status(MyApp.Files)

{:ok, :modern} = ConduitMcp.Client.era(MyApp.Files)
```

`status/1` and `era/1` read the client's cache table and never message the
connection. The states are `:connecting`, `:discovering`, `:initializing`,
`:ready`, `:reconnecting` and `:closed`. `era/1` keeps answering while the
client reconnects. Before the first handshake it returns
`{:error, %Error{kind: :unavailable}}`.

Other control functions:

| Function | Does |
|---|---|
| `server_info/1` | What the server reported in the handshake: its `ServerInfo`, capabilities and instructions, with the era and version (`kind: :unavailable, reason: :not_ready` until ready) |
| `instructions_for_llm/1` | The server's `instructions`, prepared for a model's context. `{:ok, nil}` unless the client has `include_instructions: true` (see [client_security.md](client_security.md)) |
| `close/1` | Fails pending requests with `kind: :closed` and stays `:closed` until `reconnect/1` |
| `reconnect/1` | Drops the connection (pending requests fail with `kind: :transport`) and connects again at once. Also revives a `:closed` client |
| `set_auth/3` | Replaces the credentials (any `:auth` form) and reconnects; private cached results of other credentials are dropped (see "Private results and credentials") |

## Protocol negotiation

```elixir
{ConduitMcp.Client, name: :docs, transport: transport, protocol: :auto}
```

| `protocol:` | Behaviour |
|---|---|
| `:auto` (default) | Probe `server/discover`. Fall back to `initialize` only on legacy evidence |
| `:modern` | `server/discover` without probing. Legacy evidence closes the connection; it never falls back |
| `:legacy` | Straight to `initialize` |
| `"2026-07-28"`, `"2025-11-25"`, `"2025-06-18"` | Pin that exact version (the era follows from it) |

What counts as legacy evidence depends on the transport's kind
(`ConduitMcp.Client.Negotiation.classify_probe/3`):

| Transport | Outcome of the probe | Verdict |
|---|---|---|
| any | a valid `DiscoverResult` with a mutual modern version | modern |
| any | `-32022` with a mutual version in `data.supported` | discover once more with that version (never a fallback) |
| any | `-32022` without one, `-32021`, `-32020`, or an invalid `DiscoverResult` | error, connection closes |
| any | a result that is not `DiscoverResult`-shaped | legacy |
| stdio, in-process | any other JSON-RPC error, or a timeout | legacy |
| stdio, in-process | the server exits during the probe | reconnect, and start the next attempt with `initialize` |
| HTTP | 401 / 403 | the connection closes with an `:auth` error |
| HTTP | 408 / 429 / 5xx, a network error, a timeout | reconnect and probe again; never a downgrade |
| HTTP | 400 / 404 / 405 with a non-modern body, or any status with `-32601` | legacy |

- `:probe_timeout` bounds the probe. It defaults to 5 000 ms for HTTP and
  3 000 ms otherwise.
- `prior: :legacy` (for example an era you cached from `era/1`) skips the
  probe once and starts with `initialize`. If that is refused, the next
  attempt probes again. `prior: :modern` changes nothing.
- Once a connection has negotiated modern, later handshakes never fall back
  to legacy. A ready modern connection that receives `-32022` re-discovers,
  and the request that got it is retried once.

The functions below work in both eras, with three exceptions. `ping/2`
sends `server/discover` to a modern server. `set_log_level/2` is a request
in legacy and a per-request `_meta` value in modern. `notify_roots_changed/1`
works in the legacy era only.

## Making requests

Every request function runs in the calling process and returns
`{:ok, value}` or `{:error, %ConduitMcp.Client.Error{}}`.

```elixir
:ok = ConduitMcp.Client.ping(:docs, timeout: 1_000)

{:ok, %{tools: tools, next_cursor: cursor}} = ConduitMcp.Client.list_tools(:docs)
{:ok, %{tools: more}} = ConduitMcp.Client.list_tools(:docs, cursor: cursor)

{:ok, %ConduitMcp.Client.ToolResult{content: [%{"text" => "hi"}]}} =
  ConduitMcp.Client.call_tool(:docs, "echo", %{"message" => "hi"})

{:ok, %{"contents" => contents}} = ConduitMcp.Client.read_resource(:docs, "file:///notes.md")
{:ok, %{"messages" => messages}} = ConduitMcp.Client.get_prompt(:docs, "greeting", %{name: "Ada"})

{:ok, %{"completion" => %{"values" => values}}} =
  ConduitMcp.Client.complete(:docs, {:prompt, "greeting"}, {"name", "A"})

:ok = ConduitMcp.Client.set_log_level(:docs, :warning)
```

| Function | Returns |
|---|---|
| `list_tools/2`, `list_resources/2`, `list_resource_templates/2`, `list_prompts/2` | one page: `%{tools: [...], next_cursor: cursor \| nil}` (and `resources:`, `resource_templates:`, `prompts:`) |
| `list_all_tools/2`, `list_all_resources/2`, `list_all_resource_templates/2`, `list_all_prompts/2` | every page, through the cache (see "Caching") |
| `cached_tools/2`, `tool/3` | the cached list, or one cached tool, without asking the server |
| `call_tool/4` | `%ConduitMcp.Client.ToolResult{}` (or a `%ConduitMcp.Client.Task{}`, see "Tasks") |
| `async_call_tool/4` | a `Task` running `call_tool/4` under the client's `Task.Supervisor`; a crash in it does not take the caller down |
| `read_resource/3` | the server's `ReadResourceResult` map |
| `get_prompt/4` | the server's `GetPromptResult` map. Arguments are converted to strings; `nil` values are dropped |
| `complete/4` | the server's `CompleteResult` map. `ref` is `{:prompt, name}`, `{:resource, uri_template}` or a wire map. Takes `:context` |
| `ping/2`, `set_log_level/2` | `:ok` |

`call_tool/4` sends `args` as given (string or atom keys). Tools that fail
intake never appear in listings: a name outside `[A-Za-z0-9_.-]` (1-128
characters), a malformed definition, a repeated name, or (over HTTP) invalid
`x-mcp-header` annotations. Each dropped tool logs a warning and emits
`[:conduit_mcp, :client, :tool, :rejected]`.

### Request options

Every request function accepts these options:

| Option | Meaning |
|---|---|
| `:timeout` | Milliseconds before the request is cancelled. Default: the client's `:request_timeout` (60 000) |
| `:on_progress` | A one-arity function, or a pid sent `{:mcp_progress, name, params}`, for `notifications/progress`. It runs in the caller |
| `:reset_timeout_on_progress` | `true` restarts `:timeout` on each progress notification, capped by `:max_total_timeout` |
| `:max_total_timeout` | The ceiling for the above. It also caps a deadline paused while the handler answers a legacy server request tied to the call. Default: the client's `:max_total_timeout` (300 000) |
| `:meta` | A map merged into the request's `_meta`. Reserved keys (`progressToken`, `io.modelcontextprotocol/*`) are dropped |
| `:assigns` | A map given to the `ConduitMcp.Client.Handler` callbacks as `ctx.assigns` for input requests made for this call. Default: the client's `:assigns` |
| `:traceparent` | The W3C trace context sent in a modern request's `_meta`. Default: the caller's `Logger.metadata()[:traceparent]`. Dropped unless well formed; a `traceparent` in `:meta` wins. `tracestate` and `baggage` are never propagated |

```elixir
ConduitMcp.Client.call_tool(:docs, "index_repo", %{"repo" => "a/b"},
  timeout: 30_000,
  on_progress: fn %{"progress" => done} = params -> IO.inspect({done, params["total"]}) end,
  reset_timeout_on_progress: true,
  max_total_timeout: 600_000,
  assigns: %{user_id: user.id}
)
```

When the deadline passes, the connection cancels the request on the wire and
answers `kind: :timeout`. If the calling process dies, the request is
cancelled too. Cancellation is per transport: stdio writes
`notifications/cancelled`, modern HTTP closes the response stream, legacy
HTTP POSTs `notifications/cancelled` and then closes the stream. Nothing that
may have run is retried on its own. On a reconnect, every pending request
fails with `kind: :transport`.

Limits on the connection: at most `:max_in_flight` (64) requests sent and
unanswered, and `:max_queued` (128) waiting for the connection to be ready.
One more fails at once with `kind: :overloaded`.

## Results and errors

A tool that ran and reported failure is **not** an error:

```elixir
case ConduitMcp.Client.call_tool(:docs, "deploy", args) do
  {:ok, %ConduitMcp.Client.ToolResult{is_error: false, content: content, structured: data}} ->
    {:ok, content, data}

  {:ok, %ConduitMcp.Client.ToolResult{is_error: true, content: content}} ->
    {:tool_failed, content}

  {:error, %ConduitMcp.Client.Error{kind: :timeout}} ->
    :retry_later

  {:error, %ConduitMcp.Client.Error{} = error} ->
    {:error, Exception.message(error)}
end
```

`%ToolResult{}` has `content` (the string-keyed blocks as sent),
`structured` (`structuredContent` or `nil`), `is_error`, `meta` (the
result's `_meta`), `extra` (every other wire key) and `provenance` (set only
for results shaped with `shape: :llm`).

`%ConduitMcp.Client.Error{}` has `kind`, `reason` (a short machine-readable
detail, such as `{:jsonrpc, -32602}`) and `data` (optional context; may hold
server content, so `Exception.message/1` never renders it). Match on `kind`:

| `kind` | Meaning |
|---|---|
| `:timeout` | The request deadline passed |
| `:transport` | The transport failed (connection refused, bad HTTP status, a redirect) |
| `:protocol` | The peer broke the protocol, or answered with a JSON-RPC error |
| `:denied` | The policy, an approver or a hook refused the call |
| `:not_found` | The tool, resource or prompt is hidden or unknown |
| `:hook` | A pre- or post-hook failed (fail closed) |
| `:unavailable` | The connection or its cache is gone |
| `:closed` | The client was closed |
| `:overloaded` | In-flight or queue limits were reached |
| `:input_handler` | A `ConduitMcp.Client.Handler` callback failed during a multi-round-trip call |
| `:auth` | Authorization is required or failed (HTTP 401/403) |
| `:rate_limited` | The server (HTTP 429) or a local limiter rejected the request |
| `:session_expired` | A legacy session ended and could not be renewed |
| `:mrtr_round_limit` | A multi-round-trip loop hit a round, input or state cap |
| `:pagination_cycle` | A list cursor repeated, or a pagination cap was hit |
| `:message_too_large` | A message exceeded the configured byte cap |
| `:connection_down` | The connection process exited mid-request |

`Exception.message/1` renders only the kind and the reason, with binary
reasons truncated and secrets redacted, so it is safe to log.

## Answering server input: `ConduitMcp.Client.Handler`

Servers can ask the client for input: sampling (an LLM completion),
elicitation (a question for the user) and roots (the directories it may use).
The client advertises only what its `:handler` module implements:

| Callback | Advertises |
|---|---|
| `handle_sampling/2` | `sampling` |
| `handle_elicitation/2` | `elicitation`, with the modes from `elicitation_modes/0` (default `[:form]`) |
| `list_roots/1` | `roots` |

Without a handler, or with none of these callbacks, `clientCapabilities` is
`{}`. An input request for a capability the client did not declare is
refused before any callback runs.

```elixir
defmodule MyApp.MCPHandler do
  @behaviour ConduitMcp.Client.Handler

  @impl true
  def handle_sampling(%{"messages" => messages, "maxTokens" => max_tokens}, ctx) do
    # This callback is the approval point: show the request to the user first.
    with :ok <- MyApp.Approvals.sampling(ctx.assigns, ctx.server_id, messages),
         {:ok, text} <- MyApp.LLM.complete(messages, max_tokens) do
      {:ok,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => text},
         "model" => "my-model",
         "stopReason" => "endTurn"
       }}
    else
      _ -> {:error, %{"code" => -1, "message" => "User rejected sampling request"}}
    end
  end

  @impl true
  def elicitation_modes, do: [:form, :url]

  @impl true
  def handle_elicitation(%{"message" => message} = params, %{mode: :form} = ctx) do
    case MyApp.UI.ask(ctx.assigns.user_id, message, params["requestedSchema"], ctx.fields) do
      {:ok, answers} -> {:ok, %{"action" => "accept", "content" => answers}}
      :declined -> {:ok, %{"action" => "decline"}}
    end
  end

  def handle_elicitation(_params, %{mode: :url, url: url, host: host} = ctx) do
    # The client never opens the URL. Show it, with the warnings, and let the user decide.
    warn? = ctx.idn? or ctx.origin_mismatch?
    MyApp.UI.offer_link(ctx.assigns.user_id, url, host, warn?)
    {:ok, %{"action" => "accept"}}
  end

  @impl true
  def list_roots(_ctx), do: {:ok, %{"roots" => [%{"uri" => "file:///srv/data", "name" => "data"}]}}

  @impl true
  def handle_notification(method, _params, ctx), do: MyApp.Events.mcp(ctx.server_id, method)

  @impl true
  def handle_log(level, params, ctx), do: MyApp.Events.mcp_log(ctx.server_id, level, params)
end
```

All callbacks are optional. They return string-keyed maps shaped like the
spec's result types. A legacy request can be refused with
`{:error, %{"code" => integer, "message" => binary}}`. A user who declines an
elicitation is a result, not an error: `{:ok, %{"action" => "decline"}}`.

Every callback receives a `ctx` map:

| Key | Value |
|---|---|
| `:client` | The client's `:name` |
| `:server_id` | The operator-assigned id of the asking server |
| `:era` | `:modern` or `:legacy` |
| `:assigns` | The related call's `:assigns`, or the client's `:assigns` |
| `:related_request_id` | The in-flight request this input belongs to, or `nil` (always `nil` in modern) |
| `:mode` | Elicitation only: `:form` or `:url` |
| `:fields` | Form elicitation: `%{name => %{sensitive_suspected: boolean}}`, flagging secret-looking fields |
| `:url`, `:host`, `:idn?`, `:origin_mismatch?` | URL elicitation (see below) |

`handle_notification/3` and `handle_log/3` get only `:client`, `:server_id`
and `:era`. They run in a process of their own, one notification at a time.
A raise is logged and skipped, and beyond 1 000 waiting notifications new
ones are dropped.

### How it runs in each era

- **Modern**: there are no server-to-client requests. A `tools/call`,
  `resources/read` or `prompts/get` may return `resultType: "input_required"`.
  The client then calls your handler **in the calling process** for each
  input request and retries the original request with the answers. This
  multi-round-trip (MRTR) loop is automatic. A callback that raises or
  returns `{:error, _}` fails the call with `kind: :input_handler`. The loop
  is capped at 8 rounds, 16 input requests per round and a 64 KiB
  `requestState`, each giving `kind: :mrtr_round_limit`.
- **Legacy**: the server sends JSON-RPC requests. Each runs in a task under
  the client's `Task.Supervisor`, never in the connection. The task is killed
  after `:handler_timeout` (`[sampling: 60_000, elicitation: 300_000,
  roots: 60_000]`) and answered `-32603`. At most `:max_server_requests` (8)
  run at once; over that the server gets `-32000` (busy). A server
  `notifications/cancelled` kills the task. A request tied to an in-flight
  call pauses that call's deadline, bounded by its `:max_total_timeout`.

### Safety defaults

The same checks run in both eras, before and after your callback:

| Check | Default | Option |
|---|---|---|
| Input request budget per server | 10/s, bursts of 20 | `input_rate_limit: [per_second: _, burst: _]` |
| Sampling `maxTokens` | Must be a positive integer, clamped to 4 096 | `sampling: [max_tokens: _]` |
| Sampling `includeContext` | Coerced to `"none"` | `sampling: [context: true]` declares `sampling.context` and lets it through |
| Sampling tools | Not declared | `sampling: [tools: true]` |
| Legacy sampling with no call in flight | Refused | `sampling: [allow_idle: true]` |
| Sampling refusal code (idle, over budget) | `-1` | `sampling: [rejection_code: _]` |
| Elicitation mode not in `elicitation_modes/0` | Refused, `-32602` | |
| URL elicitation | The client never fetches or opens the URL. Only absolute `https` URLs without userinfo pass (`javascript:`, `http:`, `file:` get `-32602`). `idn?` is true for a punycode `xn--` label; `origin_mismatch?` is true unless the URL has the server's origin, and always true when that origin is unknown | `elicitation: [origin: "https://host"]` for transports that report no origin |
| Form elicitation schema | Must be the spec's flat primitive subset, else `-32602` | |
| Elicitation answers | `"action"` must be `accept`/`decline`/`cancel`; a form `accept` must fit the schema; a URL `accept` carries no content (else `-32603`) | |
| Roots | Asked per server. Only `file://` URIs on the local host are sent, with `.`/`..` resolved | `roots: [list_changed: true]` (default) declares `roots.listChanged` to legacy servers |

Announce changed roots to a legacy server with
`ConduitMcp.Client.notify_roots_changed/1`.

## Notifications and subscriptions

```elixir
:ok = ConduitMcp.Client.subscribe_notifications(:docs)

receive do
  {:mcp_notification, :docs, "notifications/tools/list_changed", _params} -> :refresh
  {:mcp_notification, :docs, "notifications/message", %{"level" => level}} -> level
end

:ok = ConduitMcp.Client.unsubscribe_notifications(:docs)
```

Every server notification except `notifications/progress` (which goes to
the request's caller) and `notifications/cancelled` is sent to each
subscriber as `{:mcp_notification, name, method, params}`, and to the
handler's `handle_notification/3` / `handle_log/3`. Subscribing is
idempotent and ends when the process exits.

Bursts of one `notifications/*/list_changed` kind are coalesced: the first is
delivered at once, and any more within the next 250 ms arrive as one trailing
notification. Each delivered `list_changed` marks the matching cached list
stale and, if it was ever fetched, refreshes it.

Server log entries (`notifications/message`) are limited per connection to
`log_rate_limit: [per_second: 50, burst: 100]`; the rest are dropped, each
emitting `[:conduit_mcp, :client, :log, :dropped]`. Delivered entries carry
only `level`, `logger` and `data`, with every string passed through
`ConduitMcp.Reflect.text/2` (no control, bidi or line-separator characters;
`data` strings clamped to 4 096 characters, nesting cut below 16 levels),
and a `level` outside the RFC 5424 set becomes `"info"`.

Subscribe to one resource's updates, in either era:

```elixir
:ok = ConduitMcp.Client.subscribe(:docs, "file:///notes.md")
# updates arrive to notification subscribers as
# {:mcp_notification, :docs, "notifications/resources/updated", %{"uri" => "file:///notes.md"}}
:ok = ConduitMcp.Client.unsubscribe(:docs, "file:///notes.md")
```

- **Legacy** sends `resources/subscribe`. The server must declare
  `resources.subscribe`, else `kind: :protocol`,
  `reason: :subscriptions_not_supported`.
- **Modern** servers send change notifications only on a
  `subscriptions/listen` stream. The client opens one itself once it has a
  consumer (a cached list, a notification subscriber, a handler taking
  notifications, or a resource subscription) for something the server
  advertises, with the union of those as its filter. A filter change opens a
  new listen and closes the old one once the new one is acknowledged. A listen
  that ends is reopened after the backoff. At most four listens exist at
  once. `subscribe/2` returns `:ok` once the acknowledgment covers `uri`,
  else `kind: :protocol`, `reason: :subscription_not_acknowledged`.

Subscriptions survive reconnects and session renewals: they are sent again
each time the connection becomes ready.

## Tasks

A long tool call can run as a server task: the modern
`io.modelcontextprotocol/tasks` extension, or a legacy task-augmented call.

```elixir
# Return the task at once if the server makes one
{:ok, %ConduitMcp.Client.Task{id: id, status: :working} = task} =
  ConduitMcp.Client.call_tool(:docs, "build", args, task: :return)

{:ok, %ConduitMcp.Client.Task{status: status}} = ConduitMcp.Client.get_task(:docs, task)
{:ok, %ConduitMcp.Client.ToolResult{}} = ConduitMcp.Client.await_task(:docs, task, timeout: 600_000)
:ok = ConduitMcp.Client.cancel_task(:docs, task)

# Or wait for the result transparently
{:ok, %ConduitMcp.Client.ToolResult{}} =
  ConduitMcp.Client.call_tool(:docs, "build", args, task: :await, timeout: 600_000)
```

- `task: :await` polls until the task finishes. `:timeout` bounds the whole
  wait; when it passes the task is cancelled (`tasks/cancel`), as it is if
  the caller dies.
- `await_task/3` polls at the task's `pollIntervalMs`, answers its input
  requests with your handler (modern) or reads `tasks/result` (legacy).
- `task_ttl: ms` sets the legacy `task.ttl` to request.
- Modern servers decide per call whether to create a task. The client
  declares the tasks extension only when `:task` is given.
- Legacy servers get a task-augmented call only when they declare
  `tasks.requests.tools.call` and the tool's `execution.taskSupport` allows
  it: `"required"` always (awaited when no `:task` is given), `"optional"`
  only with `:task`.
- `cancel_task/3` is cooperative: the task may still finish.

Task statuses are `:working`, `:input_required`, `:completed`, `:failed`,
`:cancelled` and `:unknown`. Task ids are bound to the credential that
created them and may act as bearer tokens: never log them.

## Reconnects

When the transport fails, the connection fails every pending request with
`kind: :transport` and reconnects.

| Option | Default | Meaning |
|---|---|---|
| `:backoff` | `&ConduitMcp.Client.Backoff.full_jitter/1` | `fn attempt -> ms end`. The default is a random delay between 1 ms and `min(30_000, 500 * 2 ** attempt)`. Runs in the connection process, so keep it pure and fast; one that raises or returns anything but a non-negative integer falls back to the default, with a warning |
| `:max_reconnects` | `:infinity` | Consecutive failed attempts before giving up |
| `:stable_after` | 30 000 | Milliseconds the connection must stay ready before the attempt count resets |
| `:on_give_up` | `:stay` | `:stay` keeps the client `:closed` (so `status/1` explains why and `reconnect/1` can retry); `:stop` exits so a supervisor restarts it |
| `:health_check_interval` | `nil` | When set, a ready connection pings the server this often (legacy `ping`, modern `server/discover`); two unanswered checks in a row restart the transport |

```elixir
{ConduitMcp.Client,
 name: :docs,
 transport: transport,
 backoff: &ConduitMcp.Client.Backoff.full_jitter(&1, base: 1_000, cap: 60_000),
 max_reconnects: 10,
 on_give_up: :stop,
 health_check_interval: 30_000}
```

## Caching

`list_all_tools/2` (and the resource, template and prompt variants) fetch
every page and keep the result in the client's `ConduitMcp.Client.Cache`, an
ETS table that callers read directly.

```elixir
{:ok, tools} = ConduitMcp.Client.list_all_tools(:docs)                 # served from cache while fresh
{:ok, tools} = ConduitMcp.Client.list_all_tools(:docs, refresh: true)  # ignore a fresh list
{:ok, tools} = ConduitMcp.Client.cached_tools(:docs)                   # never asks the server
{:ok, %ConduitMcp.Client.Tool{} = tool} = ConduitMcp.Client.tool(:docs, "echo")
```

- A list is fresh for the server's `ttlMs` hint (the minimum over its pages),
  clamped to `:max_cache_ttl` (default 1 hour). A missing, negative or
  non-integer `ttlMs` means 0, so by default a list is never fresh and
  `list_all_*` fetches again.
- One refresh runs at a time, shared by concurrent callers. A refresh the
  caller stopped waiting for still completes and fills the cache.
- Nothing polls on TTL. A list is refreshed when a caller asks after it
  expired, or when the server sends `list_changed`. It is marked stale when
  the connection is lost.
- Pagination is capped at 100 pages, 10 000 items and 1 KiB cursors; a
  repeated cursor or a cap gives `kind: :pagination_cycle` and nothing is
  cached.
- `cached_tools/2` returns `{:error, %Error{kind: :not_found, reason:
  :not_cached}}` before the first listing.
- Multi-round-trip interim results and retries are never cached.

### Private results and credentials

A server's `cacheScope: "private"` means an answer may differ per
credential; a missing `cacheScope` (every legacy result) counts as private,
and a list is public only when every page says `"public"`. A private list is
cached together with the identity of the credentials it was fetched with,
and served only while the client still sends those. When they change it is
deleted at once and fetched again under the new ones; public lists stay.

| `:auth` | Identity |
|---|---|
| none | none: private lists are cached as usual |
| `{:bearer, token}` | the SHA-256 of the token; a new token is a new identity |
| `{:oauth, opts}`, `{:client_credentials, opts}` | the `{principal, issuer, resource}` key the tokens are stored under, so refreshing the token keeps the cache and another `:principal` does not |
| a function, with `:credential_id` | the `:credential_id` you declare: whose tokens the function returns |
| a function, no `:credential_id` | unknown: the function runs before every request and may return anyone's token, so private results are **never** served from the cache. Every `list_all_*` asks the server, `cached_tools/2` and `tool/3` see no private list, a call fetches the tool list it needs, and a hub fetches the server's tools on every listing |

The identity is a digest, never a token. Change credentials at runtime with
`ConduitMcp.Client.set_auth/3`:

```elixir
:ok = ConduitMcp.Client.set_auth(:docs, {:bearer, new_token})
:ok = ConduitMcp.Client.set_auth(:docs, &MyApp.Tokens.fetch/1, credential_id: {:service, :reporting})
```

It takes any `:auth` form (OAuth options without `:store` keep the
client's store; change `:principal` to act for another user), reconnects
(requests in flight fail with `kind: :transport`, listen streams and a
legacy session close) and drops the private lists before it returns. It
lasts as long as the client process: a client restarted by its supervisor
uses its configured credentials again.

Grants and the approval baseline are per client, not per credential: to
serve several users, pass `principal:` on calls (grants are keyed by it) or
run one client per user, named like `{MyApp.GitHub, user_id}`.

## Streamable HTTP

```elixir
# mix.exs
{:finch, "~> 0.21"}
```

```elixir
{ConduitMcp.Client,
 name: :docs,
 transport:
   {ConduitMcp.Client.Transport.StreamableHTTP,
    url: "https://mcp.example.com/mcp",
    auth: {:bearer, ConduitMcp.Client.Secret.new(System.fetch_env!("DOCS_TOKEN"))},
    headers: [{"x-tenant", "acme"}],
    redirect: :same_origin}}
```

Without `:finch` the client raises `ConduitMcp.OptionalDependencyError` when
it starts.

| Option | Default | Meaning |
|---|---|---|
| `:url` | required | The MCP endpoint: an absolute `http`/`https` URL, no user info, no fragment |
| `:auth` | `nil` | `{:bearer, token}` (a string or a `ConduitMcp.Client.Secret`), or a one-arity function called before each request with `%{url: url, method: method}`, returning `{:ok, token}`, `{:ok, nil}` or `{:error, reason}` (the request fails with `kind: :auth`), or `{:oauth, opts}` / `{:client_credentials, opts}` ([client_oauth.md](client_oauth.md)). A token must be visible ASCII (0x21-0x7E): a static one raises, a function's fails the request with `kind: :auth, reason: :invalid_token`. Never sent over `http` to a non-loopback host: that configuration raises. Replace it at runtime with `ConduitMcp.Client.set_auth/3` |
| `:credential_id` | `nil` | With an `:auth` function only: any term naming whose tokens it returns, so private results are cached for that identity (see "Private results and credentials"). Without it they are never served from the cache |
| `:headers` | `[]` | Extra `{name, value}` headers; a value may be a `Secret`, and must be visible ASCII, space and tab. Headers the transport owns (`accept`, `authorization`, `content-type`, `mcp-*`, `last-event-id`, hop-by-hop) are refused |
| `:finch` | `nil` | The name of a `Finch` pool you started |
| `:pool_size` | 100 | Connections in the library-started pool. Each open event stream holds one |
| `:transport_opts` | `[]` | TLS options for the library-started pool, and with `:public_only` for the pinned pools (Mint `:transport_opts`, for example `cacertfile:`). Any `verify:` other than `:verify_peer`, and `verify_fun:`, are refused |
| `:insecure_skip_tls_verify` | `false` | Skip certificate verification. **Local development only**: a warning is logged whenever the transport starts. Refused with `server_url_policy: :public_only` |
| `:redirect` | `false` | `false` refuses every redirect. `:same_origin` follows 307/308 to the same scheme, host and port (at most 5) |
| `:max_message_bytes` | 8 MiB | The largest JSON body or event-stream event. More fails with `kind: :message_too_large` |
| `:request_timeout` | 60 000 | Total time of a request the connection sends itself (handshake, health check) |
| `:listen_idle_timeout` | 120 000 | How long a long-lived stream may stay silent (keep-alives count) before it is dropped and reopened |
| `:server_url_policy` | `:any` | `:public_only` checks the URL with `ConduitMcp.Client.URLPolicy` before every request and connects to the vetted address, so DNS rebinding cannot redirect it (see [client_security.md](client_security.md)) |
| `:allow_private` | `[]` | CIDRs that `:public_only` admits anyway |
| `:resolver` | `nil` | The DNS resolver `:public_only` uses (`fn host -> {:ok, [ip]} end`), called in the request's process; default the system resolver |

**The pool.** By default each client starts its own Finch pool under its
supervisor, stopped with it. That pool is named by an atom derived from a
hash of the client's `:name`, so every distinct client name creates one
atom. When you start many clients with dynamic names (one per user), start
one Finch yourself and pass `finch:`:

```elixir
children = [
  {Finch, name: MyApp.MCPFinch},
  {DynamicSupervisor, name: MyApp.MCPClients}
]

DynamicSupervisor.start_child(MyApp.MCPClients,
  {ConduitMcp.Client,
   name: {MyApp.GitHub, user.id},
   transport:
     {ConduitMcp.Client.Transport.StreamableHTTP,
      url: "https://mcp.example.com/mcp",
      finch: MyApp.MCPFinch,
      auth: {:bearer, ConduitMcp.Client.Secret.new(token)}}}
)
```

`:pool_size`, `:transport_opts` and `:insecure_skip_tls_verify` apply only to
the library-started pool. Give that pool to no other code.

**Answers.**

| Server answer | Client result |
|---|---|
| 401, 403 | `kind: :auth`, `data: %{status: _, challenges: [...]}` |
| 429 | `kind: :rate_limited`, `data: %{retry_after: seconds \| nil}` |
| 4xx carrying a JSON-RPC error | that error, as `kind: :protocol` |
| legacy 404 to a request that carried a session id | the session expired: the client initializes a new session and sends that request once more, without failing the others |
| 5xx, a redirect, a network failure | `kind: :transport` |

Legacy session ids must be 1 to 1024 visible ASCII characters and are held
as a `Secret`. On close, a legacy session gets a `DELETE`. A legacy stream
that ends early after an event id is resumed with `Last-Event-ID` up to five
times; a modern stream that ends without a response fails the request and is
never replayed.

For OAuth-protected servers (`auth: {:oauth, ...}` and
`auth: {:client_credentials, ...}`), see [client_oauth.md](client_oauth.md).

## stdio

```elixir
{ConduitMcp.Client,
 name: :files,
 transport:
   {ConduitMcp.Client.Transport.Stdio,
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"],
    env: %{"GITHUB_TOKEN" => ConduitMcp.Client.Secret.new(System.fetch_env!("GITHUB_TOKEN"))},
    cd: "/srv",
    stderr: {:file, "/var/log/mcp-files.log"}}}
```

The server is spawned directly with `Port.open({:spawn_executable, path},
...)`, never through a shell. When it exits, the connection reconnects and
starts a new one (with the backoff and `:max_reconnects`). Requests in flight
fail and are not retried.

| Option | Default | Meaning |
|---|---|---|
| `:command` | required | An executable name looked up in `PATH`, or an absolute path. No whitespace: `"npx -y server"` raises |
| `:args` | `[]` | Passed as they are. No shell sees them |
| `:env` | `[]` | A map or `{name, value}` list; values may be `Secret`s. The server inherits only `HOME LOGNAME PATH SHELL TERM USER` (a Windows list on Windows) from this VM; `:env` wins |
| `:cd` | VM's working directory | An absolute path to an existing directory |
| `:stderr` | `:inherit` | `:inherit`, `:discard` or `{:file, absolute_path}` (appended). The last two are POSIX only. stderr is never merged into stdout or captured into `Logger` |
| `:allow_batch_files` | `false` | Allow a `.bat`/`.cmd` executable. On Windows, `npx` resolves to `npx.cmd`, so set this there; arguments containing `"%^&\|<>` are still refused |
| `:max_message_bytes` | 8 MiB | A longer line closes the transport (`:message_too_large`) and stops the server |
| `:max_junk_lines` | 10 | Consecutive non-JSON-RPC stdout lines tolerated; one more closes the transport (`:junk_output`) |
| `:stdin_grace` | 2 000 | Milliseconds the server gets to exit after stdin closes, before `SIGTERM` |
| `:term_grace` | 2 000 | Milliseconds after `SIGTERM` before `SIGKILL` |

Stdio configuration is **operator configuration**: whoever picks `:command`,
`:args` and `:env` runs code as this VM's user. Never build them from model
output, server responses or end-user input. The shutdown sequence and its
limits (launcher grandchildren, a killed port owner) are in
[client_security.md](client_security.md).

## Testing

`ConduitMcp.Client.Transport.InProcess` serves a server module from the same
VM. No HTTP stack, socket or optional dependency is involved. Each request
runs `ConduitMcp.Handler.dispatch/3` in a task, which classifies the era the
same way the HTTP transports do.

```elixir
defmodule MyApp.DocsServerTest do
  use ExUnit.Case, async: true

  setup do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {ConduitMcp.Client,
       name: name,
       transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.DocsServer}}
    )

    :ok = ConduitMcp.Client.await_ready(name)
    %{client: name}
  end

  test "echo", %{client: client} do
    assert {:ok, %ConduitMcp.Client.ToolResult{content: [%{"text" => "hi"}]}} =
             ConduitMcp.Client.call_tool(client, "echo", %{"message" => "hi"})
  end

  test "legacy era" do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {ConduitMcp.Client,
       name: name,
       protocol: :legacy,
       transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.DocsServer}}
    )

    :ok = ConduitMcp.Client.await_ready(name)
    assert {:ok, :legacy} = ConduitMcp.Client.era(name)
  end
end
```

`InProcess` options: `:server` (required; a `dsl: false`, DSL or
`ConduitMcp.Endpoint` module), `:assigns` (`conn.assigns` for every request),
`:principal` (a `ConduitMcp.Principal` map put on every request),
`:remote_ip`, and `:server_name`, `:server_version`, `:instructions` as for
the server's `ConduitMcp.Transport.StreamableHTTP`. Plugs (authentication,
rate limiting, header validation) do not run, so give the server an identity
with `:principal`. The server never sends server-to-client requests over
this transport. A modern `tools/call` made with `:on_progress`, or after
`set_log_level/2`, receives the tool's progress and log notifications as it
runs; `subscriptions/listen` needs an HTTP transport and is answered
`-32601`. Cancelling a request kills its task.

To exercise the real stdio transport, write a small `.exs` script that reads
newline-delimited JSON-RPC from stdin, passes each message to
`ConduitMcp.Handler.dispatch/3` for your server module, and writes each reply
as one JSON line to stdout (logs to stderr). Start it with
`command: System.find_executable("elixir")` and `args: ["-pa", ebin, ...,
"server.exs"]`. Pass `PATH` (and a UTF-8 locale) in `:env` if the script
needs more than the inherited allowlist. ConduitMCP's own suite does this in
`test/support/fixtures/stdio_server.exs`.

## Telemetry

Every client event's metadata has `:client`, `:server_id`, `:transport`
(`:stdio`, `:http`, `:in_process`) and `:era`. Metadata comes from a fixed
allowlist and never carries `_meta`, tokens or raw error data, nor
arguments or results unless you opt in to payload capture:

| Option | Default | Meaning |
|---|---|---|
| `telemetry: [capture_payloads: ...]` | `false` | `false`: the `tool_call` span has no `:arguments` or `:result` key. `[redact: fun, max_bytes: n]`: `:start` adds `:arguments` and `:stop` adds `:result`, each passed through `fun` (required; `true` alone raises at start) in the calling process. `:max_bytes` (default 4 096) caps the JSON size |

```elixir
{ConduitMcp.Client,
 name: :docs,
 transport: transport,
 telemetry: [capture_payloads: [redact: &MyApp.Telemetry.redact/1, max_bytes: 2_048]]}
```

`:arguments` are the arguments given to `call_tool/4` (before pre-hooks on a
governed client). `:result` is the returned `ToolResult` as
`%{"content" => ..., "isError" => ..., "structuredContent" => ...}` (no
`_meta`), or `nil` for an error or a task. Each holds what `redact` returned,
`{:truncated, byte_size}` when its JSON is over `:max_bytes` (never a partial
value), or `:redaction_failed` when `redact` raises or returns something that
cannot be JSON-encoded - a `ConduitMcp.Client.Secret` included. No hash of a
payload is ever emitted. A hub takes the same `:telemetry` option for every
server, or per server in its `client_opts`.

| Event | Emitted in | Adds |
|---|---|---|
| `[:conduit_mcp, :client, :request, :start \| :stop \| :exception]` | caller | One span per request sent (each MRTR round is one). `:method`; `:stop` adds `:status`, `:error_kind`, `:request_id` |
| `[:conduit_mcp, :client, :tool_call, :start \| :stop \| :exception]` | caller | One span per `call_tool/4`. `:tool_name`; `:stop` adds `:status`, `:error_kind`, `:is_error` and measurement `:rounds`. With payload capture, `:start` adds `:arguments` and `:stop` adds `:result` |
| `[:conduit_mcp, :client, :connection, :transition]` | connection | `:from`, `:to`, `:reason`, `:attempt` |
| `[:conduit_mcp, :client, :request, :cancel]` | connection | `:method`, `:request_id`, `:reason` (`:timeout`, `:caller_down`, `:caller_timeout`) |
| `[:conduit_mcp, :client, :response, :dropped]` | connection | `:request_id` |
| `[:conduit_mcp, :client, :notification]` | connection | `:method` |
| `[:conduit_mcp, :client, :log, :dropped]` | connection | nothing (a `notifications/message` over `:log_rate_limit`) |
| `[:conduit_mcp, :client, :cache, :refresh, :start \| :stop]` | connection | `:kind`, `:trigger` (`:demand`, `:list_changed`); `:stop` adds `:status`, `:error_kind` and measurements `:count`, `:pages`, `:rejected` |
| `[:conduit_mcp, :client, :tool, :rejected]` | the process that fetched | `:tool_name`, `:reason` |
| `[:conduit_mcp, :client, :tool, :definition_changed]` | connection | `:tool_name` |
| `[:conduit_mcp, :client, :policy, :decision]` | caller | See [client_permissions_and_hooks.md](client_permissions_and_hooks.md) |
| `[:conduit_mcp, :client, :hook, :stop \| :exception]` | caller | See [client_permissions_and_hooks.md](client_permissions_and_hooks.md) |
| `[:conduit_mcp, :client, :hub, :server_failed \| :server_restarted \| :collision]` | hub | See [client_hub.md](client_hub.md) |
| `[:conduit_mcp, :client, :adapter, :strict_fallback]` | caller | See [client_llm_adapters.md](client_llm_adapters.md) |

Handlers attached to events emitted in the connection process run there and
must be fast. `:tool_name` and `:method` are server-supplied (sanitized):
never use them as metric tags. Full measurement and metadata lists are in
`ConduitMcp.Telemetry`.

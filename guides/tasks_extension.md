# Tasks Extension

`ConduitMcp.Ext.Tasks` implements the MCP Tasks extension
(`io.modelcontextprotocol/tasks`) for the modern era (`2026-07-28`). A
`tools/call` that would take too long answers at once with a task. The
client then polls `tasks/get`, or listens for `notifications/tasks`, until
the task finishes.

> #### Experimental and unstable {: .warning}
>
> The extension's own repository calls it experimental. It still tracks
> SEP-2663 and already disagrees with the core specification: it documents
> `-32003` where `2026-07-28` uses `-32021`, and this library follows the
> core specification. This API, its configuration and its wire output may
> change in any release. It is off unless you enable it.

For legacy (`2025-11-25`) tasks, see `ConduitMcp.Tasks` and
[Using Oban for MCP Tasks](oban_tasks.md). The [comparison](#compared-with-legacy-tasks)
at the end lists the differences.

## Enabling

```elixir
config :conduit_mcp, :ext_tasks, true

# or, with options:
config :conduit_mcp, :ext_tasks,
  store: MyApp.TaskStore,        # default ConduitMcp.Ext.Tasks.EtsStore
  janitor: [interval: 30_000],   # ConduitMcp.Session.Janitor options, or false
  max_rows: 10_000,              # row cap passed to the store's create/2, or :infinity
  notifier: MyApp.TaskNotifier   # default ConduitMcp.Ext.Tasks.ListenNotifier; nil for none
```

The value is validated when `:conduit_mcp` starts. Anything other than
`true`, `false` or a keyword list of those four keys raises an
`ArgumentError` naming `:ext_tasks`.

When the extension is enabled:

- **Supervision.** The application starts `ConduitMcp.Ext.Tasks.EtsStore.Owner`
  (only with the default store) and a janitor named
  `ConduitMcp.Ext.Tasks.Janitor`.
- **Discovery.** `server/discover` lists the extension under
  `capabilities.extensions["io.modelcontextprotocol/tasks"]`.
- **Routing.** The modern era adds `tasks/get`, `tasks/update` and
  `tasks/cancel`.
- **Listen filter.** `subscriptions/listen` honours `taskIds`.

## Returning a task

A `tools/call` callback returns `{:task, attrs}`:

```elixir
# Manual mode
def handle_call_tool(_conn, "build", %{"ref" => ref}) do
  {:task,
   ttl_ms: :timer.minutes(30),
   poll_interval_ms: 2_000,
   status_message: "Queued",
   start: fn task_id -> MyApp.Builds.enqueue(task_id, ref) end}
end

# DSL mode
tool "build", "Build a ref" do
  param :ref, :string, "Git ref", required: true

  handle fn _conn, %{"ref" => ref} ->
    {:task, start: fn task_id -> MyApp.Builds.enqueue(task_id, ref) end}
  end
end

# Endpoint mode (a tool component)
@impl true
def execute(%{ref: ref}, _conn) do
  {:task, start: fn task_id -> MyApp.Builds.enqueue(task_id, ref) end}
end
```

`attrs` is a keyword list or an atom-keyed map. Every key is optional:

| Key | Meaning |
|---|---|
| `:ttl_ms` | Lifetime from creation, a non-negative integer (default 1 hour); `nil` means unlimited |
| `:poll_interval_ms` | Suggested polling interval, a positive integer |
| `:status_message` | Initial status message |
| `:start` | `fn task_id -> ... end`, called once the task is stored |

**`:start` is where the work begins.** Spawn the work there (a `Task` under
your supervisor, an Oban job, a message to a GenServer) and return quickly,
because the request is waiting on it. If `:start` raises, the request still
gets its `CreateTaskResult`, and the task moves to `failed` with `-32603`.
An unknown key or a value of the wrong type in `attrs` is logged and
answered with `-32603`; no task is created.

What happens on the request:

1. The client must have declared the extension in this request's
   `_meta["io.modelcontextprotocol/clientCapabilities"].extensions`.
   Otherwise the answer is `-32021` with `data.requiredCapabilities` (HTTP
   400).
2. The task is stored **before** the request is answered, owned by
   `ConduitMcp.Principal.id(conn)`.
3. `:start` runs.
4. The request is answered with a `CreateTaskResult`:

```json
{
  "taskId": "0hS1…43 url-safe chars",
  "status": "working",
  "createdAt": "2026-10-17T12:00:00.000Z",
  "lastUpdatedAt": "2026-10-17T12:00:00.000Z",
  "ttlMs": 1800000,
  "statusMessage": "Queued",
  "pollIntervalMs": 2000,
  "resultType": "task",
  "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "my-server", "version": "1.0.0"}}
}
```

Only `tools/call` may return a task. From any other callback, on a legacy
request, or while the extension is disabled, `{:task, _}` is logged and
answered with `-32603`. A tool that serves both eras can branch on the era:

```elixir
handle fn conn, params ->
  case ConduitMcp.Ctx.from_conn(conn) do
    %ConduitMcp.Ctx{era: :modern} -> {:task, start: &MyApp.Jobs.start(&1, params)}
    _legacy -> text(MyApp.Jobs.run_now(params))
  end
end
```

## Driving a task from the worker

The worker addresses the task by id alone. The id is the capability, so
keep it out of logs.

| Function | Effect |
|---|---|
| `status(id)` | `{:ok, task}` or `{:error, :not_found}` (not owner-scoped) |
| `cancelled?(id)` | `true` once `tasks/cancel` ran; `false` for an unknown id |
| `progress(id, message)` | Updates `statusMessage` and `lastUpdatedAt` without changing the status |
| `complete(id, result, opts)` | `completed` with `result`: what the tool would have returned synchronously, a `CallToolResult` map (`isError: true` included) |
| `fail(id, error, opts)` | `failed` with a JSON-RPC error, `%{"code" => ..., "message" => ...}` or `{code, message}` |
| `require_input(id, input_requests, opts)` | `input_required` with MRTR input requests |

`complete/3`, `fail/3` and `require_input/3` accept `:status_message`.
After a terminal state, `complete`, `fail` and `progress` return
`{:error, :terminal}`.

```elixir
defmodule MyApp.BuildWorker do
  use Oban.Worker, queue: :builds

  alias ConduitMcp.Ext.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => id, "ref" => ref}}) do
    if Tasks.cancelled?(id) do
      {:cancel, "cancelled by client"}
    else
      :ok = Tasks.progress(id, "Building #{ref}")
      output = MyApp.Builds.run(ref)
      Tasks.complete(id, %{"content" => [%{"type" => "text", "text" => output}]})
      :ok
    end
  end
end
```

### Input mid-flight

`require_input/3` moves the task to `input_required`. The client reads the
requests with `tasks/get` and answers with `tasks/update`. Once every
outstanding key is answered, the task returns to `working`, and the answers
are in `status/1`'s `input_responses`:

```elixir
case ConduitMcp.Ext.Tasks.status(id) do
  {:ok, %{input_responses: %{"script" => %{"action" => "accept", "content" => content}}}} ->
    render(content)

  {:ok, %{status: "working"}} ->
    :ok =
      ConduitMcp.Ext.Tasks.require_input(
        id,
        %{"script" => ConduitMcp.MRTR.elicit("What should be rendered?", schema)},
        status_message: "Waiting for a script"
      )

  {:ok, %{status: "input_required"}} ->
    :not_yet
end
```

- **Keys are single-use.** Each key must be unique over the task's whole
  life; reusing one returns `{:error, {:duplicate_keys, keys}}`.
- **Validated requests.** An empty map, or values not built with
  `ConduitMcp.MRTR`, return `{:error, :invalid_input_requests}`.
- **Waiting.** Poll `status/1`, or configure a notifier that wakes the
  worker (see [Status notifications](#status-notifications)).

### Cancellation

Cancellation is cooperative. `tasks/cancel` moves a non-terminal task to
`cancelled` immediately; the worker should check `cancelled?/1` and stop.
The terminal states, `completed`, `failed` and `cancelled`, are final.

## Routes

| Method | Params | Result |
|---|---|---|
| `tasks/get` | `taskId` | The task with `resultType`, plus `inputRequests` (when `input_required`), `result` (when `completed`) or `error` (when `failed`) |
| `tasks/update` | `taskId`, `inputResponses` (object) | `{}`. Answers for keys that aren't outstanding are ignored. |
| `tasks/cancel` | `taskId` | `{}` |

Every route:

- **requires the extension** to be declared in the request's client
  capabilities (`-32021` otherwise, HTTP 400);
- **requires `Mcp-Name` equal to `params.taskId`** over Streamable HTTP
  (`-32020` otherwise, HTTP 400; see [Protocol Eras](protocol_eras.md#request-headers));
- **is owner-scoped.** A task owned by another principal answers exactly
  like a missing one: `-32602 "Failed to retrieve task: Task not found"`.
  The id is never echoed. A missing `taskId` is `-32602 "Missing taskId"`.

There is no `tasks/list` and no `tasks/result`. A task id is a bearer token,
so tasks are never enumerated.

## Ownership

A task belongs to the principal that created it (`ConduitMcp.Principal.id/1`;
see [Authentication](authentication.md#the-canonical-principal)). A task
created without authentication is owned by `nil`, and then its id (32
random bytes) is its only protection. Enable authentication when task
results are sensitive.

## Status notifications

Every change is handed to the configured `ConduitMcp.Ext.Tasks.Notifier`.
The default, `ConduitMcp.Ext.Tasks.ListenNotifier`, sends it as
`notifications/tasks` (the full task state, the same as `tasks/get`) to the
`subscriptions/listen` streams that named the task in `taskIds`:

```json
{"jsonrpc": "2.0", "id": 9, "method": "subscriptions/listen",
 "params": {"notifications": {"taskIds": ["0hS1…"]},
            "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                      "io.modelcontextprotocol/clientCapabilities":
                        {"extensions": {"io.modelcontextprotocol/tasks": {}}}}}}
```

- `taskIds` is honoured only while the extension is enabled; otherwise it is
  an unknown field and left out of the acknowledgment.
- Naming task ids without declaring the extension is `-32021`. A wrong type,
  or more than 1 000 ids, is `-32602`.
- Each id is kept only if the caller owns the task. Any other id is dropped
  from the acknowledgment silently, so a foreign id and an unknown one look
  the same.
- Delivery goes **only** to streams whose principal owns the task. A task
  owned by `nil` reaches only unauthenticated streams. Delivery is
  node-local, like the rest of [Subscriptions](subscriptions.md).

A custom notifier replaces the default. To keep listen delivery, call
`ListenNotifier.task_changed/1` from it:

```elixir
defmodule MyApp.TaskNotifier do
  @behaviour ConduitMcp.Ext.Tasks.Notifier

  @impl true
  def task_changed(task) do
    ConduitMcp.Ext.Tasks.ListenNotifier.task_changed(task)
    MyApp.Workers.wake(task.task_id)
  end
end
```

`task_changed/1` runs in the process that made the change, right after the
store write. An exception in it is logged and swallowed, so a notifier can't
fail a request or a worker. Any notifier that delivers to clients must
deliver only to the record's `owner`. `notifier: nil` turns notifications
off.

## Storage

`ConduitMcp.Ext.Tasks.Store` is the behaviour; `ConduitMcp.Ext.Tasks.EtsStore`
is the in-memory, single-node default. For durable or multi-node tasks,
implement the behaviour and configure it with `store:`.

| Callback | Contract |
|---|---|
| `create(task, opts)` | Store a new record; `opts[:max_rows]` is the cap. Return only once a `get/2` would find it. |
| `get(task_id, owner \| :any)` | `{:error, :not_found}` when `owner` differs (`===`), exactly as for a missing id. `:any` is for server-side callers only. |
| `update(task_id, owner \| :any, fun)` | Atomically replace the record with `fun.(record)`. An `{:error, _}` from `fun` leaves it unchanged. |
| `cancel(task_id, owner)` | A non-terminal record becomes `cancelled`; a terminal one is returned unchanged. |
| `put_status(task_id, status, fields)` | Worker side: move a non-terminal record to `status`, merging `fields`; `{:error, :terminal}` otherwise. |
| `cleanup(default_ttl_ms)` | Optional. Evict expired records and return the count. |

- **No enumeration.** There is deliberately no `list` callback.
- **Atomicity.** `update/3`, `cancel/2` and `put_status/3` are
  read-modify-write operations. Apply each atomically (compare-and-swap, a
  row lock, a transaction). Otherwise a client's `tasks/update` can
  overwrite a worker's `completed` with `working`. `EtsStore` uses
  `:ets.select_replace/2` as a compare-and-swap.
- **Terminal states are final.** `put_status/3` and `cancel/2` must not
  change a `completed`, `failed` or `cancelled` record.
- **Row cap.** When `create/2` hits `:max_rows` it returns
  `{:error, :task_limit_reached}`, and the tool call gets `-32603 "Task limit
  reached"`. With the default cap of 10 000, a client looping a
  task-creating tool can't grow the table without bound.

`examples/oban_tasks_server/` has `Examples.ObanTasks.ExtStore`, a SQLite
store that does compare-and-swap on a version column.

## Janitor

`ConduitMcp.Ext.Tasks.Janitor` is a `ConduitMcp.Session.Janitor` that calls
the store's `cleanup/1` every minute. A record expires `ttl_ms` after
`created_at`. A record with `ttl_ms: nil` is evicted only once it is
terminal and older than the janitor's `ttl` (default one hour).

```elixir
config :conduit_mcp, :ext_tasks, janitor: [interval: :timer.seconds(30), ttl: :timer.hours(4)]
config :conduit_mcp, :ext_tasks, janitor: false
```

Each sweep emits `[:conduit_mcp, :ext_tasks, :cleanup]` with `%{removed: n}`
and `%{store: module}`.

## Errors

| Code | When |
|---|---|
| `-32021` (HTTP 400) | The request didn't declare `io.modelcontextprotocol/tasks` (task creation, `tasks/*`, `taskIds`) |
| `-32020` (HTTP 400) | `Mcp-Name` missing or not equal to `taskId` on `tasks/*` |
| `-32602` | Task not found or not yours; missing `taskId`; `inputResponses` not an object |
| `-32603` | `{:task, _}` on the legacy era, from a non-tool callback, or with the extension disabled; invalid `attrs`; row cap reached |

## Compared with legacy tasks

| | `ConduitMcp.Tasks` | `ConduitMcp.Ext.Tasks` |
|---|---|---|
| Era | `2025-11-25` (legacy) only | `2026-07-28` (modern) only |
| Status | frozen; goes away with the legacy era | experimental |
| Enabling | always routed; store via `config :conduit_mcp, :tasks_store` | `config :conduit_mcp, :ext_tasks, true` |
| Tool returns | `task(task_id, message)` (id in `_meta.task`) | `{:task, attrs}` → `CreateTaskResult` |
| Methods | `tasks/get`, `tasks/cancel`, `tasks/result`, `tasks/list` | `tasks/get`, `tasks/update`, `tasks/cancel` |
| Mid-task input | — | `require_input/3` + `tasks/update` |
| Change notifications | — | `notifications/tasks` over `subscriptions/listen` |
| Store behaviour | `ConduitMcp.Tasks.Store` | `ConduitMcp.Ext.Tasks.Store` |

The two stores are separate. A server that serves both eras configures both,
as `examples/oban_tasks_server/` does.

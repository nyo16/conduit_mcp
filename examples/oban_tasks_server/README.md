# Oban Tasks Server — durable MCP tasks via Oban + SQLite

A runnable ConduitMCP example demonstrating the [MCP 2025-11-25 tasks
lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
backed by a real job queue (Oban) over a real database (SQLite via
`Oban.Engines.Lite`). Tasks survive BEAM restarts; cancellations propagate
to the queue; `input_required` is exercised end-to-end via `{:snooze, _}`.

This is the production-shape companion to
[`examples/async_tasks_server/`](../async_tasks_server/), which uses
in-memory ETS + `Task.Supervisor` and has zero extra dependencies. Use
that one for prototyping; use this one when you need durability.

## What it shows

- **Pluggable task storage.** `examples/oban_tasks_server` registers
  `Examples.ObanTasks.Store` as the `ConduitMcp.Tasks.Store`
  implementation. The standard `tasks/get`, `tasks/cancel`,
  `tasks/result`, and `tasks/list` JSON-RPC routes work unchanged —
  they dispatch through `ConduitMcp.Tasks`, which now delegates to
  whichever store is configured.
- **Restart-survival.** Kill the BEAM mid-render; restart; the task
  resumes from the queue. A small `Examples.ObanTasks.Rescuer` on
  boot moves jobs left in `executing` state back to `available`
  (`Oban.Engines.Lite` doesn't ship `Lifeline`).
- **Cooperative cancellation.** `tasks/cancel` flips the task row to
  `cancelled` *and* calls `Oban.cancel_job/1`. The worker also polls
  `ConduitMcp.Cancellation.cancelled?/1` at each chunk so a client
  `notifications/cancelled` aborts mid-flight too.
- **`input_required` via snooze.** `ask_then_render` writes the
  elicitation schema, returns `{:snooze, 5}`, and Oban re-invokes the
  worker every 5 seconds. The companion `provide_render_input` tool
  stages the input and flips the status back to `working`; the
  worker's next attempt picks it up and proceeds to `completed`.
- **No `try/rescue` in the worker.** Exceptions bubble. A telemetry
  handler attached to `[:oban, :job, :exception]` mirrors permanent
  failures into the task row as `status: "failed"`.

## Tools

| Name | What it does |
| ---- | ------------ |
| `ping` | Sync round-trip — proves the server is alive. |
| `slow_render` | `task_support :supported`. Enqueues an Oban job. Updates `progress` from `0` to `100` over `duration_ms` ms, then `status: "completed"`. |
| `ask_then_render` | `task_support :supported`. Pauses immediately with `status: "input_required"` and an elicitation schema in `metadata.elicit.schema`. Resumes once `provide_render_input` is called. |
| `provide_render_input` | Stages `script` text under `metadata.input` and flips status back to `working` so the snoozed worker resumes. |

## Prerequisites

- Elixir `~> 1.18`
- SQLite — the `ecto_sqlite3` driver ships its own copy via `exqlite`, no
  system install needed.
- `curl` and/or `python3` if you want to use the shell walkthrough below.
  (The `python3` invocations just extract the task id from JSON — feel free
  to substitute `jq`.)

## Running

```bash
cd examples/oban_tasks_server
mix deps.get
iex -S mix                 # or: mix run --no-halt
```

The server listens on `http://localhost:4041/`.

The SQLite database lives at `${TMPDIR}/conduit_oban_tasks.sqlite3` by
default — override with `OBAN_SQLITE_PATH=/abs/path/here mix run --no-halt`.
That path is also what you reset to wipe state.

## Walkthrough — curl

The full lifecycle, runnable end-to-end against a fresh boot.

```bash
# 1) Initialize the MCP session.
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 1, "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {"name": "curl", "version": "0"}
  }
}'

# 2) List tools.
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 2, "method": "tools/list"
}'

# 3) Kick off a long-running tool. The response includes _meta.task.id.
RESP=$(curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 3, "method": "tools/call",
  "params": {"name": "slow_render", "arguments": {"script": "scene 1", "duration_ms": 4000}}
}')
TASK_ID=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["_meta"]["task"]["id"])')
echo "task=$TASK_ID"

# 4) Poll status. Repeat until status flips off "working".
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 4, \"method\": \"tasks/get\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"
# -> "metadata":{"progress":40},"status":"working", ...

# 5) Fetch the final payload once status == "completed".
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 5, \"method\": \"tasks/result\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"

# 6) Cancel mid-flight (start a new long task, then cancel).
RESP=$(curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 6, "method": "tools/call",
  "params": {"name": "slow_render", "arguments": {"script": "big", "duration_ms": 30000}}
}')
TASK_ID=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["_meta"]["task"]["id"])')
sleep 1
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 7, \"method\": \"tasks/cancel\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"
# -> status:"cancelled", Oban job also cancelled.

# 7) input_required flow.
RESP=$(curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 8, "method": "tools/call",
  "params": {"name": "ask_then_render", "arguments": {"duration_ms": 500}}
}')
TASK_ID=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["_meta"]["task"]["id"])')
sleep 6  # let the first attempt land in input_required + snooze
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 9, \"method\": \"tasks/get\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"
# -> status:"input_required", metadata.elicit.schema:{...}

curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 10, \"method\": \"tools/call\",
  \"params\": {
    \"name\": \"provide_render_input\",
    \"arguments\": {\"task_id\": \"$TASK_ID\", \"script\": \"act 2\"}
  }
}"
sleep 8  # snooze fires, worker completes
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 11, \"method\": \"tasks/result\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"

# 8) List everything you've created.
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 12, "method": "tasks/list"
}'
```

## Walkthrough — Req from IEx

Same flow, but using [`Req`](https://hex.pm/packages/req) so you can poke
at it from a live `iex -S mix` session. `:req` is already in the example's
deps (under `:dev, :test`).

```elixir
# From inside iex -S mix:
url = "http://localhost:4041/"
rpc = fn id, method, params ->
  Req.post!(url, json: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}).body
end
notify = fn method, params ->
  Req.post!(url, json: %{"jsonrpc" => "2.0", "method" => method, "params" => params})
end

# Initialize.
rpc.(1, "initialize", %{
  "protocolVersion" => "2025-11-25",
  "capabilities" => %{},
  "clientInfo" => %{"name" => "iex", "version" => "0"}
})

# Start a slow render.
%{"result" => %{"_meta" => %{"task" => %{"id" => task_id}}}} =
  rpc.(2, "tools/call", %{
    "name" => "slow_render",
    "arguments" => %{"script" => "scene 1", "duration_ms" => 4000}
  })

# Poll.
Stream.repeatedly(fn ->
  Process.sleep(500)
  rpc.(3, "tasks/get", %{"taskId" => task_id})
end)
|> Enum.reduce_while(nil, fn resp, _ ->
  status = get_in(resp, ["result", "task", "status"])
  IO.puts("status=#{status}, progress=#{get_in(resp, ["result", "task", "metadata", "progress"])}")
  if status in ["completed", "failed", "cancelled"], do: {:halt, resp}, else: {:cont, nil}
end)

# Fetch the final payload.
rpc.(4, "tasks/result", %{"taskId" => task_id})

# Notification flavor: notifications/cancelled (no id, no response).
notify.("notifications/cancelled", %{"requestId" => task_id, "reason" => "user pressed stop"})
```

## Walkthrough — Hermolaos client

[`Hermolaos`](https://github.com/nyo16/hermolaos) is an Elixir MCP client.
It covers the standard MCP operations (tools/resources/prompts/ping/cancel)
but does not have built-in wrappers for the 2025-11-25 tasks routes — so
you'll combine Hermolaos for the standard parts and raw HTTP (or a thin
wrapper) for `tasks/*`.

Add to your client app's `mix.exs`:

```elixir
{:hermolaos, "~> 0.3.0"}
```

Then, with this example running on `http://localhost:4041/`:

```elixir
# Connect over Streamable HTTP.
{:ok, conn} = Hermolaos.connect(:http, url: "http://localhost:4041/")

# Sanity checks.
{:ok, %{}} = Hermolaos.ping(conn)
{:ok, %{tools: tools}} = Hermolaos.list_tools(conn)
Enum.map(tools, & &1.name)  # ["ask_then_render", "ping", "provide_render_input", "slow_render"]

# Kick off slow_render. The result includes _meta.task.id because the
# tool declared task_support :supported.
{:ok, result} = Hermolaos.call_tool(conn, "slow_render",
  %{script: "scene 1", duration_ms: 4000})
task_id = get_in(result, [:_meta, :task, :id])

# Hermolaos does not have a tasks/get wrapper — fall back to Req for the
# poll. (Or write a 6-line helper around the Hermolaos transport.)
poll = fn ->
  Req.post!("http://localhost:4041/",
    json: %{
      "jsonrpc" => "2.0", "id" => 99, "method" => "tasks/get",
      "params" => %{"taskId" => task_id}
    }
  ).body
end

Stream.repeatedly(poll)
|> Stream.each(fn _ -> Process.sleep(500) end)
|> Enum.find(fn r -> get_in(r, ["result", "task", "status"]) in ["completed", "failed", "cancelled"] end)

# Cooperative cancellation IS in Hermolaos.
:ok = Hermolaos.cancel(conn, task_id, reason: "user pressed stop")

:ok = Hermolaos.disconnect(conn)
```

## Restart-survival demo

The whole point of the durable backend is that work outlives the BEAM.

```bash
# 1) Start a long task.
RESP=$(curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {"name": "slow_render", "arguments": {"script": "long", "duration_ms": 15000}}
}')
TASK_ID=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["_meta"]["task"]["id"])')

# 2) Wait a bit so it's mid-render.
sleep 3
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tasks/get\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"
# -> status:"working", progress=20

# 3) HARD-KILL the server.
pkill -9 -f "oban_tasks_server"

# 4) Restart.
mix run --no-halt &
sleep 5

# 5) Same task id; same row — Oban resumes from where it left off.
curl -s -X POST http://localhost:4041/ -H 'Content-Type: application/json' -d "{
  \"jsonrpc\": \"2.0\", \"id\": 3, \"method\": \"tasks/get\",
  \"params\": {\"taskId\": \"$TASK_ID\"}
}"
# -> status eventually flips to "completed". The boot log says:
#    "ObanTasks.Rescuer: rescued 1 executing job(s)"
```

## Architecture

```
                ┌──────────────────────────────────────┐
   HTTP POST    │  ConduitMcp.Transport.StreamableHTTP  │ :4041
       │        └──────────────┬───────────────────────┘
       ▼                       │
   tools/call             tasks/{get,cancel,result,list}
   ─────────                   │
       │                       ▼
       │           ┌────────────────────────────┐
       │           │     ConduitMcp.Tasks       │
       │           │  (facade — dispatches to)  │
       │           └──────────────┬─────────────┘
       │                          │
       ▼                          ▼
   Server                ┌──────────────────────────┐
   .ObanTasksServer      │ Examples.ObanTasks.Store │ ── Repo (SQLite)
   handle/2  ─────────► Oban.insert(Worker) ───────► oban_jobs row
                                                       │
                                                       ▼
                                              Worker.perform/1
                                                       │
                                                       ▼
                                              updates mcp_tasks row
```

Supervision tree (`Examples.ObanTasks.Application.start/2`):

1. `Examples.ObanTasks.Repo` — Ecto + SQLite3
2. `Examples.ObanTasks.Migrator` — one-shot, runs Oban schema + `mcp_tasks` migration
3. `Examples.ObanTasks.Rescuer` — one-shot, resets `executing` jobs to `available`
4. `Oban` — engine `Oban.Engines.Lite`, one `mcp_tasks` queue
5. `ConduitMcp.Tasks.Janitor` — prunes terminal-state `mcp_tasks` rows
6. `Bandit` — Streamable HTTP transport on port 4041

The Telemetry hook (`Examples.ObanTasks.Telemetry.attach/0`) is attached
*before* the supervision tree starts so failed jobs always end up mirrored
to the task row even if they fail on the very first attempt.

## Pluggable backend mechanics

The flip is one line:

```elixir
# config/config.exs
config :conduit_mcp, :tasks_store, Examples.ObanTasks.Store
```

`ConduitMcp.Tasks` reads this with `Application.get_env(:conduit_mcp,
:tasks_store, ConduitMcp.Tasks.EtsStore)` and delegates every storage
call. The framework's handler routes never see SQLite directly — they
just keep calling `ConduitMcp.Tasks.get/1`, `.cancel/1`, `.list/1`, etc.

To switch back to the in-memory ETS store, delete that config line — the
default takes over and `examples/async_tasks_server/` is the worked
example for that path.

## Known limits

- `Oban.Engines.Lite` is documented as **single-node, low-concurrency**.
  This example caps the `mcp_tasks` queue at 4 concurrent jobs. For
  multi-node deployments switch to Postgres (`Oban` default engine) —
  [`examples/oban_task_store.ex`](../oban_task_store.ex) is the
  Postgres-flavored sibling.
- `input_required` polling uses `{:snooze, 5}` — re-attempts every five
  seconds. Production users who want instantaneous resume should wake
  the snoozed job manually after staging input (e.g., `Oban.insert/2`
  with `:replace` semantics).
- `tasks/cancel` flips the row and calls `Oban.cancel_job/1`. A worker
  already mid-chunk may finish the chunk before the next
  `Cancellation.cancelled?/1` check sees it — the worst case is one
  extra `chunk_ms` of work (~50ms with default settings).

## Further reading

- [`guides/oban_tasks.md`](../../guides/oban_tasks.md) — broader guide,
  including the Postgres mapping and Oban Pro workflow patterns.
- [`examples/async_tasks_server/`](../async_tasks_server/) — the
  zero-deps ETS counterpart of this example.
- [`examples/oban_task_store.ex`](../oban_task_store.ex) — a Postgres-
  flavored reference implementation of `ConduitMcp.Tasks.Store`.
- [MCP 2025-11-25 tasks
  spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks).

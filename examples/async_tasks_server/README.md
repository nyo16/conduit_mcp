# Async Tasks Example (MCP 2025-11-25 tasks lifecycle)

This example shows how to expose a long-running tool that hands work off to a
supervised `Task` and lets the client poll progress via the MCP **tasks**
methods introduced in spec 2025-11-25.

## What it covers

- Declaring a tool with `task_support :supported` so clients know it may
  return a task id instead of an inline result.
- Using `ConduitMcp.Tasks` (`create/2`, `update/2`) to track lifecycle state
  in ETS without writing your own store.
- Spawning the actual work on a `Task.Supervisor` so it outlives the HTTP
  request.
- Cooperatively cancelling via `ConduitMcp.Cancellation` and/or polling the
  task's own `status` field.
- Returning a structured payload (`output_schema` + `structuredContent`).

## Files

- `server.ex` — defines `Examples.AsyncTasksServer` with two tools:
  `quick_echo` (synchronous) and `slow_render` (async via task).
- `application.ex` — wires Bandit, a `Task.Supervisor` for the workers,
  and `ConduitMcp.Tasks.Janitor` for periodic cleanup of completed tasks.

## Run

From the repo root:

```bash
iex -S mix run -e "Examples.AsyncTasks.Application.start(:normal, [])"
```

The server listens on `http://localhost:4040/`.

## Flow

1. **Start an async render** — `tools/call`:
   ```bash
   curl -s -X POST http://localhost:4040/ -H 'Content-Type: application/json' -d '{
     "jsonrpc": "2.0", "id": 1, "method": "tools/call",
     "params": {"name": "slow_render", "arguments": {"script": "intro", "duration_ms": 3000}}
   }'
   ```
   Response contains `_meta.task.id`:
   ```json
   {
     "result": {
       "content": [{"type": "text", "text": "Render started; poll tasks/get for progress"}],
       "_meta": {"task": {"id": "ABC-..."}}
     }
   }
   ```

2. **Poll progress** — `tasks/get`:
   ```bash
   curl -s -X POST http://localhost:4040/ -d '{
     "jsonrpc": "2.0", "id": 2, "method": "tasks/get",
     "params": {"taskId": "ABC-..."}
   }'
   ```
   While running, `task.status == "working"`.

3. **Fetch the result** — `tasks/result` (once status is `"completed"`):
   ```bash
   curl -s -X POST http://localhost:4040/ -d '{
     "jsonrpc": "2.0", "id": 3, "method": "tasks/result",
     "params": {"taskId": "ABC-..."}
   }'
   ```

4. **Cancel mid-flight** — `tasks/cancel`:
   ```bash
   curl -s -X POST http://localhost:4040/ -d '{
     "jsonrpc": "2.0", "id": 4, "method": "tasks/cancel",
     "params": {"taskId": "ABC-..."}
   }'
   ```
   The worker checks the task state every chunk and stops cleanly.

5. **List all tasks** (optionally filtered by status) — `tasks/list`:
   ```bash
   curl -s -X POST http://localhost:4040/ -d '{
     "jsonrpc": "2.0", "id": 5, "method": "tasks/list",
     "params": {"status": "completed"}
   }'
   ```

## Tool schema as seen by clients

When the client calls `tools/list`, `slow_render` is advertised with:

```json
{
  "name": "slow_render",
  "title": "Slow Render",
  "description": "Renders something slowly",
  "inputSchema": { "...": "..." },
  "outputSchema": {
    "type": "object",
    "properties": { "frames": {"type": "integer"}, "script": {"type": "string"} },
    "required": ["frames", "script"]
  },
  "execution": { "taskSupport": "supported" }
}
```

A client that understands `execution.taskSupport` will look for a task id in
the response's `_meta.task` and switch to polling. A client that doesn't will
get the same plain `content` array and treat it as an immediate response —
which is also valid; ConduitMCP simply returns the friendly "started" text.

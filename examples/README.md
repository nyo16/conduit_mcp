# Examples

Runnable examples and reference implementations grouped by what they demonstrate.

## Runnable servers

| Directory | What it shows | Guide |
|-----------|---------------|-------|
| [`simple_tools_server/`](simple_tools_server) | DSL mode minimum viable server with two synchronous tools | [DSL mode](../guides/dsl_mode.md) |
| [`async_tasks_server/`](async_tasks_server) | MCP 2025-11-25 tasks lifecycle — long-running tool spawns a Task.Supervisor child, client polls `tasks/get` / `tasks/result` | [Tasks (in CHANGELOG)](../CHANGELOG.md) |
| [`oban_tasks_server/`](oban_tasks_server) | Same tasks lifecycle but **durable**: backed by Oban + SQLite via `ConduitMcp.Tasks.Store`. Survives BEAM restarts; exercises `input_required` via `{:snooze, _}` | [Oban tasks](../guides/oban_tasks.md) |
| [`mcp_apps_demo/`](mcp_apps_demo) | MCP Apps — tools that return a sandboxed HTML resource | [MCP Apps](../guides/mcp_apps.md) |
| [`phoenix_mcp/`](phoenix_mcp) | Mounting an MCP server inside a Phoenix router with auth | [Choosing a mode](../guides/choosing_a_mode.md) |

## Pluggable backends

These are not standalone servers — they are reference implementations of the
behaviours that `ConduitMcp.Session.Store` and
`ConduitMcp.OAuth.KeyProvider` define, ready to copy into your application
and adapt.

| File | Implements | Notes |
|------|------------|-------|
| [`redis_session_store.ex`](redis_session_store.ex) | `ConduitMcp.Session.Store` | Uses Redix; relies on Redis `EX` TTL, so no janitor needed. |
| [`postgres_session_store.ex`](postgres_session_store.ex) | `ConduitMcp.Session.Store` | Uses Ecto.Repo; the included migration scaffolds the table. |
| [`mnesia_session_store.ex`](mnesia_session_store.ex) | `ConduitMcp.Session.Store` | For multi-node BEAM deployments without an external store. |
| [`redis_key_provider.ex`](redis_key_provider.ex) | `ConduitMcp.OAuth.KeyProvider` | Shared JWKS cache for multi-node OAuth resource servers. |
| [`oban_task_store.ex`](oban_task_store.ex) | `ConduitMcp.Tasks.Store` | Postgres-flavored reference implementation. For a runnable variant on SQLite, see [`oban_tasks_server/`](oban_tasks_server). |

## Tooling

| File | What it does |
|------|--------------|
| [`simple_tools_server/test_server.sh`](simple_tools_server/test_server.sh) | curl-driven smoke test for the server |
| [`simple_tools_server/test_client.sh`](simple_tools_server/test_client.sh) | exercises the server through the stdio transport |
| [`simple_tools_server/telemetry_example.exs`](simple_tools_server/telemetry_example.exs) | attaches handlers to all built-in telemetry events |
| [`simple_tools_server/claude_desktop_config.json`](simple_tools_server/claude_desktop_config.json) | drop-in Claude Desktop config snippet |
| [`simple_tools_server/mcp_config.json`](simple_tools_server/mcp_config.json) | generic MCP client config |

## Running examples locally

The runnable servers each live in their own subdirectory but use the
parent project's `mix.exs`. From the repo root:

```bash
# Simple tools server
iex -S mix run examples/simple_tools_server/run.exs

# Async tasks server (ETS, zero extra deps)
iex -S mix run -e "Examples.AsyncTasks.Application.start(:normal, [])"

# Oban tasks server (durable, SQLite-backed) — has its own mix.exs
cd examples/oban_tasks_server && mix deps.get && iex -S mix

# Phoenix MCP — see examples/phoenix_mcp/README.md
```

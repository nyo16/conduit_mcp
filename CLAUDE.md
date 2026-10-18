# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ConduitMCP is an Elixir library implementing the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) in two eras at once: modern `2026-07-28` (stateless, per-request `_meta`) and legacy `2025-11-25` / `2025-06-18` (`initialize` + sessions). It lets developers build MCP servers that expose tools, resources, and prompts to LLM applications like Claude Desktop and VS Code, and ships a production MCP client (`ConduitMcp.Client`). The library is published on Hex as `conduit_mcp`.

## Build & Test Commands

```bash
mix deps.get              # Install dependencies
mix compile               # Compile
mix test                  # Run all tests (~2,360: 2,256 tests, 61 doctests, 40 properties; includes :integration and :stdio)
mix test test/conduit_mcp/dsl_test.exs           # Run a single test file
mix test test/conduit_mcp/dsl_test.exs:42        # Run a specific test line
mix format                # Format code
mix credo                 # Lint
mix dialyzer              # Static analysis (slow first run)
mix docs                  # Generate docs
mix bench                 # Run all benchmarks
mix bench validation      # Run a specific benchmark
mix bench --list          # List available benchmarks
MIX_ENV=test mix coveralls.html  # Coverage report
```

Requires Elixir ~> 1.18. No config directory exists; validation config is set via `Application.put_env(:conduit_mcp, :validation, [...])` in tests or application config.

## Architecture

MCP server modules are **stateless** — just compiled functions. Each HTTP request runs in its own Bandit process for maximum concurrency. Rate limiting uses a user-supplied Hammer module.

The library itself does start a supervision tree (`ConduitMcp.Application`, `mod:` in `mix.exs`). It is deliberately small: it owns the long-lived ETS tables that must outlive short-lived request processes, plus the session janitor.

- Always: `ConduitMcp.Cancellation.Owner`, `ConduitMcp.Cancellation.InFlightOwner` (requests in flight; `notifications/cancelled` is recorded only for those), `ConduitMcp.Session.EtsStore.Owner`, `ConduitMcp.Transport.SSE.Owner`, `ConduitMcp.Transport.SSEStream.Owner` (slot table for modern response streams), `ConduitMcp.Client.Registry` (a passive unique `Registry`; clients register in it, so names of any term need no atoms — the library starts **no** client processes), `ConduitMcp.Subscriptions` (a duplicate-key `Registry` of `subscriptions/listen` streams by topic), `ConduitMcp.Subscriptions.Admission` (the live `subscriptions/listen` streams of each principal behind `:max_listens_per_principal`; a GenServer streams call once per listen — admission must be serialized, unlike the ETS owners' hot paths), `ConduitMcp.Session.Janitor` (as `ConduitMcp.Session.Janitor.Default`; disable with `config :conduit_mcp, :session_janitor, false`), and a second `ConduitMcp.Session.Janitor` sweeping the cancellation table and dead processes' in-flight rows (as `ConduitMcp.Cancellation.Janitor`; disable with `config :conduit_mcp, :cancellation_janitor, false`).
- Conditionally: `ConduitMcp.Tasks.EtsStore.Owner` (default tasks store only), `ConduitMcp.Ext.Tasks.EtsStore.Owner` (tasks extension enabled with its default store) and the `ConduitMcp.Ext.Tasks` janitor (tasks extension enabled; `config :conduit_mcp, :ext_tasks`), `ConduitMcp.OAuth.KeyProvider.JWKS.Owner` (only when `Req` is compiled in).

Both janitor keys accept `true`, `false`, or a keyword list of `ConduitMcp.Session.Janitor` options; anything else raises at boot naming the key.

Every owner runs `ConduitMcp.EtsOwner`: a process that creates a `:public` table and then idles, retrying every second if the name was already taken. Reads and writes go straight to ETS from the calling process — **do not turn an owner into a `handle_call` gateway.**

### Request Flow

```
HTTP Request → Transport (StreamableHTTP/SSE) → Auth Plug → Rate Limit Plug → classify_era (ConduitMcp.Era) → HeaderValidation (modern only) → Message Rate Limit → Handler.dispatch/3 → Server Module callbacks
```

Modern requests never create or look up a session (except the principal check on a supplied session id) and may answer with an SSE stream (`{:stream, StreamSpec}` from `Handler.dispatch/3`, served by `ConduitMcp.Transport.SSEStream`). Legacy requests keep JSON responses and sessions.

### Client Architecture

Users supervise clients themselves: `{ConduitMcp.Client, opts}` or `{ConduitMcp.Client.Hub, opts}`. Options are validated at `child_spec/1` (`ConduitMcp.Client.Config`, `ConduitMcp.Client.Hub.Config`), raising with the key name.

- **`ConduitMcp.Client`** — a `Supervisor` (`:one_for_all`) registered via `ConduitMcp.Client.Registry`: `[Task.Supervisor, transport child specs (e.g. the Finch pool), governance/grants owner, Client.Connection]`. The facade functions talk to the connection with monitor-alias requests (`ConduitMcp.Client.Request`), not `GenServer.call`; spans, deadlines and progress callbacks run in the caller.
- **`ConduitMcp.Client.Connection`** — a `:gen_statem` (`:handle_event_function`, `:state_enter`, trap_exit), one per server. States `:connecting → :discovering → :initializing → :ready`, plus `:authorizing`, `:reconnecting`, `:closed`. Boot never blocks; requests before ready are postponed. It owns the pending map (monitors callers, cancels on timeout or caller death), the era pin (`protocol: :auto` probes `server/discover`, falls back to `initialize`), the per-connection cache (`ConduitMcp.Client.Cache`) and reconnect backoff. **The connection never runs user code**: handlers, hooks, policy and progress callbacks run in tasks or in the caller. Per-state logic lives in helper modules under `client/connection/`.
- **Transports** — `ConduitMcp.Client.Transport` behaviour (state lives in the connection): `Transport.Stdio` (+ an internal port owner; `:spawn_executable`, env allowlist, EOF → TERM → KILL), `Transport.StreamableHTTP` (Finch-gated; one Exchange task per request answering the caller directly, plus a listener for the legacy GET stream / modern listen), `Transport.InProcess` (calls `Era.classify` + `Handler.dispatch/3` on a server module; tests and dev).
- **Governance** — `ConduitMcp.Client.Pipeline`, run in the caller once `:policy`/`:hooks`/`:tools`/`:validate` is set: resolve → select (`ToolFilter`) → fingerprint → pre-hooks → schema-validate (`SchemaValidator`, optional JSV) → policy (`Policy`, deny > pin > ask > allow > default) → ask (`on_ask`, `Grants`) → encode → send/MRTR → output-validate → post/failure hooks → LLM shaping. Hooks and approvers run in supervised tasks with deadlines and fail closed.
- **Hub** — `ConduitMcp.Client.Hub`, a `Supervisor` of `[token store, Task.Supervisor, DynamicSupervisor of per-server clients (restart: :temporary), Hub.Manager]`. The manager re-adds crashed servers with backoff. Tool lists are aggregated on read from each client's cache (`Client.Naming`/`Client.ToolSet`, `server__tool`); `:policy` is required. `ConduitMcp.Client.Adapters` turns tool sets and calls into Anthropic/OpenAI/Gemini shapes.
- **OAuth** — `ConduitMcp.Client.OAuth` (Finch-gated): discovery, registration (pre-registered → CIMD → DCR), code flow with host-managed `Pending`, refresh (single-flight via `TokenStore.transaction/3`), step-up, client credentials, `Loopback`. A 401 moves the connection to `:authorizing`; the token work runs in a task.

### Key Modules

- **`ConduitMcp.Server`** — Behaviour with 6 optional callbacks (`handle_list_tools/1`, `handle_call_tool/3`, `handle_list_resources/1`, `handle_read_resource/2`, `handle_list_prompts/1`, `handle_get_prompt/3`). `use ConduitMcp.Server` enables DSL mode; `use ConduitMcp.Server, dsl: false` gives manual control.

- **`ConduitMcp.Endpoint`** — Third mode: aggregates `ConduitMcp.Component` modules into a server. Uses `@before_compile` to generate all `ConduitMcp.Server` callbacks by dispatching to registered components. Carries declarative rate_limit/message_rate_limit/auth config via `__endpoint_config__/0`, auto-extracted by transports.

- **`ConduitMcp.Component`** — Behaviour for individual tool/resource/prompt modules. Each component has `execute/2` callback receiving atom-keyed params and `Plug.Conn`. Uses `ConduitMcp.Component.Schema` for field definitions. `@before_compile` generates introspection functions (`__component_type__/0`, `__component_name__/0`, `__component_schema__/0`, `__validation_schema__/0`). Tool components support `ui:` option for MCP Apps.

- **`ConduitMcp.DSL`** — Compile-time macro system. Accumulates `@mcp_tools`, `@mcp_prompts`, `@mcp_resources` module attributes via `tool`, `prompt`, `resource`, `app` macros. The `@before_compile` hook generates all callback implementations and validation schemas. Tools support `meta/1` (arbitrary `_meta` metadata), `ui/1` (shortcut for `_meta.ui.resourceUri`), and `app/2` (registers both a tool with UI and its `ui://` resource).

- **`ConduitMcp.DSL.SchemaBuilder`** — Dual schema generation: JSON Schema (for MCP client introspection) and NimbleOptions schema (for server-side runtime validation). Both are generated from the same DSL param definitions at compile time. Reused by `ConduitMcp.Component` for schema generation.

- **`ConduitMcp.DSL.Helpers`** — Response helper macros (`text/1`, `json/1`, `raw/1`, `error/1`, `image/1`, `audio/2`, `raw_resource/2`, `system/1`, `user/1`, `assistant/1`). These are macros, not functions — they expand to `{:ok, %{...}}` or `{:error, %{...}}` tuples. Imported automatically in DSL and Component modes. `raw_resource/2` returns resource content with a specified MIME type.

- **`ConduitMcp.Errors`** — Centralized JSON-RPC 2.0 and MCP error code constants. Used across all modules instead of hardcoded integers. `ConduitMcp.Protocol` delegates to this module.

- **`ConduitMcp.Handler`** — Routes JSON-RPC 2.0 requests to server module callbacks. Handles `initialize`, `ping`, `tools/*`, `resources/*`, `prompts/*`. Uses `__capabilities__/0` for selective capability advertisement when available. Emits telemetry events.

- **`ConduitMcp.Protocol`** — JSON-RPC 2.0 message construction and validation. Error code functions delegate to `ConduitMcp.Errors`.

- **`ConduitMcp.Validation`** — Runtime parameter validation using NimbleOptions. Validates tool params and prompt args. Supports type coercion (string→integer, string→boolean), custom constraints (min/max, min_length/max_length, enum), and custom validator functions.

- **`ConduitMcp.Validation.SchemaConverter`** — Converts DSL param definitions to NimbleOptions schemas. Custom constraint markers (prefixed with `__`, e.g., `__enum_values__`, `__min_value__`) are stored alongside NimbleOptions options and stripped before NimbleOptions validation.

- **`ConduitMcp.Transport.StreamableHTTP`** — Recommended transport. Single POST `/` endpoint. Uses `Plug.Router`. Also serves `GET /` (info), `GET /health` (health check).

- **`ConduitMcp.Transport.SSE`** — Legacy transport. `GET /sse` for server-to-client streaming, `POST /message` for client-to-server requests.

- **`ConduitMcp.Plugs.Auth`** — Authentication plug. Strategies: `:bearer_token`, `:api_key`, `:function` (custom). Skips CORS preflight. Authenticated user stored in `conn.assigns[:current_user]`.

- **`ConduitMcp.Plugs.RateLimit`** — Rate limiting plug using a user-supplied Hammer module. Requires `:backend` option (a module with `hit/3`). Configurable per-transport via `:rate_limit` option. Skips CORS preflight. Returns HTTP 429 with JSON-RPC error (`code: -32000`) on rejection. Supports custom `:key_func` for per-user or per-IP limiting. Emits `[:conduit_mcp, :rate_limit, :check]` telemetry. Hammer is an optional dependency.

- **`ConduitMcp.PromEx`** — Optional Prometheus metrics plugin (conditional compilation, only loads if `:prom_ex` dependency is available).

### DSL Internals

The DSL uses module attribute accumulation during compilation:
1. `tool/3`, `prompt/3`, `resource/2` macros accumulate definitions into `@mcp_tools`, `@mcp_prompts`, `@mcp_resources`
2. `@before_compile` in `ConduitMcp.DSL` triggers `SchemaBuilder` to generate JSON schemas and NimbleOptions schemas
3. Generated code includes: `handle_list_*` callbacks returning schema lists, `handle_call_tool`/`handle_get_prompt`/`handle_read_resource` with pattern-matched clauses per tool/prompt/resource, catch-all clauses for unknown names, and `__validation_schema_for_tool__/1` / `__validation_schema_for_prompt__/1` lookup functions

Handler types: `{:fn_ast, ast}` for anonymous functions/captures, `{:mfa, {module, function}}` for module function references, `{:app_view, path}` for MCP App view file handlers.

Tools can carry `_meta` metadata via the `meta/1` macro (generic map) or `ui/1` shortcut (sets `_meta.ui.resourceUri`). The `_meta` field is included in `build_tool_schema/1` output when present, with atom keys deep-converted to strings via `stringify_keys/1`.

### Test Infrastructure

- `test/support/` is compiled in the test env via `elixirc_paths(:test)` in `mix.exs` (no `Code.require_file`). Notable helpers: `test_server.ex` (`ConduitMcp.TestServer`, `dsl: false`), `telemetry_test.ex` (`ConduitMcp.TelemetryTestHelper`), `mcp_schema.ex` (`ConduitMcp.Test.McpSchema`, validates against the vendored `test/fixtures/mcp_schema/*/schema.json`), and `client/` (fake transports, scripted Bandit plugs, an OAuth fake, stdio fixtures).
- Real-socket tests start Bandit on `port: 0`, `ip: :loopback` and read the port from `ThousandIsland.listener_info/1`. They are tagged `:integration` (HTTP) or `:stdio` (child processes); neither tag is excluded, so plain `mix test` runs them.
- No `Process.sleep` in tests: tiny timeouts plus `assert_receive`.
- Test timeouts, deadlines and intervals are **≥ 200 ms** unless the timeout itself is what the test exercises (a 20 ms hook timeout in a "timed out" case is fine; a 20 ms timeout on a case that should succeed or fail for another reason flakes under load).
- Hub tests wait for readiness as the hub sees it (`await_hub_ready/3` in `test/support/client/harness.ex`, i.e. `Hub.status/1`), not a client's own `await_ready/2`: the manager marks a server running only after its client started. After killing a process, wait for its replacement — the Registry drops a dead process's entry asynchronously.

### Conventions

- All MCP response maps use **string keys** (e.g., `%{"content" => [...]}`, `%{"code" => -32000}`)
- Callbacks return `{:ok, map()}` or `{:error, map()}` tuples
- Tool params arrive as string-keyed maps; validation converts to atom keys internally then back to string keys
- Resource URI templates use `{param}` syntax (e.g., `"user://{id}"`) — `ConduitMcp.DSL.extract_uri_params/2` handles matching
- `ui://` scheme resources serve self-contained HTML for MCP Apps (e.g., `"ui://dashboard/app.html"`)
- NimbleOptions version is pinned to exactly `1.1.1`
- **Secrets** travel as `%ConduitMcp.Client.Secret{}`: `inspect` prints `#Secret<redacted>`, there is no `String.Chars`, and JSON-encoding one **raises**. Call `Secret.expose/1` only at the wire.
- Every stateful process that may hold secrets or credentials implements `format_status/1` and redacts them (connection, stdio port owner, `TokenStore.ETS`).
- ETS owners stay create-and-idle `ConduitMcp.EtsOwner` with `:public` tables, with three documented `:protected` exceptions: the OAuth `TokenStore.ETS` (only its owner writes), the client's governance/grants owner (writes via `GenServer.call`), and the client cache (written only by its connection, read directly by callers).
- Long-lived state machines use `:gen_statem` (see `Client.Connection`), split into per-state helper modules to keep credo happy.
- **The client connection process never calls user callbacks** (handler modules, `:backoff` funs, hooks, policy predicates, progress callbacks). Anything derived from user modules is precomputed at config time; user code runs in the caller or in a Task.Supervisor task.
- `ConduitMcp.Subscriptions.Admission` is the third documented `handle_call`-style coordinator (rare path, needs serialization), alongside the OAuth `TokenStore.ETS` owner and the governance/grants owner.
- Optional deps are gated with `if Code.ensure_loaded?(Dep)` plus an `OptionalDeps.*!/0` check that raises `OptionalDependencyError` **at init**, never per request.
- Telemetry: `ConduitMcp.Telemetry.events/0` is the single source of truth for every emitted event and its metadata keys; tests pin it to what the code emits, so add a new event there (and to `ConduitMcp.PromEx` where useful). Client metadata comes from an allowlist and never carries arguments, results or secrets.
- New public modules go in `mix.exs` `groups_for_modules`; new guides go in both `extras` and `groups_for_extras`. `mix docs` must stay warning-free (reference hidden modules in prose, not as backticked links; use `c:` for callbacks).

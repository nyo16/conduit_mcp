# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ConduitMCP is an Elixir library implementing the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification (version 2025-06-18). It lets developers build MCP servers that expose tools, resources, and prompts to LLM applications like Claude Desktop and VS Code. The library is published on Hex as `conduit_mcp`.

## Build & Test Commands

```bash
mix deps.get              # Install dependencies
mix compile               # Compile
mix test                  # Run all tests (~503 tests)
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

MCP server modules are **stateless** — just compiled functions. Each HTTP request runs in its own Bandit process for maximum concurrency. No supervised processes — rate limiting uses a user-supplied Hammer module.

### Request Flow

```
HTTP Request → Transport (StreamableHTTP/SSE) → Auth Plug → Rate Limit Plug → Handler → Server Module callbacks
```

### Key Modules

- **`ConduitMcp.Server`** — Behaviour with 6 optional callbacks (`handle_list_tools/1`, `handle_call_tool/3`, `handle_list_resources/1`, `handle_read_resource/2`, `handle_list_prompts/1`, `handle_get_prompt/3`). `use ConduitMcp.Server` enables DSL mode; `use ConduitMcp.Server, dsl: false` gives manual control.

- **`ConduitMcp.Endpoint`** — Third mode: aggregates `ConduitMcp.Component` modules into a server. Uses `@before_compile` to generate all `ConduitMcp.Server` callbacks by dispatching to registered components. Carries declarative rate_limit/message_rate_limit/auth config via `__endpoint_config__/0`, auto-extracted by transports.

- **`ConduitMcp.Component`** — Behaviour for individual tool/resource/prompt modules. Each component has `execute/2` callback receiving atom-keyed params and `Plug.Conn`. Uses `ConduitMcp.Component.Schema` for field definitions. `@before_compile` generates introspection functions (`__component_type__/0`, `__component_name__/0`, `__component_schema__/0`, `__validation_schema__/0`).

- **`ConduitMcp.DSL`** — Compile-time macro system. Accumulates `@mcp_tools`, `@mcp_prompts`, `@mcp_resources` module attributes via `tool`, `prompt`, `resource` macros. The `@before_compile` hook generates all callback implementations and validation schemas.

- **`ConduitMcp.DSL.SchemaBuilder`** — Dual schema generation: JSON Schema (for MCP client introspection) and NimbleOptions schema (for server-side runtime validation). Both are generated from the same DSL param definitions at compile time. Reused by `ConduitMcp.Component` for schema generation.

- **`ConduitMcp.DSL.Helpers`** — Response helper macros (`text/1`, `json/1`, `raw/1`, `error/1`, `image/1`, `audio/2`, `system/1`, `user/1`, `assistant/1`). These are macros, not functions — they expand to `{:ok, %{...}}` or `{:error, %{...}}` tuples. Imported automatically in DSL and Component modes.

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

Handler types: `{:fn_ast, ast}` for anonymous functions/captures, `{:mfa, {module, function}}` for module function references.

### Test Infrastructure

- `test/support/test_server.ex` — `ConduitMcp.TestServer` using `dsl: false` mode for testing core behavior
- `test/support/telemetry_test.ex` — `ConduitMcp.TelemetryTestHelper` for capturing telemetry events in tests
- Test helpers are loaded via `Code.require_file` in `test/test_helper.exs`

### Conventions

- All MCP response maps use **string keys** (e.g., `%{"content" => [...]}`, `%{"code" => -32000}`)
- Callbacks return `{:ok, map()}` or `{:error, map()}` tuples
- Tool params arrive as string-keyed maps; validation converts to atom keys internally then back to string keys
- Resource URI templates use `{param}` syntax (e.g., `"user://{id}"`) — `ConduitMcp.DSL.extract_uri_params/2` handles matching
- NimbleOptions version is pinned to exactly `1.1.1`

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`resources/templates/list` method** — MCP-spec-required endpoint for
  discovering URI-templated resources. Templated resources (URIs with
  `{param}` placeholders) now appear here instead of in `resources/list`.
  New optional `handle_list_resource_templates/1` Server callback.
- **`notifications/cancelled` handling** via the new
  `ConduitMcp.Cancellation` module. Tool authors poll
  `Cancellation.cancelled?(conn)` to cooperatively abort long-running
  work. Handler stashes the request id in `conn.assigns[:mcp_request_id]`
  and emits `[:conduit_mcp, :request, :cancelled]` telemetry.
- **Capability advertisement** for `completions`, `logging`, and
  `resources.subscribe` — previously these features were routed but
  never declared on `initialize`, so spec-compliant clients never used
  them.
- **Tool schema fields** `title`, `icons`, `outputSchema`, and
  `execution.taskSupport` (MCP 2025-11-25). New DSL macros: `title/1`,
  `icons/1`, `output_schema/1`, `task_support/1`.
- **Tasks JSON-RPC methods** — `tasks/get`, `tasks/cancel`,
  `tasks/result`, `tasks/list` routed to `ConduitMcp.Tasks`.
- **`task/2` DSL helper** for returning a task id from a long-running
  tool invocation.
- **`ConduitMcp.Session.Janitor`** — opt-in GenServer that periodically
  prunes expired sessions from the ETS-backed store. Add to your
  supervision tree to bound memory growth on public-facing servers.
- **`ConduitMcp.Tasks.delete/1`, `cleanup/1`, and `Tasks.Janitor`** —
  parallel cleanup for the tasks table, which previously had no
  eviction at all.
- **`examples/async_tasks_server/`** — runnable example demonstrating
  the MCP 2025-11-25 tasks lifecycle.

### Changed

- **`resources/list` now returns only static URIs.** Templated URIs
  move to `resources/templates/list` per spec. Clients that relied on
  templated URIs in `resources/list` were already non-spec-compliant.
- **`Session.Store` behaviour** gained an optional `cleanup/1` callback
  used by `Session.Janitor`. Existing stores that don't implement it
  continue to work; the janitor logs a warning and idles.

## [0.9.3] - 2026-04-18

### Fixed

- **Empty-map type warnings under Elixir 1.20** — endpoints with no scoped tools and/or no prompts no longer trigger `Map.get/2,3` "will always return default" warnings from `@before_compile`-generated `__scope_for_tool__/1` and `__convert_to_atom_keys__/2`. Replaced single-map lookups with per-component function clauses (`__scope_for_tool__(<<name>>) -> scope` and `__key_map__(<<name>>) -> escaped_map`) plus catch-all fallbacks. `mix compile --warnings-as-errors` is now clean for read-only / tool-only endpoints.

## [0.9.1] - 2026-03-24

### Performance

- **persistent_term validation config** — replaced `Application.get_env` with `:persistent_term.get` for O(1) lock-free config reads on every validated request (4–10% faster validation, 5–11% less memory)
- **Cached server capabilities** — new `ConduitMcp.ServerMeta` module lazily caches all `function_exported?` results in persistent_term, eliminating 9 repeated BIF calls per request (2–7% faster handler dispatch)
- **Pre-computed clean schemas** — `__validation_schema_for_tool__/1` now returns `{full_schema, clean_schema}` tuples pre-stripped of constraint markers at compile time, eliminating per-request `Keyword.drop`
- **Static resource URI dispatch** — resources with no `{param}` placeholders now generate direct pattern-match clauses (O(1)) instead of linear regex scan (O(n))

### Fixed

- **Atom table exhaustion** — `String.to_atom/1` in validation replaced with `String.to_existing_atom/1` to prevent atom table exhaustion from malicious parameter names

### Added

- `ConduitMcp.Validation.update_validation_config/1` — public API for updating validation config at runtime (writes both Application env and persistent_term)

## [0.9.0] - 2026-03-22

### Added

- **MCP Apps support** — first-class support for the [MCP Apps extension](https://modelcontextprotocol.io/docs/extensions/apps), enabling tools to return interactive UI components rendered as sandboxed iframes in host clients
  - `meta/1` macro — attach arbitrary `_meta` metadata to tool definitions (generic, future-proof)
  - `ui/1` macro — shortcut for declaring `_meta.ui.resourceUri` on a tool
  - `app/2` macro — convenience that registers both a tool (with `_meta.ui`) and its `ui://` HTML resource in one declaration
  - `raw_resource/2` helper — return raw content with a MIME type from resource handlers
  - Component mode `ui:` option — `use ConduitMcp.Component, type: :tool, ui: "ui://..."`
- **MCP Apps guide** — new HexDocs guide covering DSL, Component, and app macro usage with client-side build workflow
- **MCP Apps example** — `examples/mcp_apps_demo/` with a server health dashboard demonstrating the full tool → UI resource → iframe pattern

## [0.8.5] - 2026-03-22

### Changed

- **Removed Jason dependency** — replaced with Elixir 1.18+ built-in `JSON` module across all lib, test, and transport code (one fewer dependency)

### Performance

- **Pre-compiled URI template regex** — resource URI matching regex is now compiled once at compile time instead of rebuilt on every request (2.4x faster resource reads in DSL mode, 1.7x in Endpoint mode)
- **Single-pass constraint validation** — merged 4 separate schema traversals (enum, numeric, string length, custom) into a single `Enum.reduce_while` pass (1.6x faster)
- **Optimized marker removal** — replaced 11-iteration `Enum.reduce` with `Keyword.drop/2` (2.2x faster)
- **Single config fetch** — validation reads `Application.get_env` once per call instead of 3 times (1.3x faster)
- **O(1) schema lookup in type coercion** — replaced `Enum.find` per parameter with pre-built `Map` lookup

### Added

- **Benchee benchmark suite** (`mix bench`) with 6 benchmark files:
  - `uri_template_bench` — dynamic regex vs pre-compiled vs String.split
  - `validation_bench` — full pipeline, key conversion, constraint passes, marker removal, config lookups
  - `handler_bench` — method dispatch, `function_exported?` overhead, telemetry cost
  - `json_bench` — built-in JSON encode/decode at varying payload sizes
  - `protocol_bench` — request validation and response construction baseline
  - `full_request_bench` — DSL vs Manual vs Endpoint mode comparison
- **`mix bench` task** — run all benchmarks, run specific (`mix bench validation`), or list (`mix bench --list`)
- **HTML benchmark reports** generated in `bench/output/`

## [0.8.0] - 2026-03-22

### Added

- **Endpoint + Component mode** — third way to define MCP servers alongside DSL and Manual modes
  - `ConduitMcp.Component` behaviour for defining tools, resources, and prompts as individual modules
  - `ConduitMcp.Component.Schema` DSL (`schema do field ... end`) with automatic JSON Schema and NimbleOptions generation
  - `ConduitMcp.Endpoint` aggregator with `component` macro, declarative rate_limit/message_rate_limit/auth config
  - Auto-detected capabilities from registered component types
  - Compile-time validation (duplicate names, invalid modules, missing callbacks)
  - Atom-keyed params in `execute/2` for ergonomic pattern matching
- **`ConduitMcp.Errors` module** — centralized JSON-RPC 2.0 and MCP error code constants
  - `parse_error/0`, `invalid_request/0`, `method_not_found/0`, `invalid_params/0`, `internal_error/0`, `server_error/0`, `resource_not_found/0`
  - Replaces hardcoded magic numbers across the codebase
- **Transport auto-extraction** — StreamableHTTP and SSE transports auto-read endpoint config (name, version, rate_limit, auth) as fallback defaults
- **Handler capability detection** — `build_capabilities/1` uses `__capabilities__/0` when available for selective capability advertisement
- **6 new documentation guides** — choosing_a_mode, endpoint_mode, dsl_mode, manual_mode, authentication, rate_limiting

### Improved

- **Test coverage** expanded to 503 tests (up from 405)
- **README restructured** with all 3 server modes, responses reference, MCP spec coverage table
- **Error codes refactored** — `ConduitMcp.Protocol` now delegates to `ConduitMcp.Errors`

## [0.7.0] - 2026-03-21

### Added

- **MCP spec 2025-11-25 support** with backward compatibility for 2025-06-18
  - Protocol version negotiation in `initialize` (supports both versions)
  - `MCP-Protocol-Version` response header on all POST responses
  - `MCP-Session-Id` header with session creation and validation
- **Pluggable session store** (`ConduitMcp.Session.Store` behaviour)
  - Default ETS store included (`ConduitMcp.Session.EtsStore`)
  - Documentation for Redis, PostgreSQL, and Mnesia stores
- **Cursor-based pagination** via arity-2 list callbacks (backward compatible with arity-1)
- **Tool annotations DSL** (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`)
- **`_meta` field passthrough** for `progressToken` support
- **`listChanged` capability declarations**
- **Origin header validation** for DNS rebinding prevention
- **New handler methods**: `completion/complete`, `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe`
- **`audio/2` helper macro** for audio content type
- **`ConduitMcp.Tasks`** module for long-running operation state machine
- **`ConduitMcp.Client`** module for server-to-client requests (sampling, elicitation, roots)
- **OAuth 2.1 authentication** (`ConduitMcp.Plugs.OAuth`) with JWT validation
  - JWKS key provider with HTTP fetching (`ConduitMcp.OAuth.KeyProvider.JWKS`)
  - Static key provider (`ConduitMcp.OAuth.KeyProvider.Static`)
  - Resource metadata endpoint (`ConduitMcp.OAuth.ResourceMetadata`)
  - Tool-level scope enforcement
- **New error code** `-32002` (resource not found)
- **CI/CD pipeline** with compile, format, credo, test, dialyzer, and hex publish jobs
- **Configurable initialize response** (`server_name`, `server_version` via `conn.private`)

### Improved

- **Test coverage** expanded to 405 tests (up from 309)
- **Dependencies updated**: bandit 1.10.3, credo 1.7.17, ex_doc 0.40.1, telemetry 1.4.1
- **Handler refactored** to reduce cyclomatic complexity with extracted helper functions

### Fixed

- Version mismatch where handler returned hardcoded version instead of app version
- Hardcoded protocol version in transport (now uses `Protocol.protocol_version/0`)
- Flaky telemetry tests caused by async race conditions
- Flaky StreamableHTTP tests caused by shared ETS state in async mode
- Elixir 1.20 compilation warnings

## [0.6.5] - 2026-02-07

### Added

- **Message-level rate limiting** (`ConduitMcp.Plugs.MessageRateLimit`)
  - Second rate limiting layer that limits MCP method calls per time window
  - POST-only: GET/OPTIONS pass through automatically
  - Skips JSON-RPC notifications (no `id` field)
  - Configurable excluded methods (e.g., `["initialize", "ping"]`)
  - User-aware default key function (uses `conn.assigns[:current_user]` from Auth plug)
  - `"msg:"` key prefix prevents Hammer counter collision with HTTP rate limiter
  - HTTP 429 response with `Retry-After` header and JSON-RPC error (code `-32000`)
  - Telemetry event: `[:conduit_mcp, :message_rate_limit, :check]`
  - PromEx metrics: `message_rate_limit_check_total`, `message_rate_limit_check_duration_milliseconds`
  - Configurable via `:message_rate_limit` transport option
  - Works alongside existing HTTP-level rate limiting

### Improved

- **Test coverage** expanded to 309 tests
- **README** updated with Rate Limiting documentation (HTTP + message-level)
- **Telemetry** documentation updated with message rate limit events
- **PromEx** plugin updated with message rate limit metrics
- Applied `mix format` to all files in the codebase

## [0.5.0] - 2025-11-24

### Added

- **Resource URI parameter extraction** - Complete implementation
  - Extracts parameters from URI templates (e.g., `"user://{id}"` → `"user://123"` → `%{"id" => "123"}`)
  - Supports multiple parameters (e.g., `"user://{id}/posts/{post_id}"`)
  - Uses proper regex escaping with placeholder tokens
  - Returns `{:ok, params}` on match or `:no_match` otherwise
  - Full implementation in `extract_uri_params/2` (internal)
  - Resolves TODO from previous versions

- **PromEx plugin** for Prometheus monitoring
  - Optional integration via `{:prom_ex, "~> 1.11", optional: true}`
  - Conditional compilation (only loads if PromEx available)
  - 10 production-ready metrics (5 counters + 5 histograms)
  - Monitors all ConduitMCP operations: requests, tools, resources, prompts, auth
  - Optimized histogram buckets per operation type
  - Low cardinality design with string normalization
  - Comprehensive documentation with PromQL query examples
  - Alert rule examples included
  - Zero runtime overhead when not enabled

### Improved

- **Test coverage** expanded significantly
  - 33 new tests added (21 for core features, 12 for PromEx)
  - Resource URI parameter extraction: 11 new tests
  - Prompt functionality: 4 new tests
  - Tool functionality: 6 new tests
  - PromEx plugin: 12 new tests
  - **Total: 229 tests, all passing**

- **Documentation** enhanced
  - Added comprehensive Prometheus Metrics section to README
  - 190+ lines of PromEx plugin documentation
  - PromQL query cookbook with examples
  - Alert rule templates
  - Complete metric reference

### Fixed

- Version consistency across all files (updated from 0.4.6 to 0.4.7, now 0.5.0)
- Removed repository artifacts:
  - Deleted `erl_crash.dump` (4.9 MB)
  - Deleted `conduit_mcp-0.4.0.tar` and `conduit_mcp-0.4.6.tar`
- Updated test badge count (193 → 229 passing)

### Breaking Changes

None - This release is fully backward compatible.

## [0.4.7] - 2025-11-19

### Added
- **`raw/1` helper macro** for direct JSON output without MCP content wrapping
  - Bypasses standard MCP content structure for debugging purposes
  - Returns `{:ok, data}` directly instead of wrapped content array
  - Supports maps, strings, lists, and all data types
  - Includes comprehensive documentation with MCP compatibility warnings
  - Full test coverage with 3 test cases

### Documentation
- Updated README.md helper functions list to include `raw/1`
- Added detailed module documentation with usage examples and warnings

## [0.4.6] - 2025-01-16

### Changed
- Streamlined README and CHANGELOG for clarity
- Focused documentation on essential features
- Reduced README by 53% (634 → 298 lines)
- Reduced CHANGELOG by 48% (190 → 99 lines)

### Improved
- README now highlights DSL as primary approach
- Removed outdated migration guides
- Cleaner examples and better organization
- Added version and test badges

## [0.4.5] - 2025-01-16

### Added
- **Clean DSL for defining MCP servers**
  - `tool`, `prompt`, `resource` macros for declarative definitions
  - Automatic JSON Schema generation from parameters
  - Helper functions: `text()`, `json()`, `error()`, `system()`, `user()`, `assistant()`
  - Support for inline functions, MFA handlers, and function captures
  - Parameter features: enums, defaults, required fields, type validation
- **Flexible authentication system**
  - `ConduitMcp.Plugs.Auth` with 5 strategies
  - Bearer token, API key, custom function, MFA, database lookup
  - CORS preflight bypass, configurable assign key
  - Case-insensitive bearer token support
- **Extended telemetry**
  - `[:conduit_mcp, :resource, :read]` - Resource operations
  - `[:conduit_mcp, :prompt, :get]` - Prompt operations
  - `[:conduit_mcp, :auth, :verify]` - Authentication
  - Complete observability for all MCP operations

### Changed
- Examples updated to use DSL (simple_tools_server, phoenix_mcp)
- Transport modules support `:auth` option
- Auth configured per-transport (no separate pipeline needed)
- Documentation streamlined to focus on DSL

### Tests
- 36 DSL tests (tools, prompts, resources, helpers, schema builder)
- 26 auth plug tests (all strategies, error handling, CORS)
- 16 telemetry tests
- 193 total tests, all passing

## [0.4.0] - 2025-01-16

### Changed (Breaking)
- **Pure stateless architecture**
  - Removed GenServer and Agent - zero process overhead
  - Server is just a module with pure functions
  - No supervision tree required
  - Maximum concurrency (limited only by Bandit)
- **Simplified callback API**
  - Removed `mcp_init/1`
  - Changed `{:reply, result, state}` → `{:ok, result}`
  - Callbacks receive `conn` (Plug.Conn) as first parameter
  - No more state passing/returning
  - Error maps use string keys
- **Handler updates**
  - Calls module functions directly (no GenServer.call)
  - Transport layers pass Plug.Conn for request context

### Performance
- Zero process overhead - pure function calls
- Full concurrent request processing
- No serialization bottleneck

## [0.3.0] - 2025-10-28

### Added
- Comprehensive test suite (109 tests, 82% coverage)
- Test infrastructure (TestServer, TelemetryTestHelper)
- ExCoveralls integration

### Changed
- Simplified and professionalized README

## [0.2.0] - 2025-10-09

### Added
- Telemetry events (`[:conduit_mcp, :request, :stop]`, `[:conduit_mcp, :tool, :execute]`)
- Configurable CORS headers
- Enhanced logging

### Fixed
- SSE buffering with nginx proxies

## [0.1.0] - 2025-10-08

### Added
- Initial release
- MCP specification 2025-06-18 implementation
- `ConduitMcp.Server` behaviour
- StreamableHTTP and SSE transports
- Tools, resources, and prompts support
- Basic authentication
- Phoenix integration example

[0.8.5]: https://github.com/nyo16/conduit_mcp/compare/v0.8.0...v0.8.5
[0.8.0]: https://github.com/nyo16/conduit_mcp/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/nyo16/conduit_mcp/compare/v0.6.5...v0.7.0
[0.6.5]: https://github.com/nyo16/conduit_mcp/compare/v0.5.0...v0.6.5
[0.4.6]: https://github.com/nyo16/conduit_mcp/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/nyo16/conduit_mcp/compare/v0.4.0...v0.4.5
[0.4.0]: https://github.com/nyo16/conduit_mcp/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/nyo16/conduit_mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nyo16/conduit_mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

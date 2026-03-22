# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.7.0]: https://github.com/nyo16/conduit_mcp/compare/v0.6.5...v0.7.0
[0.6.5]: https://github.com/nyo16/conduit_mcp/compare/v0.5.0...v0.6.5
[0.4.6]: https://github.com/nyo16/conduit_mcp/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/nyo16/conduit_mcp/compare/v0.4.0...v0.4.5
[0.4.0]: https://github.com/nyo16/conduit_mcp/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/nyo16/conduit_mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nyo16/conduit_mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

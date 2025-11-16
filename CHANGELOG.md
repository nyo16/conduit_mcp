# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.4.5]: https://github.com/nyo16/conduit_mcp/compare/v0.4.0...v0.4.5
[0.4.0]: https://github.com/nyo16/conduit_mcp/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/nyo16/conduit_mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nyo16/conduit_mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2025-01-16

### Changed (Breaking)
- **Pure stateless architecture - just compiled functions!**
  - Removed GenServer and Agent - no process overhead at all
  - Server is now just a module with pure functions
  - No supervision tree required
  - Each HTTP request runs in parallel (limited only by Bandit's process pool)
- **Simplified callback API**
  - Removed `mcp_init/1` - use module attributes instead (e.g., `@tools`)
  - Changed `{:reply, result, state}` to `{:ok, result}`
  - Changed `{:error, error, state}` to `{:error, error}`
  - Callbacks now receive `conn` (Plug.Conn) as first parameter for request context
  - No more state passing/returning in callbacks
  - Removed `terminate/2` callback (no longer needed)
  - Parameter order changed: callbacks now receive `conn` first
- **Error format standardization**
  - Error maps now use string keys: `%{"code" => ..., "message" => ...}`
  - Previously used atom keys: `%{code: ..., message: ...}`
- **Handler changes**
  - Handler calls module functions directly with conn parameter
  - Transport layers pass Plug.Conn to handler for request context

### Added
- Comprehensive migration guide in README with before/after examples
- Documentation on handling mutable state with ETS, Agent, or databases
- Examples of using connection context for authentication
- Performance benefits documentation
- Connection context access in all callbacks

### Upgraded
- All examples updated to pure stateless API
  - `examples/simple_tools_server/` - uses module attributes
  - `examples/phoenix_mcp/` - uses module attributes
- All tests updated and passing (104 tests)
  - Tests now fully async (no process dependencies)
  - Handler tests
  - Transport tests (StreamableHTTP and SSE)

### Migration Guide
See README.md for detailed migration instructions from v0.3.x to v0.4.0

### Performance
- Eliminated all process overhead - pure function calls
- Request processing fully concurrent with zero serialization
- Improved throughput for high-concurrency scenarios
- Compile-time optimization of module attributes

## [0.3.0] - 2025-10-28

### Added
- Comprehensive test suite with 109 tests across all modules
  - Protocol module tests (100% coverage)
  - Handler module tests with telemetry validation
  - Server behavior tests with lifecycle testing
  - StreamableHTTP transport tests (93.5% coverage)
  - SSE transport tests (85.4% coverage)
- Test infrastructure
  - TestServer for testing MCP server behavior
  - TelemetryTestHelper for validating telemetry events
- Test coverage reporting via ExCoveralls
  - Overall coverage: 82.1%
  - Configured coverage tooling in mix.exs
- Production-ready testing infrastructure

### Changed
- Simplified README for better clarity and professionalism
  - Removed emoticons and verbose sections
  - Added installation instructions at top
  - Featured Phoenix integration example prominently
  - More concise and professional documentation
- Improved test organization with proper fixtures and helpers

### Documentation
- Streamlined README from 300+ to ~230 lines
- Improved example clarity
- Better separation of concerns in documentation

## [0.2.0] - 2025-10-09

### Added
- Comprehensive telemetry events for monitoring and metrics
  - `[:conduit_mcp, :request, :stop]` - All MCP requests with duration and status
  - `[:conduit_mcp, :tool, :execute]` - Tool executions with duration and outcome
- Enhanced logging throughout request handling
- `x-accel-buffering: no` header to SSE transport for nginx proxy compatibility
- Configurable CORS headers on both transports (origin, methods, headers)
- Examples for Resources and Prompts in README
- Documentation for all telemetry events

### Changed
- Improved error handling and logging in request handler
- Better error messages with context
- Updated server version reporting to 0.2.0

### Fixed
- SSE buffering issues with nginx proxies

## [0.1.0] - 2025-10-08

### Added
- Initial release of ConduitMCP
- Core MCP protocol implementation (specification version 2025-06-18)
- `ConduitMcp.Server` behaviour for building MCP servers
- `ConduitMcp.Protocol` module with JSON-RPC 2.0 support
- `ConduitMcp.Handler` for request routing
- `ConduitMcp.Transport.StreamableHTTP` - Modern HTTP transport
- `ConduitMcp.Transport.SSE` - Server-Sent Events transport
- Configurable CORS headers on both transports
- Support for Tools primitive (list and call)
- Basic support for Resources and Prompts primitives
- Example: Simple standalone MCP server with echo and reverse_string tools
- Example: Phoenix integration showing MCP embedded in Phoenix router
- Configurable bearer token authentication plug for Phoenix
- Comprehensive documentation and testing guides
- Test scripts for validation

### Features
- MCP specification 2025-06-18 compliance
- Dual transport support (Streamable HTTP and SSE)
- GenServer-based server implementation
- CORS configuration per transport
- Authentication plug with multiple strategies
- Phoenix router integration support
- Working examples with documentation

### Documentation
- README with quick start guide
- Implementation guide based on MCP specification
- Example server READMEs with curl examples
- VS Code/Cursor integration guide
- Phoenix integration documentation

[0.4.0]: https://github.com/nyo16/conduit_mcp/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/nyo16/conduit_mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nyo16/conduit_mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

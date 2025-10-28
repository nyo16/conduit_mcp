# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.3.0]: https://github.com/nyo16/conduit_mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nyo16/conduit_mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

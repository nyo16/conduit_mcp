# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

defmodule ConduitMcp do
  @moduledoc """
  ConduitMCP - Elixir implementation of the Model Context Protocol (MCP).

  ConduitMCP provides a framework for building MCP servers that expose tools,
  resources, and prompts to LLM applications. The library implements the MCP
  specification version 2025-06-18 with support for both modern Streamable HTTP
  and legacy SSE transports.

  ## Quick Example

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server

        @tools [
          %{
            "name" => "greet",
            "description" => "Greet someone",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"}
              },
              "required" => ["name"]
            }
          }
        ]

        @impl true
        def handle_list_tools(_conn) do
          {:ok, %{"tools" => @tools}}
        end

        @impl true
        def handle_call_tool(_conn, "greet", %{"name" => name}) do
          {:ok, %{
            "content" => [
              %{"type" => "text", "text" => "Hello, \#{name}!"}
            ]
          }}
        end
      end

  ## Core Modules

  - `ConduitMcp.Protocol` - JSON-RPC 2.0 and MCP message types
  - `ConduitMcp.Server` - Behaviour for implementing MCP servers
  - `ConduitMcp.Handler` - Request routing and method dispatch
  - `ConduitMcp.Transport.StreamableHTTP` - Modern HTTP transport
  - `ConduitMcp.Transport.SSE` - Server-Sent Events transport

  ## Transport Options

  ### Streamable HTTP (Recommended)

      children = [
        # No need to start the server module - it's just functions!
        {Bandit,
         plug: {ConduitMcp.Transport.StreamableHTTP,
                server_module: MyApp.MCPServer},
         port: 4000}
      ]

  ### SSE (Legacy)

      children = [
        # No need to start the server module - it's just functions!
        {Bandit,
         plug: {ConduitMcp.Transport.SSE,
                server_module: MyApp.MCPServer},
         port: 4000}
      ]

  ## Examples

  See the `examples/` directory for complete working examples:

  - `examples/simple_tools_server/` - Standalone MCP server
  - `examples/phoenix_mcp/` - Phoenix integration

  ## Resources

  - [MCP Specification](https://modelcontextprotocol.io/specification/)
  - [GitHub Repository](https://github.com/nyo16/conduit_mcp)
  - [Changelog](CHANGELOG.md)
  """

  @doc """
  Returns the MCP protocol version supported by this library.
  """
  def protocol_version, do: ConduitMcp.Protocol.protocol_version()
end

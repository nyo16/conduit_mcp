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

        @impl true
        def mcp_init(_opts) do
          config = %{
            tools: [
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
          }
          {:ok, config}
        end

        @impl true
        def handle_list_tools(config) do
          {:ok, %{"tools" => config.tools}}
        end

        @impl true
        def handle_call_tool("greet", %{"name" => name}, _config) do
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
        {MyApp.MCPServer, []},
        {Bandit,
         plug: {ConduitMcp.Transport.StreamableHTTP,
                server_module: MyApp.MCPServer},
         port: 4000}
      ]

  ### SSE (Legacy)

      children = [
        {MyApp.MCPServer, []},
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

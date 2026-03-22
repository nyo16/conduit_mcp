defmodule ConduitMcp do
  @moduledoc """
  ConduitMCP - Elixir implementation of the Model Context Protocol (MCP).

  ConduitMCP provides a framework for building MCP servers that expose tools,
  resources, and prompts to LLM applications. The library implements the MCP
  specification version 2025-11-25 with support for both modern Streamable HTTP
  and legacy SSE transports.

  ## Three Ways to Build

  **DSL Mode** — declarative macros, everything in one module:

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server

        tool "greet", "Greet someone" do
          param :name, :string, "Name", required: true
          handle fn _conn, %{"name" => name} -> text("Hello, \#{name}!") end
        end
      end

  **Manual Mode** — raw callbacks with full control:

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server, dsl: false

        @impl true
        def handle_list_tools(_conn), do: {:ok, %{"tools" => [...]}}

        @impl true
        def handle_call_tool(_conn, "greet", %{"name" => name}), do: ...
      end

  **Endpoint + Component Mode** — each tool as its own module:

      defmodule MyApp.Greet do
        use ConduitMcp.Component, type: :tool, description: "Greet someone"

        schema do
          field :name, :string, "Name", required: true
        end

        @impl true
        def execute(%{name: name}, _conn), do: text("Hello, \#{name}!")
      end

      defmodule MyApp.MCPServer do
        use ConduitMcp.Endpoint, name: "My App", version: "1.0.0"
        component MyApp.Greet
      end

  ## Core Modules

  - `ConduitMcp.Server` - Behaviour for DSL and manual mode servers
  - `ConduitMcp.Endpoint` - Aggregates component modules into a server
  - `ConduitMcp.Component` - Behaviour for individual tool/resource/prompt modules
  - `ConduitMcp.Protocol` - JSON-RPC 2.0 and MCP message types
  - `ConduitMcp.Handler` - Request routing and method dispatch
  - `ConduitMcp.Errors` - Standard JSON-RPC and MCP error codes
  - `ConduitMcp.Transport.StreamableHTTP` - Modern HTTP transport (recommended)
  - `ConduitMcp.Transport.SSE` - Server-Sent Events transport (legacy)

  ## Running a Server

      children = [
        {Bandit,
         plug: {ConduitMcp.Transport.StreamableHTTP,
                server_module: MyApp.MCPServer},
         port: 4000}
      ]

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

defmodule ConduitMcp do
  @moduledoc """
  ConduitMCP - Elixir implementation of the Model Context Protocol (MCP).

  ConduitMCP provides a framework for building MCP servers that expose tools,
  resources, and prompts to LLM applications, and a client for connecting to
  MCP servers. Both are dual-era:

    * **Modern, `2026-07-28`** — stateless per-request `_meta`,
      `server/discover`, multi round-trip requests (`ConduitMcp.MRTR`),
      `subscriptions/listen`, streamed responses, cache hints and `Mcp-*`
      header validation.
    * **Legacy, `2025-11-25` and `2025-06-18`** — `initialize` negotiation,
      sessions, `tasks/*`.

  A server answers both eras from the same callbacks; the era is classified
  per request (`ConduitMcp.Era`). Transports: Streamable HTTP (both eras) and
  the legacy SSE transport. See the "Protocol eras" guide.

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
  - `ConduitMcp.Subscriptions` - `subscriptions/listen` streams and change
    notifications
  - `ConduitMcp.MRTR` / `ConduitMcp.Notifications` - input-request and
    notification payload builders
  - `ConduitMcp.Client` - the MCP client (one server); `ConduitMcp.Client.Hub`
    puts many servers behind one governed tool list

  ## Connecting to a server

      children = [
        {ConduitMcp.Client,
         name: MyApp.Files,
         transport: {ConduitMcp.Client.Transport.Stdio, command: "mcp-fs"}}
      ]

      {:ok, result} = ConduitMcp.Client.call_tool(MyApp.Files, "read_file", %{"path" => "a.txt"})

  See the client guides for transports, the hub, policy and hooks, LLM
  adapters and OAuth.

  ## Change notifications

  A `2026-07-28` client receives list-changed and resource-updated
  notifications on the `subscriptions/listen` streams it opens. Push them
  from anywhere in your application:

      ConduitMcp.notify_tools_changed()
      ConduitMcp.notify_resource_updated("file:///project/config.json")

  Each reaches only the streams this node serves whose filter asked for
  it. On a cluster, broadcast the change on your own PubSub and call the
  function on every node (see `ConduitMcp.Subscriptions`).

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
  Returns the preferred legacy protocol version, `"2025-11-25"`: the
  `mcp-protocol-version` a legacy response carries when no version was
  negotiated or requested.

  The library serves more than this one version. Every supported version is
  `ConduitMcp.Protocol.supported_versions/0` (`"2026-07-28"`, `"2025-11-25"`,
  `"2025-06-18"`), split by era into `ConduitMcp.Protocol.modern_versions/0`
  and `ConduitMcp.Protocol.legacy_versions/0`.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: ConduitMcp.Protocol.protocol_version()

  @doc """
  Sends `notifications/tools/list_changed` to every `subscriptions/listen`
  stream on this node whose filter set `toolsListChanged`.

  Node-local: on a cluster, call it on every node (see
  `ConduitMcp.Subscriptions`).
  """
  @spec notify_tools_changed() :: :ok
  defdelegate notify_tools_changed, to: ConduitMcp.Subscriptions

  @doc """
  Sends `notifications/prompts/list_changed` to every `subscriptions/listen`
  stream on this node whose filter set `promptsListChanged`.

  Node-local: on a cluster, call it on every node (see
  `ConduitMcp.Subscriptions`).
  """
  @spec notify_prompts_changed() :: :ok
  defdelegate notify_prompts_changed, to: ConduitMcp.Subscriptions

  @doc """
  Sends `notifications/resources/list_changed` to every
  `subscriptions/listen` stream on this node whose filter set
  `resourcesListChanged`.

  Node-local: on a cluster, call it on every node (see
  `ConduitMcp.Subscriptions`).
  """
  @spec notify_resources_changed() :: :ok
  defdelegate notify_resources_changed, to: ConduitMcp.Subscriptions

  @doc """
  Sends `notifications/resources/updated` for `uri` to every
  `subscriptions/listen` stream on this node whose `resourceSubscriptions`
  named exactly `uri` (and that was authorized to read it when it opened).

  Node-local: on a cluster, call it on every node (see
  `ConduitMcp.Subscriptions`).
  """
  @spec notify_resource_updated(String.t()) :: :ok
  defdelegate notify_resource_updated(uri), to: ConduitMcp.Subscriptions
end

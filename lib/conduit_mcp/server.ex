defmodule ConduitMcp.Server do
  @moduledoc """
  Behaviour for implementing stateless MCP servers.

  An MCP server provides tools, resources, and prompts to LLM clients.
  Servers implement callbacks to handle client requests concurrently.

  ## Architecture

  Server modules are stateless — just pure compiled functions:

  - No GenServer, no Agent, no process overhead in *your* module
  - Nothing for you to add to your supervision tree for the server itself
  - Callbacks receive the `Plug.Conn` for request context
  - Each HTTP request runs in parallel (limited only by Bandit's process pool)

  The library does run a small supervision tree of its own
  (`ConduitMcp.Application`). It starts automatically with the `:conduit_mcp`
  application and owns the long-lived ETS tables that must outlive request
  processes, plus the janitors that sweep them:

  - `ConduitMcp.Cancellation.Owner` — cancellation flags
  - `ConduitMcp.Cancellation.InFlightOwner` — requests in flight, which gate
    the cancellations recorded
  - `ConduitMcp.Session.EtsStore.Owner` — sessions
  - `ConduitMcp.Transport.SSE.Owner` — the SSE slot table (one row per live
    stream)
  - `ConduitMcp.Transport.SSEStream.Owner` — the slot table of streamed POST
    responses (one row per open stream)
  - `ConduitMcp.Client.Registry` — a passive `Registry` client processes
    register in (it starts no client)
  - `ConduitMcp.Subscriptions` — the `Registry` of `subscriptions/listen`
    streams by topic
  - `ConduitMcp.Subscriptions.Admission` — the live `subscriptions/listen`
    streams of each principal (`:max_listens_per_principal`); a process
    streams call once per listen, not an ETS owner
  - `ConduitMcp.Session.Janitor` (as `ConduitMcp.Session.Janitor.Default`) —
    sweeps expired sessions; disable with
    `config :conduit_mcp, :session_janitor, false`
  - `ConduitMcp.Cancellation.Janitor` — sweeps stale cancellation rows and
    in-flight rows of dead processes; disable with
    `config :conduit_mcp, :cancellation_janitor, false`
  - `ConduitMcp.Tasks.EtsStore.Owner` — tasks, only with the default tasks
    store
  - `ConduitMcp.Ext.Tasks.EtsStore.Owner` and the `ConduitMcp.Ext.Tasks.Janitor`
    — only when the experimental tasks extension is enabled
    (`config :conduit_mcp, :ext_tasks`)
  - `ConduitMcp.OAuth.KeyProvider.JWKS.Owner` — the JWKS cache, only when
    `Req` is compiled in

  Every owner is a `ConduitMcp.EtsOwner` process that creates a `:public`
  table and idles; reads and writes go straight to ETS from the calling
  process. See `ConduitMcp.Application` for configuration details.

  ## Example (Using DSL - Recommended)

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server

        tool "echo", "Echo back the input" do
          param :message, :string, "Message to echo", required: true

          handle fn _conn, %{"message" => msg} ->
            text(msg)
          end
        end

        tool "calculate", "Perform calculations" do
          param :operation, :string, "Math operation", enum: ~w(add sub mul div), required: true
          param :a, :number, "First number", required: true
          param :b, :number, "Second number", required: true

          handle MyMath, :calculate
        end
      end

  ## Example (Manual - Advanced)

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server, dsl: false  # Disable DSL

        @tools [
          %{
            "name" => "echo",
            "description" => "Echo back the input",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{"type" => "string", "description" => "Message to echo"}
              },
              "required" => ["message"]
            }
          }
        ]

        @impl true
        def handle_list_tools(_conn) do
          {:ok, %{"tools" => @tools}}
        end

        @impl true
        def handle_call_tool(_conn, "echo", %{"message" => msg}) do
          {:ok, %{"content" => [%{"type" => "text", "text" => msg}]}}
        end
      end

  Then in your supervision tree, just pass the module:

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
       port: 4001}

  ## Using Connection Context

  The `conn` parameter allows access to request metadata:

      def handle_call_tool(conn, "private_data", _params) do
        # Check authentication
        user_id = conn.assigns[:user_id]

        # Access headers
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, %{"content" => [%{"type" => "text", "text" => "Data for \#{user_id}"}]}}
      end

  ## Mutable State

  If you need mutable state, use external mechanisms:

      # Option 1: ETS
      def handle_call_tool(_conn, "increment", _params) do
        :ets.update_counter(:my_counter, :count, 1)
        count = :ets.lookup_element(:my_counter, :count, 2)
        {:ok, %{"content" => [%{"type" => "text", "text" => "Count: \#{count}"}]}}
      end

      # Option 2: Agent/GenServer
      def handle_call_tool(_conn, "get_cache", %{"key" => key}) do
        value = MyApp.Cache.get(key)
        {:ok, %{"content" => [%{"type" => "text", "text" => value}]}}
      end

  ## Multi round-trip requests (MRTR)

  In MCP `2026-07-28` a server asks the client for input — an elicitation,
  and the deprecated sampling and roots — by answering `tools/call`,
  `resources/read` or `prompts/get` with an `InputRequiredResult`; the
  client retries the same request with the answers. Return
  `{:input_required, input_requests, state}` from `handle_call_tool/3`,
  `handle_read_resource/2` or `handle_get_prompt/3` (or a DSL handler or
  `c:ConduitMcp.Component.execute/2` behind them):

      def handle_call_tool(conn, "deploy", args) do
        case conn.assigns[:mcp_input] do
          nil ->
            {:input_required,
             %{"approval" => ConduitMcp.MRTR.elicit("Approve deploy?", schema)},
             %{step: :awaiting_approval, target: args["target"]}}

          %{state: %{"target" => target}, responses: %{"approval" => approval}} ->
            case approval do
              %{"action" => "accept"} -> {:ok, do_deploy(target)}
              _ -> {:ok, %{"content" => [%{"type" => "text", "text" => "Cancelled"}]}}
            end
        end
      end

  * `input_requests` maps server-chosen keys to input requests built with
    `ConduitMcp.MRTR.elicit/2` (or the deprecated `sample/2` and
    `list_roots/0`). Every request is checked against the capabilities the
    client declared; a missing one is answered with `-32021` and
    `data.requiredCapabilities` (HTTP 400) instead.
  * `state` is sealed into the result's `requestState` with
    `ConduitMcp.MRTR.State` (configure `:mrtr_keys`; without them the
    request fails with `-32603` and an error log). It must be JSON-encodable
    and comes back as decoded JSON: atom keys and values become strings.

  On the retry the library opens `requestState` (bound to the protocol
  version, method, salient params and `ConduitMcp.Principal.id/1`; any
  failure is a flat `-32602`) **before** the callback runs, and puts
  `%{state: restored_state, responses: input_responses}` in
  `conn.assigns[:mcp_input]`, where `input_responses` is the request's
  `inputResponses` map (`%{}` when absent). `conn.assigns[:mcp_input]` is
  absent on a first round. `responses` is client input: validate it like
  any other argument. A callback may return `{:input_required, ...}` again
  for another round.

  MRTR exists only in the modern era: on a legacy-era request
  (`2025-11-25`, `2025-06-18`) the same return is logged and answered with
  `-32603` ("MRTR input requests require protocol 2026-07-28"). Telemetry:
  `[:conduit_mcp, :mrtr, :input_required]` (see `ConduitMcp.Telemetry`).
  """

  @type conn :: Plug.Conn.t()
  @type tool_name :: String.t()
  @type tool_params :: map()
  @type uri :: String.t()
  @type prompt_name :: String.t()
  @type prompt_args :: map()

  @typedoc """
  An MRTR request for client input: input requests keyed by server-chosen
  ids (values built with `ConduitMcp.MRTR`), and a JSON-encodable state term
  handed back in `conn.assigns[:mcp_input]` on the retry.
  """
  @type input_required ::
          {:input_required, input_requests :: %{optional(String.t()) => map()}, state :: term()}

  @typedoc """
  A `ConduitMcp.Ext.Tasks` task request from `handle_call_tool/3`: create a
  task and answer with a `CreateTaskResult` (modern era, extension enabled
  and declared by the client). See `ConduitMcp.Ext.Tasks` for `attrs`.
  """
  @type task :: {:task, attrs :: keyword() | map()}

  @doc """
  Handle listing available tools.

  The arity-2 variant receives request params (e.g., `%{"cursor" => "..."}`)
  for pagination support. Implement arity-2 to support cursor-based pagination.
  """
  @callback handle_list_tools(conn()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}
  @callback handle_list_tools(conn(), params :: map()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}

  @doc """
  Handle tool execution.

  May return `{:input_required, input_requests, state}` on a modern-era
  request; see "Multi round-trip requests (MRTR)" in the moduledoc. May
  return `{:task, attrs}` to run as a task (`ConduitMcp.Ext.Tasks`).
  """
  @callback handle_call_tool(conn(), tool_name(), tool_params()) ::
              {:ok, result :: map()} | {:error, error :: map()} | input_required() | task()

  @doc """
  Handle listing available resources.

  The arity-2 variant receives request params for pagination support.
  """
  @callback handle_list_resources(conn()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}
  @callback handle_list_resources(conn(), params :: map()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}

  @doc """
  Handle reading a resource.

  May return `{:input_required, input_requests, state}` on a modern-era
  request; see "Multi round-trip requests (MRTR)" in the moduledoc.
  """
  @callback handle_read_resource(conn(), uri()) ::
              {:ok, content :: map()} | {:error, error :: map()} | input_required()

  @doc """
  Handle listing available prompts.

  The arity-2 variant receives request params for pagination support.
  """
  @callback handle_list_prompts(conn()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}
  @callback handle_list_prompts(conn(), params :: map()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}

  @doc """
  Handle getting a prompt.

  May return `{:input_required, input_requests, state}` on a modern-era
  request; see "Multi round-trip requests (MRTR)" in the moduledoc.
  """
  @callback handle_get_prompt(conn(), prompt_name(), prompt_args()) ::
              {:ok, messages :: map()} | {:error, error :: map()} | input_required()

  @doc """
  Handle autocompletion for prompt arguments or resource template parameters.

  Receives the reference type (`:prompt` or `:resource`), the reference name,
  the argument/parameter name, and the partial value typed so far.

  Should return `{:ok, %{"completion" => %{"values" => [...], "hasMore" => false}}}`.
  """
  @callback handle_complete(conn(), ref :: map(), argument :: map()) ::
              {:ok, map()} | {:error, map()}

  @doc """
  Handle setting the log level for server-to-client logging.

  Receives the desired log level as a string (e.g., "debug", "info", "warning", "error").
  """
  @callback handle_set_log_level(conn(), level :: String.t()) ::
              {:ok, map()} | {:error, map()}

  @doc """
  Handle subscribing to resource changes.

  Receives the resource URI to subscribe to.
  """
  @callback handle_subscribe_resource(conn(), uri()) ::
              {:ok, map()} | {:error, map()}

  @doc """
  Handle unsubscribing from resource changes.

  Receives the resource URI to unsubscribe from.
  """
  @callback handle_unsubscribe_resource(conn(), uri()) ::
              {:ok, map()} | {:error, map()}

  @doc """
  Handle listing resource templates (resources with `{param}` placeholders).

  Returns a map with `"resourceTemplates"` key containing a list of template
  descriptors, each with at least `"uriTemplate"`.

  Implemented automatically by DSL and Endpoint modes; manual-mode servers
  can implement this to advertise URI templates to clients.
  """
  @callback handle_list_resource_templates(conn()) ::
              {:ok, %{required(String.t()) => list(map())}} | {:error, map()}

  @optional_callbacks [
    handle_list_tools: 1,
    handle_list_tools: 2,
    handle_call_tool: 3,
    handle_list_resources: 1,
    handle_list_resources: 2,
    handle_list_resource_templates: 1,
    handle_read_resource: 2,
    handle_list_prompts: 1,
    handle_list_prompts: 2,
    handle_get_prompt: 3,
    handle_complete: 3,
    handle_set_log_level: 2,
    handle_subscribe_resource: 2,
    handle_unsubscribe_resource: 2
  ]

  @doc """
  Declares the module a `ConduitMcp.Server`.

  Options:

    * `:dsl` — `true` (default) enables the `ConduitMcp.DSL` macros; `false`
      is manual mode, with default callbacks you override.
    * `:instructions` — natural-language guidance for clients about this
      server, returned as `instructions` by both the legacy `initialize`
      result and the modern `server/discover` result. Generates
      `__instructions__/0`. A transport's own `:instructions` option takes
      precedence.

  ## Example

      use ConduitMcp.Server, instructions: "Use search before fetch."
  """
  defmacro __using__(opts) do
    use_dsl = Keyword.get(opts, :dsl, true)

    instructions =
      if Keyword.has_key?(opts, :instructions) do
        quote do
          @doc false
          def __instructions__, do: unquote(Keyword.fetch!(opts, :instructions))
        end
      end

    if use_dsl do
      quote do
        @behaviour ConduitMcp.Server
        use ConduitMcp.DSL

        unquote(instructions)
      end
    else
      quote do
        @behaviour ConduitMcp.Server

        unquote(instructions)

        # Default implementations for manual mode
        def handle_list_tools(_conn) do
          {:ok, %{"tools" => []}}
        end

        # Codes match `ConduitMcp.Handler`, Endpoint mode and DSL mode, so an
        # identical MCP request gets an identical error whichever mode the
        # server was written in. `-32602` for an unknown tool/prompt and the
        # legacy `-32002` for a missing resource are what the MCP specification
        # prescribes; `ConduitMcp.Protocol.Modern` turns the latter into
        # `-32602` for modern clients.
        def handle_call_tool(_conn, name, _params) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.invalid_params(),
             "message" => "Unknown tool: #{ConduitMcp.Reflect.text(name)}"
           }}
        end

        def handle_list_resources(_conn) do
          {:ok, %{"resources" => []}}
        end

        def handle_read_resource(_conn, uri) do
          {:error,
           %{
             "code" => ConduitMcp.Protocol.Legacy.resource_not_found(),
             "message" => "Resource not found: #{ConduitMcp.Reflect.text(uri)}"
           }}
        end

        def handle_list_prompts(_conn) do
          {:ok, %{"prompts" => []}}
        end

        def handle_get_prompt(_conn, name, _args) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.invalid_params(),
             "message" => "Unknown prompt: #{ConduitMcp.Reflect.text(name)}"
           }}
        end

        defoverridable handle_list_tools: 1,
                       handle_call_tool: 3,
                       handle_list_resources: 1,
                       handle_read_resource: 2,
                       handle_list_prompts: 1,
                       handle_get_prompt: 3
      end
    end
  end
end

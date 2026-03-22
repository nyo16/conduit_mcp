defmodule ConduitMcp.Server do
  @moduledoc """
  Behaviour for implementing stateless MCP servers.

  An MCP server provides tools, resources, and prompts to LLM clients.
  Servers implement callbacks to handle client requests concurrently.

  ## Changes in v0.4.0

  The server is now fully stateless - just pure compiled functions:
  - No GenServer, no Agent, no process overhead
  - No supervision tree required
  - Callbacks receive the Plug.Conn for request context
  - Each HTTP request runs in parallel (limited only by Bandit's process pool)

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
  """

  @type conn :: Plug.Conn.t()
  @type tool_name :: String.t()
  @type tool_params :: map()
  @type uri :: String.t()
  @type prompt_name :: String.t()
  @type prompt_args :: map()

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
  """
  @callback handle_call_tool(conn(), tool_name(), tool_params()) ::
              {:ok, result :: map()} | {:error, error :: map()}

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
  """
  @callback handle_read_resource(conn(), uri()) ::
              {:ok, content :: map()} | {:error, error :: map()}

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
  """
  @callback handle_get_prompt(conn(), prompt_name(), prompt_args()) ::
              {:ok, messages :: map()} | {:error, error :: map()}

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

  @optional_callbacks [
    handle_list_tools: 1,
    handle_list_tools: 2,
    handle_call_tool: 3,
    handle_list_resources: 1,
    handle_list_resources: 2,
    handle_read_resource: 2,
    handle_list_prompts: 1,
    handle_list_prompts: 2,
    handle_get_prompt: 3,
    handle_complete: 3,
    handle_set_log_level: 2,
    handle_subscribe_resource: 2,
    handle_unsubscribe_resource: 2
  ]

  defmacro __using__(opts) do
    use_dsl = Keyword.get(opts, :dsl, true)

    if use_dsl do
      quote do
        @behaviour ConduitMcp.Server
        use ConduitMcp.DSL
      end
    else
      quote do
        @behaviour ConduitMcp.Server

        # Default implementations for manual mode
        def handle_list_tools(_conn) do
          {:ok, %{"tools" => []}}
        end

        def handle_call_tool(_conn, _name, _params) do
          {:error,
           %{"code" => ConduitMcp.Errors.method_not_found(), "message" => "Tool not found"}}
        end

        def handle_list_resources(_conn) do
          {:ok, %{"resources" => []}}
        end

        def handle_read_resource(_conn, _uri) do
          {:error,
           %{"code" => ConduitMcp.Errors.method_not_found(), "message" => "Resource not found"}}
        end

        def handle_list_prompts(_conn) do
          {:ok, %{"prompts" => []}}
        end

        def handle_get_prompt(_conn, _name, _args) do
          {:error,
           %{"code" => ConduitMcp.Errors.method_not_found(), "message" => "Prompt not found"}}
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

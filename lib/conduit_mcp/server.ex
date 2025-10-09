defmodule ConduitMcp.Server do
  @moduledoc """
  Behaviour for implementing MCP servers.

  An MCP server provides tools, resources, and prompts to LLM clients.
  Servers implement callbacks to handle client requests.

  ## Example

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server

        @impl true
        def mcp_init(_opts) do
          state = %{
            tools: [
              %{
                name: "echo",
                description: "Echo back the input",
                inputSchema: %{
                  type: "object",
                  properties: %{
                    message: %{type: "string", description: "Message to echo"}
                  },
                  required: ["message"]
                }
              }
            ]
          }
          {:ok, state}
        end

        @impl true
        def handle_list_tools(state) do
          {:reply, %{tools: state.tools}, state}
        end

        @impl true
        def handle_call_tool("echo", %{"message" => msg}, state) do
          {:reply, %{content: [%{type: "text", text: msg}]}, state}
        end
      end
  """

  @type state :: any()
  @type tool_name :: String.t()
  @type tool_params :: map()
  @type uri :: String.t()
  @type prompt_name :: String.t()
  @type prompt_args :: map()

  @doc """
  Initialize the MCP server with options.
  Called when the server starts.
  """
  @callback mcp_init(opts :: keyword()) :: {:ok, state()} | {:error, any()}

  @doc """
  Handle listing available tools.
  """
  @callback handle_list_tools(state()) ::
              {:reply, %{tools: list()}, state()}

  @doc """
  Handle tool execution.
  """
  @callback handle_call_tool(tool_name(), tool_params(), state()) ::
              {:reply, result :: map(), state()} |
              {:error, error :: map(), state()}

  @doc """
  Handle listing available resources.
  """
  @callback handle_list_resources(state()) ::
              {:reply, %{resources: list()}, state()}

  @doc """
  Handle reading a resource.
  """
  @callback handle_read_resource(uri(), state()) ::
              {:reply, content :: map(), state()} |
              {:error, error :: map(), state()}

  @doc """
  Handle listing available prompts.
  """
  @callback handle_list_prompts(state()) ::
              {:reply, %{prompts: list()}, state()}

  @doc """
  Handle getting a prompt.
  """
  @callback handle_get_prompt(prompt_name(), prompt_args(), state()) ::
              {:reply, messages :: map(), state()} |
              {:error, error :: map(), state()}

  @doc """
  Handle termination.
  """
  @callback terminate(reason :: any(), state()) :: :ok

  @optional_callbacks [
    handle_list_tools: 1,
    handle_call_tool: 3,
    handle_list_resources: 1,
    handle_read_resource: 2,
    handle_list_prompts: 1,
    handle_get_prompt: 3,
    terminate: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour ConduitMcp.Server
      use GenServer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl GenServer
      def init(opts) do
        __MODULE__.mcp_init(opts)
      end

      @impl GenServer
      def handle_call({:list_tools}, _from, state) do
        case __MODULE__.handle_list_tools(state) do
          {:reply, result, new_state} -> {:reply, result, new_state}
          other -> other
        end
      end

      @impl GenServer
      def handle_call({:call_tool, name, params}, _from, state) do
        case __MODULE__.handle_call_tool(name, params, state) do
          {:reply, result, new_state} -> {:reply, result, new_state}
          {:error, error, new_state} -> {:reply, {:error, error}, new_state}
        end
      end

      @impl GenServer
      def handle_call({:list_resources}, _from, state) do
        case __MODULE__.handle_list_resources(state) do
          {:reply, result, new_state} -> {:reply, result, new_state}
          other -> other
        end
      end

      @impl GenServer
      def handle_call({:read_resource, uri}, _from, state) do
        case __MODULE__.handle_read_resource(uri, state) do
          {:reply, result, new_state} -> {:reply, result, new_state}
          {:error, error, new_state} -> {:reply, {:error, error}, new_state}
        end
      end

      @impl GenServer
      def handle_call({:list_prompts}, _from, state) do
        case __MODULE__.handle_list_prompts(state) do
          {:reply, result, new_state} -> {:reply, result, new_state}
          other -> other
        end
      end

      @impl GenServer
      def handle_call({:get_prompt, name, args}, _from, state) do
        case __MODULE__.handle_get_prompt(name, args, state) do
          {:reply, result, new_state} -> {:reply, result, new_state}
          {:error, error, new_state} -> {:reply, {:error, error}, new_state}
        end
      end

      # Default implementations
      def handle_list_tools(_state) do
        raise "handle_list_tools/1 not implemented"
      end

      def handle_call_tool(_name, _params, _state) do
        raise "handle_call_tool/3 not implemented"
      end

      def handle_list_resources(state) do
        {:reply, %{resources: []}, state}
      end

      def handle_read_resource(_uri, state) do
        {:error, %{code: -32601, message: "Resource not found"}, state}
      end

      def handle_list_prompts(state) do
        {:reply, %{prompts: []}, state}
      end

      def handle_get_prompt(_name, _args, state) do
        {:error, %{code: -32601, message: "Prompt not found"}, state}
      end

      def terminate(_reason, _state), do: :ok

      defoverridable handle_list_tools: 1,
                     handle_call_tool: 3,
                     handle_list_resources: 1,
                     handle_read_resource: 2,
                     handle_list_prompts: 1,
                     handle_get_prompt: 3,
                     terminate: 2
    end
  end
end

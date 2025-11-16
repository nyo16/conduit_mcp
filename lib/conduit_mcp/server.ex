defmodule ConduitMcp.Server do
  @moduledoc """
  Behaviour for implementing stateless MCP servers.

  An MCP server provides tools, resources, and prompts to LLM clients.
  Servers implement callbacks to handle client requests concurrently.

  ## Changes in v0.4.0

  The server is now stateless by design for maximum concurrency:
  - No GenServer bottleneck - all requests are handled concurrently
  - Config is initialized once and stored immutably
  - Callbacks no longer receive/return state
  - Each HTTP request runs in parallel (limited only by Bandit's process pool)

  If you need mutable state, use external mechanisms like ETS, Agents, or databases.

  ## Example

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server

        @impl true
        def mcp_init(_opts) do
          config = %{
            tools: [
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
          }
          {:ok, config}
        end

        @impl true
        def handle_list_tools(config) do
          {:ok, %{"tools" => config.tools}}
        end

        @impl true
        def handle_call_tool("echo", %{"message" => msg}, _config) do
          {:ok, %{"content" => [%{"type" => "text", "text" => msg}]}}
        end
      end
  """

  @type config :: any()
  @type tool_name :: String.t()
  @type tool_params :: map()
  @type uri :: String.t()
  @type prompt_name :: String.t()
  @type prompt_args :: map()

  @doc """
  Initialize the MCP server with options.
  Called when the server starts. Returns configuration that will be
  stored and passed to all handler callbacks.
  """
  @callback mcp_init(opts :: keyword()) :: {:ok, config()} | {:error, any()}

  @doc """
  Handle listing available tools.
  """
  @callback handle_list_tools(config()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}

  @doc """
  Handle tool execution.
  """
  @callback handle_call_tool(tool_name(), tool_params(), config()) ::
              {:ok, result :: map()} | {:error, error :: map()}

  @doc """
  Handle listing available resources.
  """
  @callback handle_list_resources(config()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}

  @doc """
  Handle reading a resource.
  """
  @callback handle_read_resource(uri(), config()) ::
              {:ok, content :: map()} | {:error, error :: map()}

  @doc """
  Handle listing available prompts.
  """
  @callback handle_list_prompts(config()) ::
              {:ok, %{optional(String.t()) => any()}} | {:error, map()}

  @doc """
  Handle getting a prompt.
  """
  @callback handle_get_prompt(prompt_name(), prompt_args(), config()) ::
              {:ok, messages :: map()} | {:error, error :: map()}

  @optional_callbacks [
    handle_list_tools: 1,
    handle_call_tool: 3,
    handle_list_resources: 1,
    handle_read_resource: 2,
    handle_list_prompts: 1,
    handle_get_prompt: 3
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour ConduitMcp.Server

      @doc """
      Starts the server and initializes configuration.
      Config is stored in an Agent for concurrent read access.
      """
      def start_link(opts \\ []) do
        Agent.start_link(
          fn ->
            case __MODULE__.mcp_init(opts) do
              {:ok, config} ->
                config

              {:error, reason} ->
                raise "Failed to initialize #{__MODULE__}: #{inspect(reason)}"
            end
          end,
          name: __MODULE__
        )
      end

      @doc """
      Gets the current configuration.
      """
      def get_config do
        Agent.get(__MODULE__, & &1)
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent
        }
      end

      # Default implementations
      def handle_list_tools(_config) do
        {:ok, %{"tools" => []}}
      end

      def handle_call_tool(_name, _params, _config) do
        {:error, %{"code" => -32601, "message" => "Tool not found"}}
      end

      def handle_list_resources(_config) do
        {:ok, %{"resources" => []}}
      end

      def handle_read_resource(_uri, _config) do
        {:error, %{"code" => -32601, "message" => "Resource not found"}}
      end

      def handle_list_prompts(_config) do
        {:ok, %{"prompts" => []}}
      end

      def handle_get_prompt(_name, _args, _config) do
        {:error, %{"code" => -32601, "message" => "Prompt not found"}}
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

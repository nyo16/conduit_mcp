defmodule ConduitMcp.Telemetry do
  @moduledoc """
  Telemetry integration for ConduitMCP.

  ConduitMCP uses the `:telemetry` library for instrumentation. This module
  documents all telemetry events emitted by the library and provides helper
  functions for setting up event handlers.

  ## Events

  All events are prefixed with `[:conduit_mcp]`.

  ### Request Events

  #### `[:conduit_mcp, :request, :stop]`

  Emitted when an MCP request completes, whether successfully or with an error.

  **Measurements:**

    * `:duration` (integer) - Request processing duration in native time units.
      Use `System.convert_time_unit/3` to convert to other units.

  **Metadata:**

    * `:method` (String.t) - The MCP method that was called
      (e.g., `"initialize"`, `"tools/list"`, `"tools/call"`)
    * `:server_module` (module) - The MCP server module handling the request
    * `:status` (:ok | :error) - Whether the request succeeded or failed

  **Example:**

      :telemetry.attach(
        "log-mcp-requests",
        [:conduit_mcp, :request, :stop],
        fn _event, measurements, metadata, _config ->
          duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

          IO.inspect(%{
            method: metadata.method,
            status: metadata.status,
            duration_ms: duration_ms
          }, label: "MCP Request")
        end,
        nil
      )

  ### Tool Execution Events

  #### `[:conduit_mcp, :tool, :execute]`

  Emitted when a tool is executed via the `tools/call` method.

  **Measurements:**

    * `:duration` (integer) - Tool execution duration in native time units

  **Metadata:**

    * `:tool_name` (String.t) - Name of the tool that was executed
    * `:server_module` (module) - The MCP server module
    * `:status` (:ok | :error) - Whether the tool executed successfully

  **Example:**

      :telemetry.attach(
        "track-tool-performance",
        [:conduit_mcp, :tool, :execute],
        fn _event, measurements, metadata, _config ->
          duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

          if duration_ms > 1000 do
            Logger.warning("Slow tool execution: \#{metadata.tool_name} (\#{duration_ms}ms)")
          end
        end,
        nil
      )

  ### Resource Events

  #### `[:conduit_mcp, :resource, :read]`

  Emitted when a resource is read via the `resources/read` method.

  **Measurements:**

    * `:duration` (integer) - Resource read duration in native time units

  **Metadata:**

    * `:uri` (String.t) - URI of the resource that was read
    * `:server_module` (module) - The MCP server module
    * `:status` (:ok | :error) - Whether the read succeeded or failed

  **Example:**

      :telemetry.attach(
        "track-resource-reads",
        [:conduit_mcp, :resource, :read],
        fn _event, measurements, metadata, _config ->
          duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
          Logger.info("Resource read: uri=\#{metadata.uri} duration=\#{duration_ms}ms")
        end,
        nil
      )

  ### Prompt Events

  #### `[:conduit_mcp, :prompt, :get]`

  Emitted when a prompt is retrieved via the `prompts/get` method.

  **Measurements:**

    * `:duration` (integer) - Prompt retrieval duration in native time units

  **Metadata:**

    * `:prompt_name` (String.t) - Name of the prompt that was retrieved
    * `:server_module` (module) - The MCP server module
    * `:status` (:ok | :error) - Whether the prompt retrieval succeeded

  **Example:**

      :telemetry.attach(
        "track-prompt-usage",
        [:conduit_mcp, :prompt, :get],
        fn _event, _measurements, metadata, _config ->
          Logger.info("Prompt requested: \#{metadata.prompt_name}")
        end,
        nil
      )

  ### Authentication Events

  #### `[:conduit_mcp, :auth, :verify]`

  Emitted when authentication verification is performed.

  **Measurements:**

    * `:duration` (integer) - Authentication verification duration in native time units

  **Metadata:**

    * `:strategy` (:bearer_token | :api_key | :function) - Auth strategy used
    * `:status` (:ok | :error) - Whether authentication succeeded
    * `:reason` (any) - Failure reason (only present when status is :error)

  **Example:**

      :telemetry.attach(
        "track-auth-failures",
        [:conduit_mcp, :auth, :verify],
        fn _event, _measurements, metadata, _config ->
          if metadata.status == :error do
            Logger.warning("Auth failed: strategy=\#{metadata.strategy} reason=\#{inspect(metadata.reason)}")
          end
        end,
        nil
      )

  ## Common Use Cases

  ### Logging All MCP Activity

      defmodule MyApp.MCPTelemetry do
        require Logger

        def attach_handlers do
          events = [
            [:conduit_mcp, :request, :stop],
            [:conduit_mcp, :tool, :execute],
            [:conduit_mcp, :resource, :read],
            [:conduit_mcp, :prompt, :get],
            [:conduit_mcp, :auth, :verify]
          ]

          :telemetry.attach_many(
            "my-app-mcp-logger",
            events,
            &handle_event/4,
            nil
          )
        end

        def handle_event([:conduit_mcp, :request, :stop], measurements, metadata, _config) do
          Logger.info("MCP request",
            method: metadata.method,
            status: metadata.status,
            duration_ms: convert_duration(measurements.duration)
          )
        end

        def handle_event([:conduit_mcp, :tool, :execute], measurements, metadata, _config) do
          Logger.info("Tool executed",
            tool: metadata.tool_name,
            status: metadata.status,
            duration_ms: convert_duration(measurements.duration)
          )
        end

        def handle_event([:conduit_mcp, :resource, :read], measurements, metadata, _config) do
          Logger.info("Resource read",
            uri: metadata.uri,
            status: metadata.status,
            duration_ms: convert_duration(measurements.duration)
          )
        end

        def handle_event([:conduit_mcp, :prompt, :get], measurements, metadata, _config) do
          Logger.info("Prompt retrieved",
            prompt: metadata.prompt_name,
            status: metadata.status,
            duration_ms: convert_duration(measurements.duration)
          )
        end

        def handle_event([:conduit_mcp, :auth, :verify], measurements, metadata, _config) do
          Logger.info("Auth verification",
            strategy: metadata.strategy,
            status: metadata.status,
            duration_ms: convert_duration(measurements.duration)
          )
        end

        defp convert_duration(native) do
          System.convert_time_unit(native, :native, :millisecond)
        end
      end

  ### Metrics Collection

      defmodule MyApp.MCPMetrics do
        use Supervisor
        import Telemetry.Metrics

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
        end

        def init(_opts) do
          children = [
            {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end

        defp metrics do
          [
            # Total requests by method and status
            counter("conduit_mcp.request.stop.count",
              tags: [:method, :status],
              description: "Total MCP requests"
            ),

            # Request duration distribution
            distribution("conduit_mcp.request.stop.duration",
              unit: {:native, :millisecond},
              tags: [:method],
              description: "MCP request duration"
            ),

            # Tool execution count
            counter("conduit_mcp.tool.execute.count",
              tags: [:tool_name, :status],
              description: "Tool execution count"
            ),

            # Tool duration summary
            summary("conduit_mcp.tool.execute.duration",
              unit: {:native, :millisecond},
              tags: [:tool_name],
              description: "Tool execution duration"
            ),

            # Resource read count
            counter("conduit_mcp.resource.read.count",
              tags: [:status],
              description: "Resource read operations"
            ),

            # Resource read duration
            distribution("conduit_mcp.resource.read.duration",
              unit: {:native, :millisecond},
              description: "Resource read duration"
            ),

            # Prompt retrieval count
            counter("conduit_mcp.prompt.get.count",
              tags: [:prompt_name, :status],
              description: "Prompt retrieval count"
            ),

            # Prompt retrieval duration
            summary("conduit_mcp.prompt.get.duration",
              unit: {:native, :millisecond},
              tags: [:prompt_name],
              description: "Prompt retrieval duration"
            ),

            # Auth verification count
            counter("conduit_mcp.auth.verify.count",
              tags: [:strategy, :status],
              description: "Authentication attempts"
            ),

            # Auth verification duration
            distribution("conduit_mcp.auth.verify.duration",
              unit: {:native, :millisecond},
              tags: [:strategy],
              description: "Authentication verification duration"
            )
          ]
        end
      end

  ### Performance Alerts

      :telemetry.attach(
        "mcp-performance-alerts",
        [:conduit_mcp, :tool, :execute],
        fn _event, %{duration: duration}, %{tool_name: tool}, _config ->
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)

          cond do
            duration_ms > 5000 ->
              Logger.error("Critical: Tool \#{tool} took \#{duration_ms}ms")

            duration_ms > 1000 ->
              Logger.warning("Warning: Tool \#{tool} took \#{duration_ms}ms")

            true ->
              :ok
          end
        end,
        nil
      )

  ## See Also

  - [`:telemetry` documentation](https://hexdocs.pm/telemetry/)
  - [`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics/)
  - [Phoenix Telemetry](https://hexdocs.pm/phoenix/telemetry.html)
  """

  @doc """
  Returns all telemetry event names emitted by ConduitMCP.

  ## Example

      iex> ConduitMcp.Telemetry.events()
      [
        [:conduit_mcp, :request, :stop],
        [:conduit_mcp, :tool, :execute],
        [:conduit_mcp, :resource, :read],
        [:conduit_mcp, :prompt, :get],
        [:conduit_mcp, :auth, :verify]
      ]
  """
  @spec events() :: [[:conduit_mcp, ...]]
  def events do
    [
      [:conduit_mcp, :request, :stop],
      [:conduit_mcp, :tool, :execute],
      [:conduit_mcp, :resource, :read],
      [:conduit_mcp, :prompt, :get],
      [:conduit_mcp, :auth, :verify]
    ]
  end

  @doc """
  Attaches default logging handlers for all ConduitMCP telemetry events.

  This is a convenience function for quick setup during development.
  The handlers will log events at the `:debug` level.

  ## Example

      # In your application.ex
      def start(_type, _args) do
        ConduitMcp.Telemetry.attach_default_handlers()
        # ... rest of supervision tree
      end

  To detach later:

      ConduitMcp.Telemetry.detach_default_handlers()
  """
  @spec attach_default_handlers() :: :ok | {:error, :already_exists}
  def attach_default_handlers do
    :telemetry.attach_many(
      "conduit-mcp-default-logger",
      events(),
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detaches the default telemetry handlers.

  ## Example

      ConduitMcp.Telemetry.detach_default_handlers()
  """
  @spec detach_default_handlers() :: :ok | {:error, :not_found}
  def detach_default_handlers do
    :telemetry.detach("conduit-mcp-default-logger")
  end

  # Private: Default event handler for logging
  defp handle_event([:conduit_mcp, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "MCP request completed: method=#{metadata.method} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :tool, :execute], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Tool executed: tool=#{metadata.tool_name} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :resource, :read], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Resource read: uri=#{metadata.uri} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :prompt, :get], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Prompt retrieved: prompt=#{metadata.prompt_name} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :auth, :verify], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    level = if metadata.status == :ok, do: :debug, else: :warning

    Logger.log(
      level,
      "Auth verification: strategy=#{metadata.strategy} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end
end

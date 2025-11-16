defmodule PhoenixMcp.Telemetry do
  @moduledoc """
  Telemetry setup for Phoenix MCP example.

  Demonstrates how to capture and monitor MCP tool response times.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Optional: Start telemetry poller for VM metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    # Attach ConduitMCP telemetry handlers
    attach_conduit_mcp_handlers()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Attach handlers for ConduitMCP telemetry events
  defp attach_conduit_mcp_handlers do
    events = [
      [:conduit_mcp, :request, :stop],
      [:conduit_mcp, :tool, :execute],
      [:conduit_mcp, :resource, :read],
      [:conduit_mcp, :prompt, :get],
      [:conduit_mcp, :auth, :verify]
    ]

    :telemetry.attach_many(
      "phoenix-mcp-telemetry",
      events,
      &handle_event/4,
      nil
    )
  end

  # Handle MCP request events
  def handle_event([:conduit_mcp, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.info("MCP Request",
      method: metadata.method,
      status: metadata.status,
      duration_ms: duration_ms
    )
  end

  # Handle tool execution events - CAPTURES RESPONSE TIME!
  def handle_event([:conduit_mcp, :tool, :execute], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    # Log every tool execution with response time
    Logger.info("Tool Executed",
      tool: metadata.tool_name,
      status: metadata.status,
      response_time_ms: duration_ms
    )

    # Alert on slow tools
    if duration_ms > 1000 do
      Logger.warning("Slow tool detected: #{metadata.tool_name} took #{duration_ms}ms")
    end

    # You could also send to external monitoring (Datadog, New Relic, etc.)
    # MyApp.Monitoring.track_tool_execution(metadata.tool_name, duration_ms)
  end

  # Handle resource read events
  def handle_event([:conduit_mcp, :resource, :read], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.info("Resource Read",
      uri: metadata.uri,
      status: metadata.status,
      duration_ms: duration_ms
    )
  end

  # Handle prompt retrieval events
  def handle_event([:conduit_mcp, :prompt, :get], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.info("Prompt Retrieved",
      prompt: metadata.prompt_name,
      status: metadata.status,
      duration_ms: duration_ms
    )
  end

  # Handle authentication events
  def handle_event([:conduit_mcp, :auth, :verify], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    if metadata.status == :error do
      Logger.warning("Auth Failed",
        strategy: metadata.strategy,
        reason: metadata.reason,
        duration_ms: duration_ms
      )
    else
      Logger.debug("Auth Success",
        strategy: metadata.strategy,
        duration_ms: duration_ms
      )
    end
  end

  # Metrics for Phoenix LiveDashboard
  def metrics do
    [
      # Phoenix-provided metrics
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # ConduitMCP metrics
      summary("conduit_mcp.request.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :status],
        description: "MCP request duration"
      ),

      counter("conduit_mcp.request.stop.count",
        tags: [:method, :status],
        description: "Total MCP requests"
      ),

      # Tool execution metrics - RESPONSE TIME TRACKING
      summary("conduit_mcp.tool.execute.duration",
        unit: {:native, :millisecond},
        tags: [:tool_name],
        description: "Tool response time (milliseconds)"
      ),

      distribution("conduit_mcp.tool.execute.duration",
        unit: {:native, :millisecond},
        tags: [:tool_name],
        reporter_options: [
          buckets: [10, 100, 500, 1000, 5000]
        ],
        description: "Tool response time distribution"
      ),

      counter("conduit_mcp.tool.execute.count",
        tags: [:tool_name, :status],
        description: "Tool execution count"
      ),

      # Resource metrics
      counter("conduit_mcp.resource.read.count",
        tags: [:status],
        description: "Resource read operations"
      ),

      summary("conduit_mcp.resource.read.duration",
        unit: {:native, :millisecond},
        description: "Resource read duration"
      ),

      # Prompt metrics
      counter("conduit_mcp.prompt.get.count",
        tags: [:prompt_name, :status],
        description: "Prompt retrieval count"
      ),

      summary("conduit_mcp.prompt.get.duration",
        unit: {:native, :millisecond},
        tags: [:prompt_name],
        description: "Prompt retrieval duration"
      ),

      # Authentication metrics
      counter("conduit_mcp.auth.verify.count",
        tags: [:strategy, :status],
        description: "Authentication attempts"
      ),

      distribution("conduit_mcp.auth.verify.duration",
        unit: {:native, :millisecond},
        tags: [:strategy],
        reporter_options: [
          buckets: [1, 10, 50, 100, 500]
        ],
        description: "Auth verification duration"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :megabyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      {PhoenixMcp, :count_users, []}
    ]
  end

  def count_users do
    # Example: return metrics about your app
    # %{active_users: MyApp.Users.count_active()}
    %{}
  end
end

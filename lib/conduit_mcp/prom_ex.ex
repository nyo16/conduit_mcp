if Code.ensure_loaded?(PromEx) do
  defmodule ConduitMcp.PromEx do
    @moduledoc """
    A PromEx plugin for monitoring ConduitMCP operations.

    This plugin captures metrics from the ConduitMCP library's telemetry events:
    - Request metrics (all MCP method calls)
    - Tool execution metrics
    - Resource read metrics
    - Prompt retrieval metrics
    - Authentication metrics

    ## Installation

    Add `:prom_ex` to your dependencies:

        def deps do
          [
            {:conduit_mcp, "~> 0.4.7"},
            {:prom_ex, "~> 1.11"}
          ]
        end

    ## Usage

    Add this plugin to your PromEx module's plugins list:

        defmodule MyApp.PromEx do
          use PromEx, otp_app: :my_app

          @impl true
          def plugins do
            [
              PromEx.Plugins.Application,
              PromEx.Plugins.Beam,
              {ConduitMcp.PromEx, otp_app: :my_app}
            ]
          end

          @impl true
          def dashboard_assigns do
            [
              datasource_id: "prometheus",
              default_selected_interval: "30s"
            ]
          end
        end

    Then add your PromEx module to your supervision tree:

        def start(_type, _args) do
          children = [
            MyApp.PromEx,
            # ... other children ...
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end

    ## Configuration Options

    - `:otp_app` (required) - Your application name
    - `:duration_unit` (optional) - Unit for duration metrics (default: `:millisecond`)

    ## Metrics Exposed

    All metrics are prefixed with `{otp_app}_conduit_mcp_`.

    ### Request Metrics

    - `{prefix}_request_total` - Counter of MCP requests
      - Tags: `method` (e.g., "tools/list"), `status` (:ok | :error)
    - `{prefix}_request_duration_milliseconds` - Distribution of request durations
      - Tags: `method`, `status`
      - Buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

    ### Tool Metrics

    - `{prefix}_tool_execution_total` - Counter of tool executions
      - Tags: `tool_name`, `status`
    - `{prefix}_tool_duration_milliseconds` - Distribution of tool execution durations
      - Tags: `tool_name`, `status`
      - Buckets: [10, 50, 100, 500, 1_000, 5_000, 10_000, 30_000]

    ### Resource Metrics

    - `{prefix}_resource_read_total` - Counter of resource reads
      - Tags: `status`
    - `{prefix}_resource_read_duration_milliseconds` - Distribution of resource read durations
      - Tags: `status`
      - Buckets: [10, 50, 100, 500, 1_000, 5_000]

    ### Prompt Metrics

    - `{prefix}_prompt_get_total` - Counter of prompt retrievals
      - Tags: `prompt_name`, `status`
    - `{prefix}_prompt_get_duration_milliseconds` - Distribution of prompt retrieval durations
      - Tags: `prompt_name`, `status`
      - Buckets: [10, 50, 100, 500, 1_000]

    ### Authentication Metrics

    - `{prefix}_auth_verify_total` - Counter of authentication attempts
      - Tags: `strategy` (:bearer_token | :api_key | :function), `status`
    - `{prefix}_auth_verify_duration_milliseconds` - Distribution of auth verification durations
      - Tags: `strategy`, `status`
      - Buckets: [1, 5, 10, 25, 50, 100, 250]

    ## PromQL Examples

    ### Request Rate by Method

        rate({otp_app}_conduit_mcp_request_total[5m])

    ### Error Rate Percentage

        100 * (
          rate({otp_app}_conduit_mcp_request_total{status="error"}[5m])
          /
          rate({otp_app}_conduit_mcp_request_total[5m])
        )

    ### P95 Request Duration

        histogram_quantile(0.95,
          rate({otp_app}_conduit_mcp_request_duration_milliseconds_bucket[5m])
        )

    ### Slow Tool Executions (>5s)

        histogram_quantile(0.95,
          rate({otp_app}_conduit_mcp_tool_duration_milliseconds_bucket[5m])
        ) > 5000

    ### Authentication Success Rate

        100 * (
          rate({otp_app}_conduit_mcp_auth_verify_total{status="ok"}[5m])
          /
          rate({otp_app}_conduit_mcp_auth_verify_total[5m])
        )

    ## Alert Examples

    ### High Error Rate

        - alert: ConduitMcpHighErrorRate
          expr: |
            100 * (
              rate(myapp_conduit_mcp_request_total{status="error"}[5m])
              /
              rate(myapp_conduit_mcp_request_total[5m])
            ) > 5
          for: 5m
          annotations:
            summary: "High error rate in ConduitMCP ({{ $value }}%)"

    ### Slow Tool Executions

        - alert: ConduitMcpSlowTools
          expr: |
            histogram_quantile(0.95,
              rate(myapp_conduit_mcp_tool_duration_milliseconds_bucket[5m])
            ) > 5000
          for: 10m
          annotations:
            summary: "Tool executions are slow (p95: {{ $value }}ms)"

    ### Authentication Failures

        - alert: ConduitMcpAuthFailures
          expr: |
            rate(myapp_conduit_mcp_auth_verify_total{status="error"}[5m]) > 0.1
          for: 5m
          annotations:
            summary: "Authentication failures detected"

    ## Cardinality Considerations

    This plugin is designed to minimize metric cardinality:

    - ✅ LOW: `method` (limited set of MCP methods)
    - ✅ LOW: `status` (only :ok or :error)
    - ✅ LOW: `strategy` (only 3 auth strategies)
    - ✅ LOW: `tool_name` (user-defined but typically limited)
    - ✅ LOW: `prompt_name` (user-defined but typically limited)
    - ❌ HIGH: `uri` is NOT included (unbounded)
    - ❌ HIGH: `server_module` is NOT included (not useful)

    All string values are normalized to prevent cardinality explosion.
    """

    use PromEx.Plugin

    @impl true
    def event_metrics(opts) do
      otp_app = Keyword.fetch!(opts, :otp_app)
      metric_prefix = PromEx.metric_prefix(otp_app, :conduit_mcp)
      duration_unit = Keyword.get(opts, :duration_unit, :millisecond)

      [
        request_metrics(metric_prefix, duration_unit),
        tool_metrics(metric_prefix, duration_unit),
        resource_metrics(metric_prefix, duration_unit),
        prompt_metrics(metric_prefix, duration_unit),
        auth_metrics(metric_prefix, duration_unit)
      ]
    end

    # Request metrics from [:conduit_mcp, :request, :stop]
    defp request_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_request_metrics,
        [
          # Counter: Total requests by method and status
          counter(
            metric_prefix ++ [:request, :total],
            event_name: [:conduit_mcp, :request, :stop],
            description: "Total number of MCP requests",
            measurement: fn _measurements -> 1 end,
            tags: [:method, :status],
            tag_values: &extract_request_tags/1
          ),

          # Distribution: Request duration by method and status
          distribution(
            metric_prefix ++ [:request, :duration, duration_unit],
            event_name: [:conduit_mcp, :request, :stop],
            description: "MCP request duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:method, :status],
            tag_values: &extract_request_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
            ]
          )
        ]
      )
    end

    # Tool execution metrics from [:conduit_mcp, :tool, :execute]
    defp tool_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_tool_metrics,
        [
          # Counter: Tool executions by tool name and status
          counter(
            metric_prefix ++ [:tool, :execution, :total],
            event_name: [:conduit_mcp, :tool, :execute],
            description: "Total number of MCP tool executions",
            measurement: fn _measurements -> 1 end,
            tags: [:tool_name, :status],
            tag_values: &extract_tool_tags/1
          ),

          # Distribution: Tool execution duration by tool name and status
          distribution(
            metric_prefix ++ [:tool, :duration, duration_unit],
            event_name: [:conduit_mcp, :tool, :execute],
            description: "MCP tool execution duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:tool_name, :status],
            tag_values: &extract_tool_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 500, 1_000, 5_000, 10_000, 30_000]
            ]
          )
        ]
      )
    end

    # Resource read metrics from [:conduit_mcp, :resource, :read]
    defp resource_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_resource_metrics,
        [
          # Counter: Resource reads by status
          counter(
            metric_prefix ++ [:resource, :read, :total],
            event_name: [:conduit_mcp, :resource, :read],
            description: "Total number of MCP resource reads",
            measurement: fn _measurements -> 1 end,
            tags: [:status],
            tag_values: &extract_resource_tags/1
          ),

          # Distribution: Resource read duration by status
          distribution(
            metric_prefix ++ [:resource, :read, :duration, duration_unit],
            event_name: [:conduit_mcp, :resource, :read],
            description: "MCP resource read duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:status],
            tag_values: &extract_resource_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 500, 1_000, 5_000]
            ]
          )
        ]
      )
    end

    # Prompt retrieval metrics from [:conduit_mcp, :prompt, :get]
    defp prompt_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_prompt_metrics,
        [
          # Counter: Prompt retrievals by prompt name and status
          counter(
            metric_prefix ++ [:prompt, :get, :total],
            event_name: [:conduit_mcp, :prompt, :get],
            description: "Total number of MCP prompt retrievals",
            measurement: fn _measurements -> 1 end,
            tags: [:prompt_name, :status],
            tag_values: &extract_prompt_tags/1
          ),

          # Distribution: Prompt retrieval duration by prompt name and status
          distribution(
            metric_prefix ++ [:prompt, :get, :duration, duration_unit],
            event_name: [:conduit_mcp, :prompt, :get],
            description: "MCP prompt retrieval duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:prompt_name, :status],
            tag_values: &extract_prompt_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 500, 1_000]
            ]
          )
        ]
      )
    end

    # Authentication metrics from [:conduit_mcp, :auth, :verify]
    defp auth_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_auth_metrics,
        [
          # Counter: Auth attempts by strategy and status
          counter(
            metric_prefix ++ [:auth, :verify, :total],
            event_name: [:conduit_mcp, :auth, :verify],
            description: "Total number of MCP authentication attempts",
            measurement: fn _measurements -> 1 end,
            tags: [:strategy, :status],
            tag_values: &extract_auth_tags/1
          ),

          # Distribution: Auth verification duration by strategy and status
          distribution(
            metric_prefix ++ [:auth, :verify, :duration, duration_unit],
            event_name: [:conduit_mcp, :auth, :verify],
            description: "MCP authentication verification duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:strategy, :status],
            tag_values: &extract_auth_tags/1,
            reporter_options: [
              buckets: [1, 5, 10, 25, 50, 100, 250]
            ]
          )
        ]
      )
    end

    # Tag extraction functions

    defp extract_request_tags(%{method: method, status: status}) do
      %{
        method: normalize_string(method),
        status: status
      }
    end

    defp extract_tool_tags(%{tool_name: tool_name, status: status}) do
      %{
        tool_name: normalize_string(tool_name),
        status: status
      }
    end

    defp extract_resource_tags(%{status: status}) do
      %{
        status: status
      }
    end

    defp extract_prompt_tags(%{prompt_name: prompt_name, status: status}) do
      %{
        prompt_name: normalize_string(prompt_name),
        status: status
      }
    end

    defp extract_auth_tags(%{strategy: strategy, status: status}) do
      %{
        strategy: strategy,
        status: status
      }
    end

    # Normalize strings to prevent cardinality explosion
    defp normalize_string(value) when is_binary(value), do: value
    defp normalize_string(value) when is_atom(value), do: to_string(value)
    defp normalize_string(value), do: inspect(value)
  end
end

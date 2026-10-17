if Code.ensure_loaded?(PromEx) do
  defmodule ConduitMcp.PromEx do
    @moduledoc """
    A PromEx plugin for monitoring ConduitMCP operations.

    This plugin captures metrics from the ConduitMCP library's telemetry events:
    - Request metrics (all MCP method calls)
    - Tool execution metrics
    - Resource read metrics
    - Prompt retrieval metrics
    - HTTP and message rate limit metrics
    - Authentication metrics
    - Cancellation metrics
    - Janitor cleanup metrics

    Every event in `ConduitMcp.Telemetry.events/0` feeds at least one metric.

    ## Installation

    Add `:prom_ex` to your dependencies:

        def deps do
          [
            {:conduit_mcp, "~> 0.9.0"},
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

    ### Rate Limit Metrics

    - `{prefix}_rate_limit_check_total` - Counter of HTTP rate limit checks
      - Tags: `status` (:allow | :deny)
    - `{prefix}_rate_limit_check_duration_milliseconds` - Distribution of check durations
      - Tags: `status`
      - Buckets: [1, 5, 10, 25, 50, 100, 250]

    ### Message Rate Limit Metrics

    - `{prefix}_message_rate_limit_check_total` - Counter of message rate limit checks
      - Tags: `status` (:allow | :deny), `method` (MCP method name)
    - `{prefix}_message_rate_limit_check_duration_milliseconds` - Distribution of check durations
      - Tags: `status`, `method`
      - Buckets: [1, 5, 10, 25, 50, 100, 250]

    ### Authentication Metrics

    - `{prefix}_auth_verify_total` - Counter of authentication attempts
      - Tags: `strategy` (:bearer_token | :api_key | :function), `status`
    - `{prefix}_auth_verify_duration_milliseconds` - Distribution of auth verification durations
      - Tags: `strategy`, `status`
      - Buckets: [1, 5, 10, 25, 50, 100, 250]

    ### Cancellation Metrics

    - `{prefix}_request_cancelled_total` - Counter of recorded
      `notifications/cancelled` (no tags: request ids, scopes and reasons
      are unbounded or client-supplied)
    - `{prefix}_cancellation_cleanup_removed_total` - Sum of expired
      cancellation rows removed
    - `{prefix}_cancellation_cleanup_in_flight_removed_total` - Sum of
      in-flight rows of dead request processes removed
    - `{prefix}_cancellation_janitor_runs_total` - Counter of cancellation
      janitor runs (its `removed` duplicates the cleanup sum, so it is
      counted, not summed)

    ### Cleanup Metrics

    - `{prefix}_session_cleanup_removed_total` - Sum of expired sessions evicted
      - Tags: `store`
    - `{prefix}_tasks_cleanup_removed_total` - Sum of terminal tasks evicted
    - `{prefix}_ext_tasks_cleanup_removed_total` - Sum of expired
      tasks-extension tasks evicted
      - Tags: `store`

    ### MRTR Metrics

    - `{prefix}_mrtr_input_required_total` - Counter of `InputRequiredResult`s
      sent
      - Tags: `method` (`tools/call`, `resources/read`, `prompts/get`)
    - `{prefix}_mrtr_input_requests_total` - Sum of input requests carried by
      them
      - Tags: `method`

    ### Client Metrics

    From `ConduitMcp.Client`. Tool names and notification methods come from
    the server, and client names may be per-tenant, so none of them is a tag.

    - `{prefix}_client_request_start_total`,
      `{prefix}_client_request_exception_total` - Counters of requests sent
      and of requests whose caller raised
      - Tags: `method`
    - `{prefix}_client_request_total` - Counter of finished requests
      - Tags: `method`, `status`, `error_kind`
    - `{prefix}_client_request_duration_milliseconds` - Distribution of
      request durations
      - Tags: `method`, `status`
    - `{prefix}_client_tool_call_start_total`,
      `{prefix}_client_tool_call_exception_total` - Counters of tool calls
    - `{prefix}_client_tool_call_total` - Counter of finished tool calls
      - Tags: `status`, `error_kind`, `is_error`
    - `{prefix}_client_tool_call_duration_milliseconds` - Distribution of tool
      call durations
      - Tags: `status`
    - `{prefix}_client_connection_transition_total` - Counter of connection
      state changes
      - Tags: `to`, `reason`
    - `{prefix}_client_request_cancel_total` - Counter of requests the client
      cancelled
      - Tags: `reason`
    - `{prefix}_client_response_dropped_total` - Counter of late responses
      dropped
    - `{prefix}_client_notification_total` - Counter of server notifications
      received
    - `{prefix}_client_cache_refresh_start_total` - Counter of cache
      refreshes started
      - Tags: `kind`
    - `{prefix}_client_cache_refresh_total` - Counter of finished cache
      refreshes
      - Tags: `kind`, `status`, `error_kind`
    - `{prefix}_client_cache_refresh_duration_milliseconds` - Distribution of
      cache refresh durations
      - Tags: `kind`, `status`
    - `{prefix}_client_tool_rejected_total` - Counter of listed tools
      dropped at intake
      - Tags: `reason`
    - `{prefix}_client_tool_definition_changed_total` - Counter of known
      tools whose definition changed
    - `{prefix}_client_policy_decision_total` - Counter of policy
      decisions on governed calls, reads and gets
      - Tags: `target`, `decision`, `source`, `reason`, `approval`
    - `{prefix}_client_hook_total` - Counter of hook runs that returned
      within their contract
      - Tags: `kind`, `status`
    - `{prefix}_client_hook_duration_milliseconds` - Distribution of hook
      durations
      - Tags: `kind`
    - `{prefix}_client_hook_exception_total` - Counter of failed hook runs
      - Tags: `kind`, `reason`
    - `{prefix}_client_hub_server_failed_total` - Counter of hub server
      clients that exited
      - Tags: `reason`
    - `{prefix}_client_hub_server_restarted_total` - Counter of hub servers
      started again after a failure
    - `{prefix}_client_hub_collision_total` - Counter of exposed tool names
      left out because several tools mangled to them
    - `{prefix}_client_adapter_strict_fallback_total` - Counter of OpenAI
      tools sent non-strict because their schema has no strict form
      - Tags: `api`, `reason`
    - `{prefix}_client_oauth_{op}_start_total`, `{prefix}_client_oauth_{op}_total`,
      `{prefix}_client_oauth_{op}_exception_total` - Counters of the
      client's OAuth operations, `op` one of `discovery`, `registration`,
      `token_exchange`, `refresh`, `step_up`
      - Tags (`_total` only): `status`, `reason`
    - `{prefix}_client_oauth_authorization_required_total` - Counter of
      times the user had to authorize
      - Tags: `reason`

    ### Subscription Metrics

    - `{prefix}_subscription_start_total` - Counter of `subscriptions/listen`
      streams opened
    - `{prefix}_subscription_stop_total` - Counter of streams ended
      - Tags: `reason` (`client_closed`, `max_lifetime`, `token_expired`,
        `idle_timeout`)
    - `{prefix}_subscription_duration_milliseconds` - Distribution of how long
      streams stayed open
      - Tags: `reason`
      - Buckets: [1 000, 10 000, 60 000, 300 000, 900 000, 1 800 000, 3 600 000]

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
    - ❌ HIGH: the rate limit `key`, cancellation `request_id`, `scope` and
      `reason`, and subscription `filters`, are NOT included (unbounded,
      client-supplied, or a list)

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
        rate_limit_metrics(metric_prefix, duration_unit),
        message_rate_limit_metrics(metric_prefix, duration_unit),
        auth_metrics(metric_prefix, duration_unit),
        cancellation_metrics(metric_prefix),
        cleanup_metrics(metric_prefix),
        mrtr_metrics(metric_prefix),
        client_metrics(metric_prefix, duration_unit),
        subscription_metrics(metric_prefix)
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

    # HTTP rate limit metrics from [:conduit_mcp, :rate_limit, :check]. `key`
    # is an IP or user id, so it is never a tag.
    defp rate_limit_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_rate_limit_metrics,
        [
          counter(
            metric_prefix ++ [:rate_limit, :check, :total],
            event_name: [:conduit_mcp, :rate_limit, :check],
            description: "Total number of MCP HTTP rate limit checks",
            measurement: fn _measurements -> 1 end,
            tags: [:status],
            tag_values: &extract_status_tag/1
          ),
          distribution(
            metric_prefix ++ [:rate_limit, :check, :duration, duration_unit],
            event_name: [:conduit_mcp, :rate_limit, :check],
            description: "MCP HTTP rate limit check duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:status],
            tag_values: &extract_status_tag/1,
            reporter_options: [
              buckets: [1, 5, 10, 25, 50, 100, 250]
            ]
          )
        ]
      )
    end

    # Message rate limit metrics from [:conduit_mcp, :message_rate_limit, :check]
    defp message_rate_limit_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_message_rate_limit_metrics,
        [
          # Counter: Message rate limit checks by status and method
          counter(
            metric_prefix ++ [:message_rate_limit, :check, :total],
            event_name: [:conduit_mcp, :message_rate_limit, :check],
            description: "Total number of MCP message rate limit checks",
            measurement: fn _measurements -> 1 end,
            tags: [:status, :method],
            tag_values: &extract_message_rate_limit_tags/1
          ),

          # Distribution: Message rate limit check duration
          distribution(
            metric_prefix ++ [:message_rate_limit, :check, :duration, duration_unit],
            event_name: [:conduit_mcp, :message_rate_limit, :check],
            description: "MCP message rate limit check duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:status, :method],
            tag_values: &extract_message_rate_limit_tags/1,
            reporter_options: [
              buckets: [1, 5, 10, 25, 50, 100, 250]
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

    # Cancellation metrics from [:conduit_mcp, :request, :cancelled],
    # [:conduit_mcp, :cancellation, :cleanup] and
    # [:conduit_mcp, :cancellation, :janitor]. Untagged: request ids, scopes
    # and reasons are unbounded or client-supplied.
    defp cancellation_metrics(metric_prefix) do
      Event.build(
        :conduit_mcp_cancellation_metrics,
        [
          counter(
            metric_prefix ++ [:request, :cancelled, :total],
            event_name: [:conduit_mcp, :request, :cancelled],
            description: "Total number of recorded MCP request cancellations",
            measurement: fn _measurements -> 1 end
          ),
          sum(
            metric_prefix ++ [:cancellation, :cleanup, :removed, :total],
            event_name: [:conduit_mcp, :cancellation, :cleanup],
            description: "Expired MCP cancellation rows removed",
            measurement: :removed
          ),
          sum(
            metric_prefix ++ [:cancellation, :cleanup, :in_flight_removed, :total],
            event_name: [:conduit_mcp, :cancellation, :cleanup],
            description: "In-flight rows of dead MCP request processes removed",
            measurement: :in_flight_removed
          ),
          # The janitor's `removed` is the cleanup pass's count again, so it
          # is counted per run rather than summed a second time.
          counter(
            metric_prefix ++ [:cancellation, :janitor, :runs, :total],
            event_name: [:conduit_mcp, :cancellation, :janitor],
            description: "Total number of MCP cancellation janitor runs",
            measurement: fn _measurements -> 1 end
          )
        ]
      )
    end

    # Janitor metrics from [:conduit_mcp, :session, :cleanup],
    # [:conduit_mcp, :tasks, :cleanup] and [:conduit_mcp, :ext_tasks, :cleanup].
    defp cleanup_metrics(metric_prefix) do
      Event.build(
        :conduit_mcp_cleanup_metrics,
        [
          sum(
            metric_prefix ++ [:session, :cleanup, :removed, :total],
            event_name: [:conduit_mcp, :session, :cleanup],
            description: "Expired MCP sessions evicted",
            measurement: :removed,
            tags: [:store],
            tag_values: &extract_store_tag/1
          ),
          sum(
            metric_prefix ++ [:tasks, :cleanup, :removed, :total],
            event_name: [:conduit_mcp, :tasks, :cleanup],
            description: "Terminal MCP tasks evicted",
            measurement: :removed
          ),
          sum(
            metric_prefix ++ [:ext_tasks, :cleanup, :removed, :total],
            event_name: [:conduit_mcp, :ext_tasks, :cleanup],
            description: "Expired MCP tasks-extension tasks evicted",
            measurement: :removed,
            tags: [:store],
            tag_values: &extract_store_tag/1
          )
        ]
      )
    end

    # MRTR metrics from [:conduit_mcp, :mrtr, :input_required]. `round` is
    # not a tag: it is unbounded.
    defp mrtr_metrics(metric_prefix) do
      Event.build(
        :conduit_mcp_mrtr_metrics,
        [
          counter(
            metric_prefix ++ [:mrtr, :input_required, :total],
            event_name: [:conduit_mcp, :mrtr, :input_required],
            description: "Total number of MCP InputRequiredResults sent",
            measurement: fn _measurements -> 1 end,
            tags: [:method],
            tag_values: &extract_method_tag/1
          ),
          sum(
            metric_prefix ++ [:mrtr, :input_requests, :total],
            event_name: [:conduit_mcp, :mrtr, :input_required],
            description: "MCP input requests sent in InputRequiredResults",
            measurement: :count,
            tags: [:method],
            tag_values: &extract_method_tag/1
          )
        ]
      )
    end

    # Client metrics from the [:conduit_mcp, :client, ...] events. Only
    # closed-set atoms and the client's own method names become tags.
    defp client_metrics(metric_prefix, duration_unit) do
      Event.build(
        :conduit_mcp_client_metrics,
        [
          counter(
            metric_prefix ++ [:client, :request, :start, :total],
            event_name: [:conduit_mcp, :client, :request, :start],
            description: "Total number of MCP client requests sent",
            measurement: fn _measurements -> 1 end,
            tags: [:method],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :request, :total],
            event_name: [:conduit_mcp, :client, :request, :stop],
            description: "Total number of finished MCP client requests",
            measurement: fn _measurements -> 1 end,
            tags: [:method, :status, :error_kind],
            tag_values: &extract_client_tags/1
          ),
          distribution(
            metric_prefix ++ [:client, :request, :duration, duration_unit],
            event_name: [:conduit_mcp, :client, :request, :stop],
            description: "MCP client request duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:method, :status],
            tag_values: &extract_client_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 60_000]
            ]
          ),
          counter(
            metric_prefix ++ [:client, :request, :exception, :total],
            event_name: [:conduit_mcp, :client, :request, :exception],
            description: "MCP client requests whose caller raised",
            measurement: fn _measurements -> 1 end,
            tags: [:method],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :tool_call, :start, :total],
            event_name: [:conduit_mcp, :client, :tool_call, :start],
            description: "Total number of MCP client tool calls started",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :tool_call, :total],
            event_name: [:conduit_mcp, :client, :tool_call, :stop],
            description: "Total number of finished MCP client tool calls",
            measurement: fn _measurements -> 1 end,
            tags: [:status, :error_kind, :is_error],
            tag_values: &extract_client_tags/1
          ),
          distribution(
            metric_prefix ++ [:client, :tool_call, :duration, duration_unit],
            event_name: [:conduit_mcp, :client, :tool_call, :stop],
            description: "MCP client tool call duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:status],
            tag_values: &extract_client_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 60_000]
            ]
          ),
          counter(
            metric_prefix ++ [:client, :tool_call, :exception, :total],
            event_name: [:conduit_mcp, :client, :tool_call, :exception],
            description: "MCP client tool calls whose caller raised",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :input_request, :start, :total],
            event_name: [:conduit_mcp, :client, :input_request, :start],
            description: "Server-to-client input requests the MCP client started answering",
            measurement: fn _measurements -> 1 end,
            tags: [:method],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :input_request, :total],
            event_name: [:conduit_mcp, :client, :input_request, :stop],
            description: "Server-to-client input requests the MCP client answered",
            measurement: fn _measurements -> 1 end,
            tags: [:method, :status],
            tag_values: &extract_client_tags/1
          ),
          distribution(
            metric_prefix ++ [:client, :input_request, :duration, duration_unit],
            event_name: [:conduit_mcp, :client, :input_request, :stop],
            description: "MCP client input request (handler) duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:method],
            tag_values: &extract_client_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 250, 500, 1_000, 5_000, 30_000, 60_000, 300_000]
            ]
          ),
          counter(
            metric_prefix ++ [:client, :input_request, :exception, :total],
            event_name: [:conduit_mcp, :client, :input_request, :exception],
            description: "MCP client input request handlers that raised",
            measurement: fn _measurements -> 1 end,
            tags: [:method],
            tag_values: &extract_client_tags/1
          ),
          last_value(
            metric_prefix ++ [:client, :transport, :mailbox, :message_queue_len],
            event_name: [:conduit_mcp, :client, :transport, :mailbox],
            description: "MCP client connection mailbox length when over its threshold",
            measurement: :message_queue_len
          ),
          counter(
            metric_prefix ++ [:client, :connection, :transition, :total],
            event_name: [:conduit_mcp, :client, :connection, :transition],
            description: "MCP client connection state changes",
            measurement: fn _measurements -> 1 end,
            tags: [:to, :reason],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :request, :cancel, :total],
            event_name: [:conduit_mcp, :client, :request, :cancel],
            description: "MCP client requests cancelled by the client",
            measurement: fn _measurements -> 1 end,
            tags: [:reason],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :response, :dropped, :total],
            event_name: [:conduit_mcp, :client, :response, :dropped],
            description: "Late MCP responses dropped by the client",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :notification, :total],
            event_name: [:conduit_mcp, :client, :notification],
            description: "MCP server notifications received by the client",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :cache, :refresh, :start, :total],
            event_name: [:conduit_mcp, :client, :cache, :refresh, :start],
            description: "MCP client cache refreshes started",
            measurement: fn _measurements -> 1 end,
            tags: [:kind],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :cache, :refresh, :total],
            event_name: [:conduit_mcp, :client, :cache, :refresh, :stop],
            description: "MCP client cache refreshes finished",
            measurement: fn _measurements -> 1 end,
            tags: [:kind, :status, :error_kind],
            tag_values: &extract_client_tags/1
          ),
          distribution(
            metric_prefix ++ [:client, :cache, :refresh, :duration, duration_unit],
            event_name: [:conduit_mcp, :client, :cache, :refresh, :stop],
            description: "MCP client cache refresh duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:kind, :status],
            tag_values: &extract_client_tags/1,
            reporter_options: [
              buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 60_000]
            ]
          ),
          counter(
            metric_prefix ++ [:client, :tool, :rejected, :total],
            event_name: [:conduit_mcp, :client, :tool, :rejected],
            description: "Tools dropped by the MCP client at intake",
            measurement: fn _measurements -> 1 end,
            tags: [:reason],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :tool, :definition_changed, :total],
            event_name: [:conduit_mcp, :client, :tool, :definition_changed],
            description: "Known tools whose definition changed on refresh",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :policy, :decision, :total],
            event_name: [:conduit_mcp, :client, :policy, :decision],
            description: "MCP client policy decisions",
            measurement: fn _measurements -> 1 end,
            tags: [:target, :decision, :source, :reason, :approval],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :hook, :total],
            event_name: [:conduit_mcp, :client, :hook, :stop],
            description: "MCP client hook runs",
            measurement: fn _measurements -> 1 end,
            tags: [:kind, :status],
            tag_values: &extract_client_tags/1
          ),
          distribution(
            metric_prefix ++ [:client, :hook, :duration, duration_unit],
            event_name: [:conduit_mcp, :client, :hook, :stop],
            description: "MCP client hook duration distribution",
            measurement: :duration,
            unit: {:native, duration_unit},
            tags: [:kind],
            tag_values: &extract_client_tags/1,
            reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1_000, 5_000, 60_000]]
          ),
          counter(
            metric_prefix ++ [:client, :hook, :exception, :total],
            event_name: [:conduit_mcp, :client, :hook, :exception],
            description: "MCP client hook failures",
            measurement: fn _measurements -> 1 end,
            tags: [:kind, :reason],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :hub, :server_failed, :total],
            event_name: [:conduit_mcp, :client, :hub, :server_failed],
            description: "MCP hub server clients that exited",
            measurement: fn _measurements -> 1 end,
            tags: [:reason],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :hub, :server_restarted, :total],
            event_name: [:conduit_mcp, :client, :hub, :server_restarted],
            description: "MCP hub servers started again after a failure",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :hub, :collision, :total],
            event_name: [:conduit_mcp, :client, :hub, :collision],
            description: "MCP hub exposed tool names left out after a collision",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:client, :adapter, :strict_fallback, :total],
            event_name: [:conduit_mcp, :client, :adapter, :strict_fallback],
            description: "OpenAI tools sent non-strict by the MCP client adapters",
            measurement: fn _measurements -> 1 end,
            tags: [:api, :reason],
            tag_values: &extract_client_tags/1
          ),
          counter(
            metric_prefix ++ [:client, :oauth, :authorization_required, :total],
            event_name: [:conduit_mcp, :client, :oauth, :authorization_required],
            description: "Times an MCP client needed the user to authorize",
            measurement: fn _measurements -> 1 end,
            tags: [:reason],
            tag_values: &extract_client_tags/1
          )
        ] ++ oauth_metrics(metric_prefix)
      )
    end

    # One start, stop and exception counter per OAuth operation; `status`
    # and `reason` (an OAuth error reason) are closed sets.
    defp oauth_metrics(metric_prefix) do
      for op <- [:discovery, :registration, :token_exchange, :refresh, :step_up],
          {suffix, event, tags} <- [
            {[:start, :total], :start, []},
            {[:total], :stop, [:status, :reason]},
            {[:exception, :total], :exception, []}
          ] do
        counter(
          metric_prefix ++ [:client, :oauth, op] ++ suffix,
          event_name: [:conduit_mcp, :client, :oauth, op, event],
          description: "MCP client OAuth #{op} #{event} events",
          measurement: fn _measurements -> 1 end,
          tags: tags,
          tag_values: &extract_client_tags/1
        )
      end
    end

    # Subscription metrics from [:conduit_mcp, :subscription, :start] and
    # [:conduit_mcp, :subscription, :stop]. `reason` is a closed set of
    # atoms; `filters` is a list, so it is not a tag. Durations are those of
    # long-lived streams, hence the coarse buckets and fixed unit.
    defp subscription_metrics(metric_prefix) do
      Event.build(
        :conduit_mcp_subscription_metrics,
        [
          counter(
            metric_prefix ++ [:subscription, :start, :total],
            event_name: [:conduit_mcp, :subscription, :start],
            description: "Total number of MCP subscriptions/listen streams opened",
            measurement: fn _measurements -> 1 end
          ),
          counter(
            metric_prefix ++ [:subscription, :stop, :total],
            event_name: [:conduit_mcp, :subscription, :stop],
            description: "Total number of MCP subscriptions/listen streams ended",
            measurement: fn _measurements -> 1 end,
            tags: [:reason],
            tag_values: &extract_reason_tag/1
          ),
          distribution(
            metric_prefix ++ [:subscription, :duration, :milliseconds],
            event_name: [:conduit_mcp, :subscription, :stop],
            description: "How long MCP subscriptions/listen streams stayed open",
            measurement: :duration,
            unit: {:native, :millisecond},
            tags: [:reason],
            tag_values: &extract_reason_tag/1,
            reporter_options: [
              buckets: [1_000, 10_000, 60_000, 300_000, 900_000, 1_800_000, 3_600_000]
            ]
          )
        ]
      )
    end

    # Tag extraction functions

    @client_tags [
      :method,
      :status,
      :error_kind,
      :is_error,
      :to,
      :reason,
      :kind,
      :target,
      :decision,
      :source,
      :approval,
      :api
    ]

    defp extract_client_tags(metadata) do
      for key <- @client_tags, Map.has_key?(metadata, key), into: %{} do
        {key, normalize_string(Map.fetch!(metadata, key))}
      end
    end

    defp extract_status_tag(%{status: status}), do: %{status: status}

    defp extract_reason_tag(%{reason: reason}), do: %{reason: reason}

    defp extract_store_tag(%{store: store}), do: %{store: normalize_string(store)}

    defp extract_method_tag(%{method: method}), do: %{method: normalize_string(method)}

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

    defp extract_message_rate_limit_tags(%{status: status, method: method}) do
      %{
        status: status,
        method: normalize_string(method || "unknown")
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

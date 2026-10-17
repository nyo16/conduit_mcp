defmodule ConduitMcp.Telemetry do
  # The single source of truth for every event: its name, its measurement
  # keys, the metadata keys every emission carries, and the metadata keys
  # only some emissions carry. `events/0`, the moduledoc's "Key reference"
  # table and the test that pins emitted key sets
  # (`test/conduit_mcp/telemetry_contract_test.exs`) are all derived from
  # it, so the three cannot drift apart. A new event goes here first.
  client = [:client, :server_id, :transport, :era]
  span_start = [:monotonic_time, :system_time]
  span_stop = [:duration, :monotonic_time]

  @event_specs [
    {[:conduit_mcp, :request, :stop], [:duration],
     [
       :method,
       :server_module,
       :status,
       :era,
       :protocol_version,
       :traceparent,
       :tracestate,
       :baggage
     ], []},
    {[:conduit_mcp, :tool, :execute], [:duration], [:tool_name, :server_module, :status], []},
    {[:conduit_mcp, :resource, :read], [:duration], [:uri, :server_module, :status], []},
    {[:conduit_mcp, :prompt, :get], [:duration], [:prompt_name, :server_module, :status], []},
    {[:conduit_mcp, :rate_limit, :check], [:duration], [:key, :status], [:count, :retry_after]},
    {[:conduit_mcp, :message_rate_limit, :check], [:duration], [:key, :status, :method],
     [:count, :retry_after]},
    {[:conduit_mcp, :auth, :verify], [:duration], [:strategy, :status], [:reason]},
    {[:conduit_mcp, :request, :cancelled], [:count], [:request_id, :scope, :reason], []},
    {[:conduit_mcp, :cancellation, :cleanup], [:removed, :in_flight_removed], [], []},
    {[:conduit_mcp, :cancellation, :janitor], [:removed], [:store], []},
    {[:conduit_mcp, :session, :cleanup], [:removed], [:store], []},
    {[:conduit_mcp, :tasks, :cleanup], [:removed], [], []},
    {[:conduit_mcp, :mrtr, :input_required], [:count], [:method, :server_module, :round], []},
    {[:conduit_mcp, :client, :request, :start], span_start, client ++ [:method], []},
    {[:conduit_mcp, :client, :request, :stop], span_stop,
     client ++ [:method, :status, :error_kind, :request_id], []},
    {[:conduit_mcp, :client, :request, :exception], span_stop, client ++ [:method, :kind], []},
    {[:conduit_mcp, :client, :tool_call, :start], span_start, client ++ [:tool_name], []},
    {[:conduit_mcp, :client, :tool_call, :stop], span_stop ++ [:rounds],
     client ++ [:tool_name, :status, :error_kind, :is_error], []},
    {[:conduit_mcp, :client, :tool_call, :exception], span_stop, client ++ [:tool_name, :kind],
     []},
    {[:conduit_mcp, :client, :input_request, :start], span_start, client ++ [:method], []},
    {[:conduit_mcp, :client, :input_request, :stop], span_stop, client ++ [:method, :status], []},
    {[:conduit_mcp, :client, :input_request, :exception], span_stop, client ++ [:method, :kind],
     []},
    {[:conduit_mcp, :client, :connection, :transition], [:system_time],
     client ++ [:from, :to, :reason, :attempt], []},
    {[:conduit_mcp, :client, :request, :cancel], [:count],
     client ++ [:method, :request_id, :reason], []},
    {[:conduit_mcp, :client, :response, :dropped], [:count], client ++ [:request_id], []},
    {[:conduit_mcp, :client, :notification], [:count], client ++ [:method], []},
    {[:conduit_mcp, :client, :transport, :mailbox], [:message_queue_len], client, []},
    {[:conduit_mcp, :subscription, :start], [:system_time, :resource_subscriptions],
     [:filters, :server_module], []},
    {[:conduit_mcp, :subscription, :stop], [:duration], [:filters, :server_module, :reason], []},
    {[:conduit_mcp, :ext_tasks, :cleanup], [:removed], [:store], []},
    {[:conduit_mcp, :client, :cache, :refresh, :start], span_start, client ++ [:kind, :trigger],
     []},
    {[:conduit_mcp, :client, :cache, :refresh, :stop], span_stop ++ [:count, :pages, :rejected],
     client ++ [:kind, :trigger, :status, :error_kind], []},
    {[:conduit_mcp, :client, :tool, :rejected], [:count], client ++ [:tool_name, :reason], []},
    {[:conduit_mcp, :client, :tool, :definition_changed], [:count], client ++ [:tool_name], []},
    {[:conduit_mcp, :client, :policy, :decision], [:count],
     client ++ [:target, :decision, :source, :reason, :rule_id, :approval],
     [:tool_name, :principal]},
    {[:conduit_mcp, :client, :hook, :stop], span_stop, client ++ [:hook_id, :kind, :status],
     [:tool_name]},
    {[:conduit_mcp, :client, :hook, :exception], span_stop, client ++ [:hook_id, :kind, :reason],
     [:tool_name]},
    {[:conduit_mcp, :client, :hub, :server_failed], [:count, :delay],
     [:hub, :server_id, :attempt, :reason], []},
    {[:conduit_mcp, :client, :hub, :server_restarted], [:count], [:hub, :server_id, :attempt],
     []},
    {[:conduit_mcp, :client, :hub, :collision], [:count], [:hub, :exposed_name, :colliders], []},
    {[:conduit_mcp, :client, :adapter, :strict_fallback], [:count],
     [:client, :provider, :api, :tool_name, :reason], []}
  ]

  keys = fn
    [] -> "-"
    list -> Enum.map_join(list, ", ", &"`#{inspect(&1)}`")
  end

  @key_table Enum.map_join(@event_specs, "\n", fn {event, measurements, always, sometimes} ->
               "| `#{inspect(event)}` | #{keys.(measurements)} | #{keys.(always)} | " <>
                 "#{keys.(sometimes)} |"
             end)

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

    * `:method` (String.t | nil) - The MCP method that was called
      (e.g., `"initialize"`, `"tools/list"`, `"tools/call"`); `nil` when the
      request's `"method"` is missing or not a string
    * `:server_module` (module) - The MCP server module handling the request
    * `:status` (:ok | :error) - Whether the request succeeded or failed
    * `:era` (:modern | :legacy) - The request's protocol era (see
      `ConduitMcp.Era`)
    * `:protocol_version` (String.t | nil) - The modern request's `_meta`
      protocol version, or the legacy session's negotiated version; `nil`
      when neither is known
    * `:traceparent`, `:tracestate`, `:baggage` (String.t | nil) - W3C trace
      context from the request's `_meta`, already validated (`traceparent`
      well-formed, `tracestate`/`baggage` at most 512 bytes of printable
      ASCII); `nil` when absent or invalid

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

    * `:tool_name` (String.t | nil) - Name of the tool that was executed;
      `nil` when the client's `"name"` is missing or not a string
    * `:server_module` (module) - The MCP server module
    * `:status` (:ok | :error) - Whether the tool executed successfully (an
      MRTR `input_required` round counts as `:ok`)

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

    * `:uri` (String.t | nil) - URI of the resource that was read; `nil` when
      the client's `"uri"` is missing or not a string
    * `:server_module` (module) - The MCP server module
    * `:status` (:ok | :error) - Whether the read succeeded or failed (an
      MRTR `input_required` round counts as `:ok`)

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

    * `:prompt_name` (String.t | nil) - Name of the prompt that was retrieved;
      `nil` when the client's `"name"` is missing or not a string
    * `:server_module` (module) - The MCP server module
    * `:status` (:ok | :error) - Whether the prompt retrieval succeeded (an
      MRTR `input_required` round counts as `:ok`)

  **Example:**

      :telemetry.attach(
        "track-prompt-usage",
        [:conduit_mcp, :prompt, :get],
        fn _event, _measurements, metadata, _config ->
          Logger.info("Prompt requested: \#{metadata.prompt_name}")
        end,
        nil
      )

  ### MRTR Events

  #### `[:conduit_mcp, :mrtr, :input_required]`

  Emitted when a modern-era `tools/call`, `resources/read` or `prompts/get`
  answers with an `InputRequiredResult` (see "Multi round-trip requests
  (MRTR)" in `ConduitMcp.Server`) — after the input requests passed the
  client-capability check and the state was sealed. Not emitted for a
  rejected round (`-32021`, `-32603`).

  **Measurements:**

    * `:count` (integer) - Number of input requests in the result

  **Metadata:**

    * `:method` (String.t) - `"tools/call"`, `"resources/read"` or
      `"prompts/get"`
    * `:server_module` (module) - The MCP server module
    * `:round` (pos_integer) - Which `input_required` round of the exchange
      this is: `1` for a first request, `n + 1` for a retry whose verified
      `requestState` came from round `n`

  Neither the input requests, the state nor the `requestState` token is
  included.

  ### Subscription Events

  A modern `subscriptions/listen` stream (see `ConduitMcp.Subscriptions`)
  emits these instead of `[:conduit_mcp, :request, :stop]`: its duration is
  how long the stream stayed open, which would swamp a latency metric. A
  listen refused before its stream opened (HTTP 406, 429 or 503) emits
  neither.

  #### `[:conduit_mcp, :subscription, :start]`

  Emitted once the stream's SSE response has started, just before the
  acknowledgment is written.

  **Measurements:**

    * `:system_time` (integer) - `System.system_time/0` at the start
    * `:resource_subscriptions` (integer) - Number of resource URIs honoured

  **Metadata:**

    * `:filters` ([atom]) - The filter fields honoured, a subset of
      `:tools_list_changed`, `:prompts_list_changed`,
      `:resources_list_changed`, `:resource_subscriptions` and `:task_ids`
      (`ConduitMcp.Ext.Tasks` enabled only)
    * `:server_module` (module) - The MCP server module

  #### `[:conduit_mcp, :subscription, :stop]`

  Emitted when the stream ends.

  **Measurements:**

    * `:duration` (integer) - How long the stream was open, in native time
      units

  **Metadata:**

    * `:filters` ([atom]) - As on `:start`
    * `:server_module` (module) - The MCP server module
    * `:reason` (atom) - `:client_closed` (the client went away),
      `:max_lifetime` (`:max_stream_lifetime` reached), `:token_expired`
      (the bearer token's `exp` passed) or `:idle_timeout`
      (`:listen_idle_timeout` without a notification). Every reason but
      `:client_closed` ended with `notifications/cancelled` and the
      graceful-closure result.

  Neither event carries the resource URIs, the listen request id or the
  principal.

  ### Rate Limiting Events

  #### `[:conduit_mcp, :rate_limit, :check]`

  Emitted when a rate limit check is performed.

  **Measurements:**

    * `:duration` (integer) - Rate limit check duration in native time units

  **Metadata:**

    * `:key` (String.t) - The rate limit key (e.g., IP address or user ID)
    * `:status` (:allow | :deny) - Whether the request was allowed or denied
    * `:count` (integer) - Current request count (only when status is :allow)
    * `:retry_after` (integer) - Seconds until the limit resets (only when status is :deny)

  **Example:**

      :telemetry.attach(
        "track-rate-limits",
        [:conduit_mcp, :rate_limit, :check],
        fn _event, _measurements, metadata, _config ->
          if metadata.status == :deny do
            Logger.warning("Rate limited: key=\#{metadata.key}")
          end
        end,
        nil
      )

  ### Message Rate Limiting Events

  #### `[:conduit_mcp, :message_rate_limit, :check]`

  Emitted when a message-level rate limit check is performed.

  **Measurements:**

    * `:duration` (integer) - Rate limit check duration in native time units

  **Metadata:**

    * `:key` (String.t) - The rate limit key (e.g., `"msg:user:123"` or `"msg:127.0.0.1"`)
    * `:status` (:allow | :deny) - Whether the message was allowed or denied
    * `:method` (String.t | nil) - The MCP method being rate limited
    * `:count` (integer) - Current message count (only when status is :allow)
    * `:retry_after` (integer) - Seconds until the limit resets (only when status is :deny)

  **Example:**

      :telemetry.attach(
        "track-message-rate-limits",
        [:conduit_mcp, :message_rate_limit, :check],
        fn _event, _measurements, metadata, _config ->
          if metadata.status == :deny do
            Logger.warning("Message rate limited: key=\#{metadata.key} method=\#{metadata.method}")
          end
        end,
        nil
      )

  ### Authentication Events

  #### `[:conduit_mcp, :auth, :verify]`

  Emitted when authentication verification is performed.

  **Measurements:**

    * `:duration` (integer) - Authentication verification duration in native time units

  **Metadata:**

    * `:strategy` (:bearer_token | :api_key | :function | :oauth) - Auth strategy used
      (the deprecated `:custom` strategy reports `:function`)
    * `:status` (:ok | :error) - Whether authentication succeeded
    * `:reason` (atom) - Failure reason, only present when status is `:error`. Always an
      atom, never verifier or token text: `:invalid_credential` / `:invalid_return` from
      `ConduitMcp.Plugs.Auth`; for `:oauth`, one of the set in the "Telemetry" section of
      `ConduitMcp.Plugs.OAuth`

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

  ### Cancellation Events

  #### `[:conduit_mcp, :request, :cancelled]`

  Emitted when a `notifications/cancelled` is recorded for a request in flight
  in the caller's scope (see `ConduitMcp.Cancellation`).

  **Measurements:**

    * `:count` (integer) - Always `1`

  **Metadata:**

    * `:request_id` (String.t | integer) - The cancelled request's JSON-RPC id
    * `:scope` (String.t) - The caller's cancellation scope (`"session:..."`,
      `"principal:..."` or `"ip:..."`)
    * `:reason` (String.t | nil) - The client's reason, clamped and stripped of
      control characters. Client-supplied: never use it as a metric tag.

  #### `[:conduit_mcp, :cancellation, :cleanup]`

  Emitted on every `ConduitMcp.Cancellation.cleanup/1` pass.

  **Measurements:**

    * `:removed` (integer) - Expired cancellation rows deleted
    * `:in_flight_removed` (integer) - In-flight rows of dead request
      processes deleted

  **Metadata:** none (`%{}`).

  ### Janitor Events

  Emitted after each periodic sweep of the tables `ConduitMcp.Application`
  owns.

  #### `[:conduit_mcp, :session, :cleanup]`

  From `ConduitMcp.Session.Janitor` sweeping expired sessions.

  **Measurements:** `:removed` (integer) - Sessions evicted.

  **Metadata:** `:store` (module) - The session store swept.

  #### `[:conduit_mcp, :cancellation, :janitor]`

  From the cancellation janitor (a `ConduitMcp.Session.Janitor` over
  `ConduitMcp.Cancellation`). Its `:removed` is the same count the run's
  `[:conduit_mcp, :cancellation, :cleanup]` reports, so count runs with it
  rather than summing both.

  **Measurements:** `:removed` (integer) - Cancellation rows evicted.

  **Metadata:** `:store` (module) - `ConduitMcp.Cancellation`.

  #### `[:conduit_mcp, :tasks, :cleanup]`

  From `ConduitMcp.Tasks.Janitor` sweeping terminal tasks.

  **Measurements:** `:removed` (integer) - Tasks evicted.

  **Metadata:** none (`%{}`).

  ### Client Events

  Emitted by `ConduitMcp.Client`. Metadata comes from a fixed allowlist and
  never carries tool arguments, results, `_meta`, tokens or raw error data.
  Every client event's metadata has:

    * `:client` (term) - the client's `:name`
    * `:server_id` (String.t) - the client's `:server_id`
    * `:transport` (atom) - the transport kind (`:stdio`, `:http`,
      `:in_process`)
    * `:era` (:modern | :legacy | nil) - the negotiated era; `nil` before
      the first handshake

  The `request`, `tool_call` and `input_request` spans, `policy.decision`
  and the `hook` events are emitted **in the calling process**, so tracing
  bridges nest them under the caller's span, and `tool.rejected` in the
  process that fetched the tool list (a caller, or a cache refresh task).
  The other client events are emitted inside the client's connection
  process: their handlers must be fast.

  #### `[:conduit_mcp, :client, :request, :start | :stop | :exception]`

  One span per request sent (each round of a multi-round-trip call is its
  own request).

  **Measurements:** `:start` has `:monotonic_time` and `:system_time`;
  `:stop` and `:exception` have `:duration` (native units) and
  `:monotonic_time`.

  **Metadata:** the common keys, plus `:method` (String.t). `:stop` adds
  `:status` (:ok | :error), `:error_kind` (a `ConduitMcp.Client.Error` kind
  or `nil`) and `:request_id` (integer, or `nil` if never sent).
  `:exception` (a raise in an `:on_progress` callback) adds `:kind`.

  #### `[:conduit_mcp, :client, :tool_call, :start | :stop | :exception]`

  One span per `ConduitMcp.Client.call_tool/4`, around all its rounds.

  **Measurements:** as for `request`; `:stop` adds `:rounds` (integer).

  **Metadata:** the common keys, plus `:tool_name` (String.t, sanitized).
  `:stop` adds `:status`, `:error_kind` and `:is_error` (boolean, or `nil`
  when no result came back).

  #### `[:conduit_mcp, :client, :connection, :transition]`

  The connection changed state (see `ConduitMcp.Client.Connection`).

  **Measurements:** `:system_time`.

  **Metadata:** the common keys, plus `:from` (atom, `nil` at start), `:to`
  (atom), `:reason` (atom - a closed-set tag of the cause, `nil` when none)
  and `:attempt` (integer - consecutive reconnect attempts).

  #### `[:conduit_mcp, :client, :request, :cancel]`

  The connection cancelled an in-flight request.

  **Measurements:** `:count` (always `1`).

  **Metadata:** the common keys, plus `:method`, `:request_id` and
  `:reason` (:timeout | :caller_down | :caller_timeout).

  #### `[:conduit_mcp, :client, :response, :dropped]`

  A response arrived for a request that is no longer pending (late, or
  cancelled).

  **Measurements:** `:count` (always `1`).

  **Metadata:** the common keys, plus `:request_id` (integer, or `nil` for
  an id the client never issued).

  #### `[:conduit_mcp, :client, :notification]`

  A server notification reached the connection.

  **Measurements:** `:count` (always `1`).

  **Metadata:** the common keys, plus `:method` (String.t, sanitized;
  server-supplied, so never use it as a metric tag).

  #### `[:conduit_mcp, :ext_tasks, :cleanup]`

  From the `ConduitMcp.Ext.Tasks` janitor (a `ConduitMcp.Session.Janitor`,
  started only when the experimental tasks extension is enabled) evicting
  expired tasks.

  **Measurements:** `:removed` (integer) - Tasks evicted.

  **Metadata:** `:store` (module) - The `ConduitMcp.Ext.Tasks.Store` swept.

  #### `[:conduit_mcp, :client, :cache, :refresh, :start | :stop]`

  The connection refreshed one cached list (`ConduitMcp.Client.Cache`): on
  demand, or after a `list_changed` notification. The fetch itself runs in
  a task; these events bracket it.

  **Measurements:** `:start` has `:monotonic_time` and `:system_time`;
  `:stop` has `:duration` (native units), `:monotonic_time`, `:count`
  (items kept), `:pages` and `:rejected` (tools dropped at intake); the
  counts are 0 when the refresh failed.

  **Metadata:** the common keys, plus `:kind` (:tools | :prompts |
  :resources | :resource_templates) and `:trigger` (:demand |
  :list_changed). `:stop` adds `:status` (:ok | :error) and `:error_kind`.

  #### `[:conduit_mcp, :client, :tool, :rejected]`

  A tool a server listed was dropped at intake (see `ConduitMcp.Client`,
  "Listing and the cache").

  **Measurements:** `:count` (always `1`).

  **Metadata:** the common keys, plus `:tool_name` (String.t | nil - the
  name with every character outside `[A-Za-z0-9_-]` replaced by `_`;
  server-supplied, never a metric tag) and `:reason` (:invalid_name |
  :invalid_definition | :duplicate_name | :invalid_x_mcp_header, or
  :collision when a `ConduitMcp.Client.Hub` or `ConduitMcp.Client.Adapters`
  toolset left the tool out because its exposed name collided).

  #### `[:conduit_mcp, :client, :tool, :definition_changed]`

  A refreshed tool list changed the definition (the
  `ConduitMcp.Client.Fingerprint`) of a tool the client already knew.

  **Measurements:** `:count` (always `1`).

  **Metadata:** the common keys, plus `:tool_name` (String.t, sanitized;
  server-supplied, never a metric tag).

  #### `[:conduit_mcp, :client, :policy, :decision]`

  `ConduitMcp.Client.Pipeline` decided a governed tool call, resource read
  or prompt get (`ConduitMcp.Client.Policy`), after any approval.

  **Measurements:** `:count` (always `1`).

  **Metadata:** the common keys, plus:

    * `:target` (:tool | :resource | :prompt)
    * `:tool_name` (String.t, sanitized; tools only; never a metric tag)
    * `:decision` (:allow | :ask | :deny) - the policy's decision
    * `:source` (:deny | :ask | :allow | :pin | :default)
    * `:reason` (atom) - a `ConduitMcp.Client.Policy.Decision` reason, or
      `:no_policy` when a `{:named, name}` policy is not stored
    * `:rule_id` (term) - the deciding rule's id, `nil` for the pin and the
      default (operator-chosen, so not a metric tag)
    * `:approval` (:grant | :once | :always | :denied | :halted | :failed |
      nil) - how an `:ask` was settled: a live grant, the approver's
      answer, or `:failed` (a raise, exit, timeout or bad return); `nil`
      when the decision was not `:ask`
    * `:principal` (term) - the call's `:principal`, only when given

  #### `[:conduit_mcp, :client, :hook, :stop]`

  A `ConduitMcp.Client.Hooks` hook returned within its contract.

  **Measurements:** `:duration` (native units) and `:monotonic_time`.

  **Metadata:** the common keys, plus `:hook_id` (the hook's `:id`),
  `:kind` (the hook event: :pre_tool_call | :post_tool_call |
  :tool_call_failed | :on_tools_listed | :on_resource_read |
  :on_prompt_get), `:status` (:cont | :rewrite | :deny | :halt | :recover)
  and, for tool hooks, `:tool_name` (sanitized).

  #### `[:conduit_mcp, :client, :hook, :exception]`

  A hook raised, threw, exited, timed out or returned outside its contract;
  the call failed closed, the result was withheld, or (with
  `on_error: :ignore`) the hook was skipped. What the hook raised is never
  included.

  **Measurements:** as for `hook.stop`.

  **Metadata:** as for `hook.stop`, with `:reason` (:raise | :exit |
  :timeout | :bad_return) instead of `:status`.

  #### `[:conduit_mcp, :client, :input_request, :start | :stop | :exception]`

  One span per server-to-client input request the client's
  `ConduitMcp.Client.Handler` answers (`sampling/createMessage`,
  `elicitation/create`, `roots/list`), in either era: in the calling
  process for a modern multi-round-trip input request, in the
  connection's handler task for a legacy server request. The span covers
  the safety checks and the handler callback; neither the request's
  params nor the answer is included.

  **Measurements:** as for `request`.

  **Metadata:** the common keys, plus `:method` (one of the three
  methods above, or `nil` for any other). `:stop` adds `:status` (:ok when
  an answer is sent, :error when an error is); `:exception` (the handler
  raised, threw or exited) adds `:kind`.

  #### `[:conduit_mcp, :client, :transport, :mailbox]`

  The connection's mailbox holds more than 1 000 messages: it is not
  keeping up with what the server sends (a stdio port or an HTTP stream
  has no back-pressure). Sampled once every 64 transport messages, so a
  backlog emits it repeatedly until it drains.

  **Measurements:** `:message_queue_len` (integer).

  **Metadata:** the common keys.

  ### Hub and Adapter Events

  Emitted by `ConduitMcp.Client.Hub` and `ConduitMcp.Client.Adapters`. The
  hub events carry `:hub` (the hub's `:name`) instead of the client keys
  above; `adapter.strict_fallback` carries `:client` (the hub's or client's
  name).

  #### `[:conduit_mcp, :client, :hub, :server_failed]`

  A hub server's client exited (it crashed, or its supervisor gave up).
  Emitted in the hub's manager process, which starts it again after a
  jittered backoff.

  **Measurements:** `:count` (always `1`) and `:delay` (milliseconds until
  the restart).

  **Metadata:** `:hub`, `:server_id` (String.t), `:attempt` (integer -
  consecutive failures) and `:reason` (atom - a closed-set tag of the exit
  reason, `:other` when it is not an atom or tagged tuple).

  #### `[:conduit_mcp, :client, :hub, :server_restarted]`

  The hub started a failed server's client again.

  **Measurements:** `:count` (always `1`).

  **Metadata:** `:hub`, `:server_id` and `:attempt`.

  #### `[:conduit_mcp, :client, :hub, :collision]`

  Two or more tools mangled to the same exposed name, so none of them is
  offered (HB-1). Emitted in the caller that built the toolset, once per
  distinct tool list (each tool also gets a `tool.rejected` with reason
  `:collision`).

  **Measurements:** `:count` (the number of colliding tools).

  **Metadata:** `:hub`, `:exposed_name` (String.t) and `:colliders`
  (`[{server_id, tool_name}]`, tool names sanitized; never a metric tag).

  #### `[:conduit_mcp, :client, :adapter, :strict_fallback]`

  `ConduitMcp.Client.Adapters.tools/3` sent an OpenAI tool with
  `"strict": false` because its schema cannot be converted to strict mode
  (`strict: :auto`).

  **Measurements:** `:count` (always `1`).

  **Metadata:** `:client`, `:provider` (`:openai`), `:api` (:chat |
  :responses), `:tool_name` (the exposed name; never a metric tag) and
  `:reason` (:unsupported_keyword, or the strict-mode limit exceeded:
  :max_properties | :max_depth | :max_chars | :max_enum_values |
  :max_enum_chars).

  ### Key reference

  Every event with the exact keys it carries. "Always" keys are in every
  emission; "Sometimes" keys only where the event's section says. No
  emission carries a key outside these two columns: a test pins each
  emitted key set to this table, which is generated from the same list as
  `events/0`.

  | Event | Measurements | Metadata (always) | Metadata (sometimes) |
  |---|---|---|---|
  #{@key_table}

  ## Common Use Cases

  ### Logging Request Activity

      defmodule MyApp.MCPTelemetry do
        require Logger

        def attach_handlers do
          events = [
            [:conduit_mcp, :request, :stop],
            [:conduit_mcp, :tool, :execute],
            [:conduit_mcp, :resource, :read],
            [:conduit_mcp, :prompt, :get],
            [:conduit_mcp, :rate_limit, :check],
            [:conduit_mcp, :message_rate_limit, :check],
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

        def handle_event([:conduit_mcp, :rate_limit, :check], measurements, metadata, _config) do
          Logger.info("Rate limit check",
            key: metadata.key,
            status: metadata.status,
            duration_ms: convert_duration(measurements.duration)
          )
        end

        def handle_event([:conduit_mcp, :message_rate_limit, :check], measurements, metadata, _config) do
          Logger.info("Message rate limit check",
            key: metadata.key,
            method: metadata.method,
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

            # Rate limit check count
            counter("conduit_mcp.rate_limit.check.count",
              tags: [:status],
              description: "Rate limit checks"
            ),

            # Rate limit check duration
            distribution("conduit_mcp.rate_limit.check.duration",
              unit: {:native, :millisecond},
              description: "Rate limit check duration"
            ),

            # Message rate limit check count
            counter("conduit_mcp.message_rate_limit.check.count",
              tags: [:status, :method],
              description: "Message rate limit checks"
            ),

            # Message rate limit check duration
            distribution("conduit_mcp.message_rate_limit.check.duration",
              unit: {:native, :millisecond},
              description: "Message rate limit check duration"
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
  Returns all telemetry event names emitted by ConduitMCP, in the order of
  the moduledoc's "Key reference" table.

  ## Example

      iex> [:conduit_mcp, :client, :tool_call, :stop] in ConduitMcp.Telemetry.events()
      true
  """
  @spec events() :: [[:conduit_mcp, ...]]
  def events, do: for({event, _measurements, _always, _sometimes} <- @event_specs, do: event)

  @doc false
  # `{event, measurement_keys, always_metadata_keys, sometimes_metadata_keys}`
  # for every event; what the key-set test pins emissions against.
  @spec __event_specs__() :: [{[atom(), ...], [atom()], [atom()], [atom()]}]
  def __event_specs__, do: @event_specs

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

  # Private: Default event handlers for logging.
  #
  # `method`, `tool_name`, `uri` and `prompt_name` come from the client's
  # JSON-RPC body, so they go through `ConduitMcp.Reflect.text/2` rather than
  # bare interpolation: a map or tuple would raise `Protocol.UndefinedError`,
  # and `:telemetry` detaches a handler that raises - from every event it is
  # attached to - so one request would silence the whole default logger. A
  # `\n` would forge a log line. `Reflect.text/2` renders `nil` as `""`.
  defp handle_event([:conduit_mcp, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "MCP request completed: method=#{ConduitMcp.Reflect.text(metadata.method)} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :tool, :execute], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Tool executed: tool=#{ConduitMcp.Reflect.text(metadata.tool_name)} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :resource, :read], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Resource read: uri=#{ConduitMcp.Reflect.text(metadata.uri)} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :prompt, :get], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Prompt retrieved: prompt=#{ConduitMcp.Reflect.text(metadata.prompt_name)} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:conduit_mcp, :rate_limit, :check], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    level = if metadata.status == :allow, do: :debug, else: :warning

    Logger.log(
      level,
      "Rate limit check: key=#{metadata.key} status=#{metadata.status} duration=#{duration_ms}ms"
    )
  end

  defp handle_event(
         [:conduit_mcp, :message_rate_limit, :check],
         measurements,
         metadata,
         _config
       ) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    level = if metadata.status == :allow, do: :debug, else: :warning

    Logger.log(
      level,
      "Message rate limit check: key=#{metadata.key} method=#{ConduitMcp.Reflect.text(metadata.method)} status=#{metadata.status} duration=#{duration_ms}ms"
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

  # The client's `reason` is not logged: it is free text from the request.
  defp handle_event([:conduit_mcp, :request, :cancelled], _measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "Request cancelled: request_id=#{ConduitMcp.Reflect.text(metadata.request_id, 64)} scope=#{ConduitMcp.Reflect.text(metadata.scope)}"
    )
  end

  defp handle_event([:conduit_mcp, :cancellation, :cleanup], measurements, _metadata, _config) do
    require Logger

    Logger.debug(
      "Cancellation cleanup: removed=#{measurements.removed} in_flight_removed=#{measurements.in_flight_removed}"
    )
  end

  defp handle_event([:conduit_mcp, scope, event], measurements, metadata, _config)
       when {scope, event} in [
              {:cancellation, :janitor},
              {:session, :cleanup},
              {:tasks, :cleanup},
              {:ext_tasks, :cleanup}
            ] do
    require Logger

    Logger.debug(
      "Janitor run: #{scope}.#{event} removed=#{measurements.removed} store=#{inspect(metadata[:store])}"
    )
  end

  defp handle_event([:conduit_mcp, :mrtr, :input_required], measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MRTR input required: method=#{metadata.method} round=#{metadata.round} count=#{measurements.count}"
    )
  end

  # Client events. `client` is any term the user chose and `method` /
  # `tool_name` may be server-supplied, so all go through `Reflect.text/2`.
  # Span starts are not logged; their stop or exception is.
  defp handle_event([:conduit_mcp, :client, span, :start], _measurements, _metadata, _config)
       when span in [:request, :tool_call, :input_request],
       do: :ok

  defp handle_event([:conduit_mcp, :client, :request, :stop], measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client request: client=#{client_text(metadata)} method=#{ConduitMcp.Reflect.text(metadata.method)} status=#{metadata.status} error_kind=#{metadata.error_kind} duration=#{duration_ms(measurements)}ms"
    )
  end

  defp handle_event([:conduit_mcp, :client, :tool_call, :stop], measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client tool call: client=#{client_text(metadata)} tool=#{ConduitMcp.Reflect.text(metadata.tool_name)} status=#{metadata.status} is_error=#{metadata.is_error} rounds=#{measurements.rounds} duration=#{duration_ms(measurements)}ms"
    )
  end

  defp handle_event([:conduit_mcp, :client, span, :exception], _measurements, metadata, _config)
       when span in [:request, :tool_call, :input_request] do
    require Logger

    Logger.warning(
      "MCP client #{span} raised in the caller: client=#{client_text(metadata)} kind=#{metadata.kind}"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :input_request, :stop],
         measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.debug(
      "MCP client input request: client=#{client_text(metadata)} method=#{ConduitMcp.Reflect.text(metadata.method)} status=#{metadata.status} duration=#{duration_ms(measurements)}ms"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :transport, :mailbox],
         measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.warning(
      "MCP client connection is falling behind: client=#{client_text(metadata)} message_queue_len=#{measurements.message_queue_len}"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :connection, :transition],
         _measurements,
         metadata,
         _config
       ) do
    require Logger

    level = if metadata.to in [:reconnecting, :closed], do: :info, else: :debug

    Logger.log(
      level,
      "MCP client connection: client=#{client_text(metadata)} #{metadata.from} -> #{metadata.to} reason=#{metadata.reason} attempt=#{metadata.attempt}"
    )
  end

  defp handle_event([:conduit_mcp, :client, :request, :cancel], _measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client cancelled a request: client=#{client_text(metadata)} method=#{ConduitMcp.Reflect.text(metadata.method)} request_id=#{metadata.request_id} reason=#{metadata.reason}"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :response, :dropped],
         _measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.debug(
      "MCP client dropped a response: client=#{client_text(metadata)} request_id=#{metadata.request_id}"
    )
  end

  defp handle_event([:conduit_mcp, :client, :notification], _measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client notification: client=#{client_text(metadata)} method=#{ConduitMcp.Reflect.text(metadata.method)}"
    )
  end

  defp handle_event([:conduit_mcp, :subscription, :start], measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "Subscription started: filters=#{inspect(metadata.filters)} resource_subscriptions=#{measurements.resource_subscriptions}"
    )
  end

  defp handle_event([:conduit_mcp, :subscription, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    require Logger

    Logger.debug(
      "Subscription stopped: reason=#{metadata.reason} filters=#{inspect(metadata.filters)} duration=#{duration_ms}ms"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :cache, :refresh, :start],
         _measurements,
         _metadata,
         _config
       ),
       do: :ok

  defp handle_event(
         [:conduit_mcp, :client, :cache, :refresh, :stop],
         measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.debug(
      "MCP client cache refresh: client=#{client_text(metadata)} kind=#{metadata.kind} trigger=#{metadata.trigger} status=#{metadata.status} count=#{measurements.count} pages=#{measurements.pages} rejected=#{measurements.rejected} duration=#{duration_ms(measurements)}ms"
    )
  end

  defp handle_event([:conduit_mcp, :client, :tool, :rejected], _measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client rejected a tool: client=#{client_text(metadata)} tool=#{ConduitMcp.Reflect.text(metadata.tool_name)} reason=#{metadata.reason}"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :tool, :definition_changed],
         _measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.info(
      "MCP client tool definition changed: client=#{client_text(metadata)} tool=#{ConduitMcp.Reflect.text(metadata.tool_name)}"
    )
  end

  defp handle_event([:conduit_mcp, :client, :policy, :decision], _measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client policy decision: client=#{client_text(metadata)} target=#{metadata.target} tool=#{ConduitMcp.Reflect.text(Map.get(metadata, :tool_name))} decision=#{metadata.decision} source=#{metadata.source} reason=#{metadata.reason} rule_id=#{ConduitMcp.Reflect.text(metadata.rule_id, 64)} approval=#{metadata.approval}"
    )
  end

  defp handle_event([:conduit_mcp, :client, :hook, :stop], measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP client hook: client=#{client_text(metadata)} hook=#{ConduitMcp.Reflect.text(metadata.hook_id, 64)} kind=#{metadata.kind} status=#{metadata.status} duration=#{duration_ms(measurements)}ms"
    )
  end

  defp handle_event([:conduit_mcp, :client, :hook, :exception], measurements, metadata, _config) do
    require Logger

    Logger.warning(
      "MCP client hook failed: client=#{client_text(metadata)} hook=#{ConduitMcp.Reflect.text(metadata.hook_id, 64)} kind=#{metadata.kind} reason=#{metadata.reason} duration=#{duration_ms(measurements)}ms"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :hub, :server_failed],
         measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.warning(
      "MCP hub server failed: hub=#{ConduitMcp.Reflect.text(metadata.hub, 64)} server=#{metadata.server_id} reason=#{metadata.reason} attempt=#{metadata.attempt} retry_in=#{measurements.delay}ms"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :hub, :server_restarted],
         _measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.info(
      "MCP hub server restarted: hub=#{ConduitMcp.Reflect.text(metadata.hub, 64)} server=#{metadata.server_id} attempt=#{metadata.attempt}"
    )
  end

  defp handle_event([:conduit_mcp, :client, :hub, :collision], measurements, metadata, _config) do
    require Logger

    Logger.debug(
      "MCP hub tool name collision: hub=#{ConduitMcp.Reflect.text(metadata.hub, 64)} exposed=#{metadata.exposed_name} count=#{measurements.count}"
    )
  end

  defp handle_event(
         [:conduit_mcp, :client, :adapter, :strict_fallback],
         _measurements,
         metadata,
         _config
       ) do
    require Logger

    Logger.debug(
      "MCP adapter strict-mode fallback: client=#{client_text(metadata)} api=#{metadata.api} tool=#{ConduitMcp.Reflect.text(metadata.tool_name)} reason=#{metadata.reason}"
    )
  end

  defp client_text(metadata), do: ConduitMcp.Reflect.text(metadata.client, 64)

  defp duration_ms(%{duration: duration}),
    do: System.convert_time_unit(duration, :native, :millisecond)
end

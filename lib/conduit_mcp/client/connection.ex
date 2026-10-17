defmodule ConduitMcp.Client.Connection do
  @moduledoc """
  The process that owns one client's connection to one MCP server.

  A `:gen_statem` (callback mode `[:handle_event_function, :state_enter]`)
  started by `ConduitMcp.Client` and registered as `{:client, name}` in
  `ConduitMcp.Client.Registry`. It traps exits. Users never call it
  directly: `ConduitMcp.Client` functions message it from the caller (see
  `ConduitMcp.Client.Request`).

  It is a router, not a worker. It allocates request ids, keeps the pending
  map, enforces deadlines and limits, routes cancellations and progress,
  and fans notifications out to subscribers. It **never runs user code**:
  no handler callbacks, no progress callbacks (progress goes to the caller,
  which runs them), no policy or hooks. The transport's callbacks run here,
  and must not block (`ConduitMcp.Client.Transport`).

  ## States

  | State | Does | Leaves to |
  |---|---|---|
  | `:connecting` | `transport.connect/1`, bounded by `:request_timeout` | `:discovering`, or `:initializing` for a legacy pin or hint |
  | `:discovering` | sends `server/discover` (bounded by `:probe_timeout` when probing) | `:ready` (modern), `:initializing` on legacy evidence, `:reconnecting`, `:closed` |
  | `:initializing` | sends legacy `initialize`, then `notifications/initialized` | `:ready`, `:reconnecting`, `:closed` |
  | `:ready` | sends requests; resets the reconnect count after `:stable_after`; runs the optional health check | `:reconnecting`, `:discovering` (re-negotiation) |
  | `:reconnecting` | waits `backoff.(attempt)` | `:connecting`, or `:closed` after `:max_reconnects` |
  | `:closed` | answers every request `kind: :closed` at once | `:connecting` via `ConduitMcp.Client.reconnect/1` |

  Starting never blocks: `init/1` returns at once and the first connect runs
  as an internal event. `:closed` keeps the process alive so `status/1`
  shows why; with `on_give_up: :stop` the connection exits instead so a
  supervisor restarts it.

  ### Era discovery

  With `protocol: :auto` the connection probes `server/discover` and reads
  the outcome with `ConduitMcp.Client.Negotiation.classify_probe/3` (the
  transport's `kind/0` picks the stdio or HTTP rules):

    * a `DiscoverResult` → modern, ready;
    * `-32022` with a mutual version → discover once more with that
      version, never a fallback; a second refusal, or no version in common,
      closes;
    * legacy evidence (stdio: a non-modern error or a timeout) →
      `initialize`;
    * the server exiting during the probe → reconnect, and the next attempt
      starts with `initialize`;
    * a recognised modern error naming no common version or a missing
      client capability → `:closed`.

  `protocol: :modern` (or a modern version) discovers without probing:
  legacy evidence closes the connection instead of falling back.
  `protocol: :legacy` (or a legacy version) goes straight to `initialize`.
  `prior: :legacy` skips the probe once. Once a connection has negotiated
  modern, later handshakes never fall back to legacy. A ready modern
  connection that receives `-32022` re-discovers; the caller's
  `ConduitMcp.Client.Request` retries that request once.

  ## Requests

  A request that arrives before `:ready` is postponed (at most
  `:max_queued` of them) and replayed on entering `:ready`, where its
  deadline is checked again: a request whose caller already gave up is
  answered `kind: :timeout` and never sent. In `:ready` a request beyond
  `:max_in_flight` is refused with `kind: :overloaded`.

  Ids are integers from a counter that is never reset, so a late frame
  from an earlier attempt can never match a current request. A request
  that asked for progress carries `progressToken` = its id.

  Each request has an absolute deadline timer. When it fires, the
  connection calls `transport.cancel/4` (reason `:timeout`) and answers
  `kind: :timeout`; when the caller dies, it cancels with `:caller_down`.
  A response that arrives for a request no longer pending is dropped
  (`[:conduit_mcp, :client, :response, :dropped]`). Nothing that may have
  executed is retried automatically: on reconnect every pending request
  fails with `kind: :transport`.

  ## Notifications

  Every server notification but `notifications/progress` and
  `notifications/cancelled` is sent to each process subscribed with
  `ConduitMcp.Client.subscribe_notifications/2` as
  `{:mcp_notification, name, method, params}`, and to the handler's
  `handle_notification/3` / `handle_log/3` (run in a separate process, in
  order). A burst of one `notifications/*/list_changed` kind is coalesced:
  the first is delivered at once, and any further ones within the next
  250 ms are delivered as one trailing notification, so a flood reaches
  subscribers at most twice per window. Each delivered `list_changed`
  marks the matching `ConduitMcp.Client.Cache` list stale and, if it was
  ever fetched, refreshes it (at most two refreshes per burst).

  ## Change notifications and resource subscriptions

  Modern servers send change notifications only on a `subscriptions/listen`
  stream. The connection opens one itself once the client has a consumer
  (a cached list, a notification subscriber, or a handler taking
  notifications) for a kind the server advertises `listChanged` for, or a
  resource subscription (`ConduitMcp.Client.subscribe/2`), with the union
  of those as its filter. Notifications are routed only for a live listen,
  with its `subscriptionId` removed. A filter change opens a new listen
  and closes the old one once the new one is acknowledged; a listen that
  ends is reopened after the backoff, and one that dropped also marks the
  cache stale. At most four listens exist at once. Legacy servers get
  `resources/subscribe` instead. Resource subscriptions survive reconnects:
  each new session or listen carries them again.

  ## Cache

  The connection owns and is the only writer of the client's
  `ConduitMcp.Client.Cache` table, but never fetches lists itself: a
  refresh runs in a task under the client's `Task.Supervisor` and reports
  back. Losing the connection marks every cached list stale.

  ## HTTP outcomes

  A transport may report a request refused for credentials (`{:unauthorized,
  id, info}`: the caller gets `kind: :auth`) or a legacy session the server
  no longer knows (`{:session_expired, id}`): the connection then runs a new
  `initialize` without failing the requests in flight, and the transport
  re-sends the expired ones once (`ConduitMcp.Client.Transport`).

  ## Server-to-client requests (legacy)

  `ping` is answered `{}`. `sampling/createMessage`, `elicitation/create`
  and `roots/list` run the client's `ConduitMcp.Client.Handler` in a task
  under the client's `Task.Supervisor`, never here, with the limits of
  `:handler_timeout` and `:max_server_requests`; the related call's
  deadline is paused meanwhile (bounded by its `:max_total_timeout`). A
  server `notifications/cancelled` kills the task. Any other method, or one
  whose capability was not declared, is answered `-32601`.

  ## Telemetry

  Emits `[:conduit_mcp, :client, :connection, :transition]`,
  `[:conduit_mcp, :client, :request, :cancel]`,
  `[:conduit_mcp, :client, :response, :dropped]`,
  `[:conduit_mcp, :client, :notification]`,
  `[:conduit_mcp, :client, :cache, :refresh, :start | :stop]` and
  `[:conduit_mcp, :client, :tool, :definition_changed]` from this process;
  handlers attached to them run here and must be fast (see
  `ConduitMcp.Telemetry`).

  ## Crash reports

  `format_status/1` replaces the transport state, the transport options,
  the params of queued requests and every `assigns` (the client's and each
  pending call's) with `:redacted`, so a crash report never carries
  credentials, session ids, host data or tool arguments.
  """

  @behaviour :gen_statem

  require Logger

  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Handshake
  alias ConduitMcp.Client.Connection.Inbound
  alias ConduitMcp.Client.Connection.Listen
  alias ConduitMcp.Client.Connection.Notifier
  alias ConduitMcp.Client.Connection.Refresh
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Connection.ServerRequests
  alias ConduitMcp.Client.Connection.TaskWatch
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Telemetry

  @doc false
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, shutdown: 5_000}
  end

  @doc false
  @spec start_link(Config.t()) :: :gen_statem.start_ret()
  def start_link(%Config{} = config) do
    :gen_statem.start_link(
      Registry.via({:client, config.name}, :starting),
      __MODULE__,
      config,
      []
    )
  end

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)
    Logger.metadata(mcp_client: ConduitMcp.Reflect.text(config.name, 64))

    {:ok, task_sup, _value} = Registry.lookup({:task_sup, config.name})
    {transport, opts} = config.transport

    case transport.init(opts, %{owner: self(), task_sup: task_sup, key: config.name}) do
      {:ok, tstate} ->
        data = Data.new(config, task_sup, tstate)

        notifier =
          Notifier.start(config.handler, %{client: config.name, server_id: config.server_id})

        data = %{data | notifier: notifier}
        :ok = Data.register(data)
        :ok = Data.publish(data, :connecting)
        {:ok, :connecting, data, [{:next_event, :internal, :connect}]}

      {:error, reason} ->
        {:stop, {:transport_init, reason}}
    end
  end

  @impl :gen_statem
  def handle_event(:enter, old_state, state, data), do: enter(old_state, state, data)

  def handle_event(:internal, :connect, :connecting, data), do: Handshake.connect(data)

  def handle_event(:internal, {:transport, event}, state, data),
    do: transport_event(event, state, data)

  def handle_event(:info, {:"$mcp_request", _, _, _, _, _} = request, state, data),
    do: result(Requests.admit(request, state, data))

  def handle_event(:info, {:"$mcp_cancel", mref, reason}, _state, data) do
    case Requests.cancel_ref(mref, reason, data) do
      :unknown -> :keep_state_and_data
      result -> result(result)
    end
  end

  def handle_event(:info, {:"$mcp_call", mref, op}, state, data),
    do: control(op, mref, state, data)

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason} = message, state, data),
    do: down(ref, message, state, data)

  def handle_event(:info, {ref, answer} = message, state, data) when is_reference(ref) do
    case Data.job(data, ref) do
      {:server_request, id} -> result(ServerRequests.reply(id, ref, answer, data))
      # A list written to the cache may give the modern listen a new filter.
      {:refresh, kind} -> sync(Refresh.done(kind, ref, answer, data), state)
      :error -> transport_info(message, state, data)
    end
  end

  def handle_event(:info, message, state, data), do: transport_info(message, state, data)

  def handle_event({:timeout, {:req, id}}, id, _state, data),
    do: result(Requests.timeout(id, data))

  def handle_event({:timeout, {:list_changed, method}}, nil, _state, data),
    do: result(Inbound.window_end(method, data))

  def handle_event({:timeout, {:server_request, id}}, id, _state, data),
    do: result(ServerRequests.timeout(id, data))

  def handle_event({:timeout, :listen}, nil, state, data), do: result(Listen.timer(data, state))

  def handle_event({:timeout, :health}, nil, :ready, data), do: Handshake.health_tick(data)
  def handle_event({:timeout, :health}, nil, _state, _data), do: :keep_state_and_data

  def handle_event(:state_timeout, content, state, data),
    do: Handshake.state_timeout(state, content, data)

  # --- state enter -------------------------------------------------------------

  defp enter(old_state, state, data) do
    from = if old_state == state, do: nil, else: old_state
    data = %{data | queued: 0}
    :ok = Data.publish(data, state)
    Telemetry.transition(Data.telemetry(data), from, state, data.reason, data.attempt)
    {:keep_state, data, enter_actions(state, data)}
  end

  defp enter_actions(:ready, data),
    do: [{:state_timeout, data.config.stable_after, :stable}, Handshake.health_timer(data)]

  defp enter_actions(_state, _data), do: []

  # --- transport ---------------------------------------------------------------

  defp transport_info(_message, _state, %Data{tstate: nil}), do: :keep_state_and_data

  defp transport_info(message, _state, data) do
    case data.transport.handle_info(message, data.tstate) do
      {:ok, events, tstate} ->
        {:keep_state, %{data | tstate: tstate},
         Enum.map(events, &{:next_event, :internal, {:transport, &1}})}

      :unknown ->
        Logger.debug("MCP client dropped an unexpected message",
          message: ConduitMcp.Reflect.text(message, 64)
        )

        :keep_state_and_data
    end
  end

  defp transport_event({:connected, info}, :connecting, data),
    do: Handshake.connected(%{data | origin: origin(info)})

  defp transport_event({:connected, _info}, _state, _data), do: :keep_state_and_data

  defp transport_event({:response, id, message}, state, data) do
    case Map.fetch(data.internal, id) do
      {:ok, purpose} -> internal_outcome(id, purpose, {:response, message}, state, data)
      :error -> response(id, message, state, data)
    end
  end

  defp transport_event({:exchange_done, id, outcome}, state, data) do
    case {Map.fetch(data.internal, id), outcome} do
      {{:ok, purpose}, {:error, _reason}} -> internal_outcome(id, purpose, outcome, state, data)
      {{:ok, _purpose}, :ok} -> :keep_state_and_data
      {:error, _} -> result(Requests.exchange_done(id, outcome, data))
    end
  end

  # HTTP 401/403: the request fails with `kind: :auth` (the OAuth phase
  # hooks in here).
  defp transport_event({:unauthorized, id, info}, state, data) do
    case Requests.unauthorized(id, info, data) do
      :unknown ->
        case Map.fetch(data.internal, id) do
          {:ok, purpose} ->
            error = Requests.auth_error(info)
            internal_outcome(id, purpose, {:error, error}, state, data)

          :error ->
            :keep_state_and_data
        end

      result ->
        result(result)
    end
  end

  # A legacy session ended (HTTP 404): renew it; the transport re-sends the
  # request once the new session is ready.
  defp transport_event({:session_expired, _id}, state, data),
    do: Handshake.session_expired(state, data)

  defp transport_event({:notification, method, params}, state, data) do
    params = if is_map(params), do: params, else: %{}

    case Listen.notification(method, params, data, state) do
      {:route, params, data, actions} ->
        {data, more} = Inbound.notification(method, params, data)
        {:keep_state, data, actions ++ more}

      {:handled, data, actions} ->
        {:keep_state, data, actions}
    end
  end

  defp transport_event({:server_request, id, message, related}, _state, data),
    do: result(ServerRequests.start(id, message, related, data))

  defp transport_event({:closed, reason}, state, data),
    do: Handshake.transport_closed(state, reason, data)

  # The answer to one of the connection's own requests.
  defp internal_outcome(id, :listen, outcome, _state, data),
    do: result(Listen.ended(id, outcome, data))

  defp internal_outcome(id, purpose, outcome, _state, data)
       when purpose == :resubscribe or (is_tuple(purpose) and elem(purpose, 0) == :resource) do
    data = %{data | internal: Map.delete(data.internal, id)}
    {:keep_state, Listen.legacy_done(purpose, outcome, data)}
  end

  defp internal_outcome(id, purpose, {:response, message}, state, data) do
    data = %{data | internal: Map.delete(data.internal, id)}
    Handshake.internal_response(id, purpose, message, state, data)
  end

  # A pinned discover refused with HTTP 401/403 (a probe reports the status
  # to `ConduitMcp.Client.Negotiation` instead).
  defp internal_outcome(id, :discover, {:error, %Error{kind: :auth} = error}, _state, data),
    do: Handshake.close(error, %{data | internal: Map.delete(data.internal, id)})

  defp internal_outcome(id, :discover, {:error, reason}, _state, data),
    do: Handshake.discover_failed(id, reason, %{data | internal: Map.delete(data.internal, id)})

  defp internal_outcome(id, :initialize, {:error, reason}, _state, data),
    do: Handshake.initialize_failed(id, reason, %{data | internal: Map.delete(data.internal, id)})

  # A health check or a dead caller's `tasks/cancel` that failed: a missed
  # health check is counted by its timer.
  defp internal_outcome(id, _purpose, {:error, _reason}, _state, data),
    do: {:keep_state, %{data | internal: Map.delete(data.internal, id)}}

  defp response(id, message, state, data) do
    case Requests.response(id, message, state, data) do
      {:renegotiate, data, actions} ->
        data
        |> Handshake.begin_discover(data.version, :pinned, [])
        |> add_actions(actions)

      {_ok_or_dropped, data, actions} ->
        {:keep_state, data, actions}
    end
  end

  defp add_actions({:next_state, state, data, actions}, more),
    do: {:next_state, state, data, more ++ actions}

  defp add_actions(other, _more), do: other

  defp origin(%{origin: origin}) when is_binary(origin), do: origin
  defp origin(_info), do: nil

  # A task this process started (a server request handler or a cache
  # refresh) exited without answering.
  defp task_down(ref, data) do
    case Data.job(data, ref) do
      {:server_request, id} -> ServerRequests.down(id, data)
      {:refresh, kind} -> Refresh.down(kind, data)
      :error -> :unknown
    end
  end

  # --- monitors ----------------------------------------------------------------

  defp down(ref, message, state, data) do
    with :unknown <- Requests.cancel_ref(ref, :caller_down, data),
         :unknown <- Inbound.subscriber_down(ref, data),
         :unknown <- task_down(ref, data),
         :unknown <- TaskWatch.down(ref, state, data) do
      transport_info(message, state, data)
    else
      %Data{} = data -> sync(data, state)
      result -> result(result)
    end
  end

  # --- control calls (ConduitMcp.Client.Request.call/3) -----------------------

  defp control(:await_ready, mref, :ready, _data), do: reply(mref, :ok)

  defp control(:await_ready, mref, :closed, data),
    do: reply(mref, {:error, Requests.closed_error(data)})

  defp control(:await_ready, _mref, _state, _data), do: {:keep_state_and_data, [:postpone]}

  defp control(:close, mref, :closed, _data), do: reply(mref, :ok)

  # Answered after the teardown, so a legacy session's DELETE has been sent
  # when `ConduitMcp.Client.close/1` returns.
  defp control(:close, mref, _state, data) do
    {data, actions} = Handshake.user_close(data)
    Requests.reply(mref, :ok)
    {:next_state, :closed, data, actions}
  end

  defp control(:reconnect, mref, _state, data) do
    Requests.reply(mref, :ok)
    {data, actions} = Handshake.user_reconnect(data)
    {:next_state, :connecting, data, actions}
  end

  defp control({:subscribe, pid}, mref, state, data) do
    Requests.reply(mref, :ok)
    sync(Inbound.subscribe(pid, data), state)
  end

  defp control({:unsubscribe, pid}, mref, state, data) do
    Requests.reply(mref, :ok)
    sync(Inbound.unsubscribe(pid, data), state)
  end

  defp control({:resource_subscription, op, uri}, mref, :ready, data),
    do: result(Listen.change(op, uri, mref, data))

  defp control({:resource_subscription, _op, _uri}, mref, :closed, data),
    do: reply(mref, {:error, Requests.closed_error(data)})

  defp control({:resource_subscription, _op, _uri}, _mref, _state, _data),
    do: {:keep_state_and_data, [:postpone]}

  defp control({:refresh, kind, opts}, mref, _state, data),
    do: {:keep_state, Refresh.demand(kind, mref, opts, data)}

  defp control({:watch_task, pid, task_id}, mref, _state, data) do
    Requests.reply(mref, :ok)
    {:keep_state, TaskWatch.watch(pid, task_id, data)}
  end

  defp control({:unwatch_task, pid, task_id}, mref, _state, data) do
    Requests.reply(mref, :ok)
    {:keep_state, TaskWatch.unwatch(pid, task_id, data)}
  end

  defp control(_unknown, mref, _state, _data),
    do: reply(mref, {:error, Error.new(:protocol, :unknown_control_call)})

  defp reply(mref, message) do
    Requests.reply(mref, message)
    :keep_state_and_data
  end

  defp result({data, actions}), do: {:keep_state, data, actions}

  # The modern listen filter follows the client's consumers.
  defp sync(%Data{} = data, state) do
    {data, actions} = Listen.sync(data, state)
    {:keep_state, data, actions}
  end

  # --- shutdown ----------------------------------------------------------------

  @impl :gen_statem
  def terminate(reason, _state, %Data{} = data) do
    {data, _actions} = Requests.fail_all(data, Error.new(:closed, :shutdown))
    _data = Data.close_transport(data, reason)
    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

  @impl :gen_statem
  def format_status(status) do
    status
    |> Map.update(:data, nil, &redact_data/1)
    |> Map.update(:queue, [], &redact_events/1)
    |> Map.update(:postponed, [], &redact_events/1)
  end

  # Transport options (in the config) may carry credentials just like the
  # transport state built from them.
  defp redact_data(%Data{config: %{transport: {transport, _opts}} = config} = data) do
    %{
      data
      | tstate: :redacted,
        input: :redacted,
        pending: Map.new(data.pending, fn {id, entry} -> {id, %{entry | assigns: :redacted}} end),
        config: %{config | transport: {transport, :redacted}, assigns: :redacted}
    }
  end

  defp redact_data(other), do: other

  defp redact_events(events) when is_list(events), do: Enum.map(events, &redact_event/1)
  defp redact_events(other), do: other

  defp redact_event({type, {:"$mcp_request", mref, caller, op, _params, opts}}),
    do: {type, {:"$mcp_request", mref, caller, op, :redacted, opts}}

  defp redact_event({type, {:transport, _event}}), do: {type, {:transport, :redacted}}
  defp redact_event(event), do: event
end

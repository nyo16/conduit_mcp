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
  `{:mcp_notification, name, method, params}`. A burst of one
  `notifications/*/list_changed` kind is coalesced: the first is delivered
  at once, and any further ones within the next 250 ms are delivered as one
  trailing notification, so a flood reaches subscribers at most twice per
  window.

  Legacy server-to-client requests: `ping` is answered `{}`; any other
  method is answered `-32601`.

  ## Telemetry

  Emits `[:conduit_mcp, :client, :connection, :transition]`,
  `[:conduit_mcp, :client, :request, :cancel]`,
  `[:conduit_mcp, :client, :response, :dropped]` and
  `[:conduit_mcp, :client, :notification]` from this process; handlers
  attached to them run here and must be fast (see `ConduitMcp.Telemetry`).

  ## Crash reports

  `format_status/1` replaces the transport state, the transport options and
  the params of queued requests with `:redacted`, so a crash report never
  carries credentials, session ids or tool arguments.
  """

  @behaviour :gen_statem

  require Logger

  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Handshake
  alias ConduitMcp.Client.Connection.Inbound
  alias ConduitMcp.Client.Connection.Requests
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

  def handle_event(:info, message, state, data), do: transport_info(message, state, data)

  def handle_event({:timeout, {:req, id}}, id, _state, data),
    do: result(Requests.timeout(id, data))

  def handle_event({:timeout, {:list_changed, method}}, nil, _state, data),
    do: result(Inbound.window_end(method, data))

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

  defp transport_event({:connected, _info}, :connecting, data), do: Handshake.connected(data)
  defp transport_event({:connected, _info}, _state, _data), do: :keep_state_and_data

  defp transport_event({:response, id, message}, state, data) do
    case Map.fetch(data.internal, id) do
      {:ok, purpose} ->
        data = %{data | internal: Map.delete(data.internal, id)}
        Handshake.internal_response(id, purpose, message, state, data)

      :error ->
        response(id, message, state, data)
    end
  end

  defp transport_event({:exchange_done, id, outcome}, _state, data) do
    case {Map.fetch(data.internal, id), outcome} do
      {{:ok, :discover}, {:error, reason}} ->
        Handshake.discover_failed(id, reason, %{data | internal: Map.delete(data.internal, id)})

      {{:ok, _purpose}, _outcome} ->
        :keep_state_and_data

      {:error, _} ->
        result(Requests.exchange_done(id, outcome, data))
    end
  end

  defp transport_event({:notification, method, params}, _state, data),
    do: result(Inbound.notification(method, params, data))

  defp transport_event({:server_request, id, message, _related}, _state, data),
    do: {:keep_state, Inbound.server_request(id, message, data)}

  defp transport_event({:closed, reason}, state, data),
    do: Handshake.transport_closed(state, reason, data)

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

  # --- monitors ----------------------------------------------------------------

  defp down(ref, message, state, data) do
    with :unknown <- Requests.cancel_ref(ref, :caller_down, data),
         :unknown <- Inbound.subscriber_down(ref, data) do
      transport_info(message, state, data)
    else
      %Data{} = data -> {:keep_state, data}
      result -> result(result)
    end
  end

  # --- control calls (ConduitMcp.Client.Request.call/3) -----------------------

  defp control(:await_ready, mref, :ready, _data), do: reply(mref, :ok)

  defp control(:await_ready, mref, :closed, data),
    do: reply(mref, {:error, Requests.closed_error(data)})

  defp control(:await_ready, _mref, _state, _data), do: {:keep_state_and_data, [:postpone]}

  defp control(:close, mref, :closed, _data), do: reply(mref, :ok)

  defp control(:close, mref, _state, data) do
    Requests.reply(mref, :ok)
    {data, actions} = Handshake.user_close(data)
    {:next_state, :closed, data, actions}
  end

  defp control(:reconnect, mref, _state, data) do
    Requests.reply(mref, :ok)
    {data, actions} = Handshake.user_reconnect(data)
    {:next_state, :connecting, data, actions}
  end

  defp control({:subscribe, pid}, mref, _state, data) do
    Requests.reply(mref, :ok)
    {:keep_state, Inbound.subscribe(pid, data)}
  end

  defp control({:unsubscribe, pid}, mref, _state, data) do
    Requests.reply(mref, :ok)
    {:keep_state, Inbound.unsubscribe(pid, data)}
  end

  defp control(_unknown, mref, _state, _data),
    do: reply(mref, {:error, Error.new(:protocol, :unknown_control_call)})

  defp reply(mref, message) do
    Requests.reply(mref, message)
    :keep_state_and_data
  end

  defp result({data, actions}), do: {:keep_state, data, actions}

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
  defp redact_data(%Data{config: %{transport: {transport, _opts}} = config} = data),
    do: %{data | tstate: :redacted, config: %{config | transport: {transport, :redacted}}}

  defp redact_data(other), do: other

  defp redact_events(events) when is_list(events), do: Enum.map(events, &redact_event/1)
  defp redact_events(other), do: other

  defp redact_event({type, {:"$mcp_request", mref, caller, op, _params, opts}}),
    do: {type, {:"$mcp_request", mref, caller, op, :redacted, opts}}

  defp redact_event({type, {:transport, _event}}), do: {type, {:transport, :redacted}}
  defp redact_event(event), do: event
end

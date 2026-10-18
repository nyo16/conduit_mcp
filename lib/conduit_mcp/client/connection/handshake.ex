defmodule ConduitMcp.Client.Connection.Handshake do
  @moduledoc false

  # The connection lifecycle: connect, era discovery (`server/discover`),
  # the legacy `initialize` handshake, reconnect with backoff, closing, and
  # the optional health check. Functions return `:gen_statem` results.

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Connection.Authorize
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Listen
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Connection.ServerRequests
  alias ConduitMcp.Client.DiscoverResult
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Negotiation
  alias ConduitMcp.Client.ServerInfo
  alias ConduitMcp.Client.Telemetry

  @permanent_errors [:no_common_version, :missing_client_capability]

  @type result :: :gen_statem.event_handler_result(atom())

  # --- connecting ----------------------------------------------------------

  @doc "The `:connect` internal event: (re)initialise the transport and connect."
  @spec connect(Data.t()) :: result()
  def connect(data) do
    case ensure_transport(data) do
      {:ok, data} ->
        {:ok, tstate} = data.transport.connect(data.tstate)

        {:keep_state, %{data | tstate: tstate},
         [{:state_timeout, data.config.request_timeout, :connect}]}

      {:error, reason} ->
        close({:transport_init, reason}, data)
    end
  end

  defp ensure_transport(%Data{tstate: nil, config: config} = data) do
    {transport, opts} = config.transport

    case transport.init(opts, %{owner: self(), task_sup: data.task_sup, key: data.config.name}) do
      {:ok, tstate} -> {:ok, Authorize.push(%{data | tstate: tstate})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_transport(data), do: {:ok, data}

  @doc "The transport reported `{:connected, _}`: start the handshake."
  @spec connected(Data.t()) :: result()
  def connected(data) do
    skip_probe? = data.era_hint == :legacy and data.era_lock != :modern
    data = %{data | era_hint: nil}

    cond do
      pinned_era(data) == :legacy -> begin_initialize(data, false)
      skip_probe? and pinned_era(data) == nil -> begin_initialize(data, true)
      true -> begin_discover(data, first_modern_version(data), discover_mode(data), [])
    end
  end

  defp pinned_era(%Data{config: %{protocol: protocol}}) when protocol in [:modern, :legacy],
    do: protocol

  defp pinned_era(%Data{config: %{protocol: version}}) when is_binary(version),
    do: Negotiation.era(version)

  defp pinned_era(_data), do: nil

  # A connection that has spoken modern never falls back to legacy.
  defp discover_mode(data) do
    if pinned_era(data) == :modern or data.era_lock == :modern, do: :pinned, else: :probe
  end

  defp versions(%Data{config: %{protocol: version}}) when is_binary(version), do: [version]
  defp versions(_data), do: Negotiation.client_versions()

  defp first_modern_version(data),
    do: data |> versions() |> Enum.find(&(Negotiation.era(&1) == :modern))

  defp first_legacy_version(data),
    do: data |> versions() |> Enum.find(&(Negotiation.era(&1) == :legacy))

  # --- discovering ---------------------------------------------------------

  @doc "Sends `server/discover` for `version` and enters `:discovering`."
  @spec begin_discover(Data.t(), String.t(), :probe | :pinned, [String.t()]) :: result()
  def begin_discover(data, version, mode, tried) do
    {id, data} = Data.take_id(data)
    info = %{era: :modern, version: version}

    case Data.send_request(data, id, "server/discover", %{}, info, nil, probe: mode == :probe) do
      {:ok, _handle, data} ->
        timeout =
          if mode == :probe, do: data.config.probe_timeout, else: data.config.request_timeout

        data = %{
          data
          | internal: Map.put(data.internal, id, :discover),
            handshake: %{id: id, mode: mode, tried: [version | tried], skipped_probe?: false}
        }

        {:next_state, :discovering, data, [{:state_timeout, timeout, :handshake}]}

      {:error, reason, data} ->
        reconnect(reason, data)
    end
  end

  @doc """
  The outcome of the discover request, in the shape
  `ConduitMcp.Client.Negotiation.classify_probe/3` takes for this
  transport's kind.
  """
  @spec discover_outcome(term(), Data.t()) :: result()
  def discover_outcome(outcome, data) do
    %{mode: mode, tried: tried} = data.handshake
    verdict = Negotiation.classify_probe(probe_class(data), outcome, versions: versions(data))
    apply_verdict(verdict, mode, tried, data)
  end

  @doc "The probe class of the transport (see `ConduitMcp.Client.Transport`)."
  @spec probe_class(Data.t()) :: :stdio | :http
  def probe_class(%Data{kind: :http}), do: :http
  def probe_class(_data), do: :stdio

  defp apply_verdict({:modern, version, %DiscoverResult{} = result}, _mode, _tried, data) do
    server = %{
      server_info: result.server_info,
      capabilities: result.capabilities,
      instructions: result.instructions
    }

    ready(%{data | era: :modern, version: version, era_lock: :modern, server: server})
  end

  # `-32022` names the versions the server accepts: discover once more with
  # the mutual one. A second refusal in the same handshake closes; a legacy
  # fallback never follows a modern error.
  defp apply_verdict({:modern_retry, version}, mode, tried, data) do
    if length(tried) >= 2,
      do: close(Error.new(:protocol, :no_common_version), data),
      else: begin_discover(data, version, mode, tried)
  end

  defp apply_verdict(:legacy, :probe, _tried, data), do: begin_initialize(data, false)

  defp apply_verdict(:legacy, :pinned, _tried, data),
    do: close(Error.new(:protocol, :not_modern), data)

  defp apply_verdict({:reconnect, :legacy}, mode, _tried, data) do
    data = if mode == :probe, do: %{data | era_hint: :legacy}, else: data
    reconnect(:closed_during_probe, data)
  end

  defp apply_verdict({:authorize, status}, _mode, _tried, data),
    do: close(Error.new(:auth, {:http_status, status}), data)

  defp apply_verdict({:retry, reason}, _mode, _tried, data), do: reconnect(reason, data)

  defp apply_verdict({:error, %Error{reason: reason} = error}, _mode, _tried, data)
       when reason in @permanent_errors,
       do: close(error, data)

  defp apply_verdict({:error, %Error{} = error}, _mode, _tried, data), do: reconnect(error, data)

  # --- initializing --------------------------------------------------------

  @doc """
  Sends the legacy `initialize` and enters `:initializing`. `skipped_probe?`
  marks an attempt that skipped the probe on a hint, so a refusal makes the
  next attempt probe instead of closing.
  """
  @spec begin_initialize(Data.t(), boolean()) :: result()
  def begin_initialize(data, skipped_probe?) do
    {id, data} = Data.take_id(data)
    version = first_legacy_version(data)

    params = %{
      "protocolVersion" => version,
      "capabilities" => Data.client_capabilities(data, :legacy),
      "clientInfo" => data.config.client_info
    }

    case Data.send_request(data, id, "initialize", params, %{era: :legacy}, nil, []) do
      {:ok, _handle, data} ->
        data = %{
          data
          | internal: Map.put(data.internal, id, :initialize),
            handshake: %{id: id, mode: :legacy, tried: [version], skipped_probe?: skipped_probe?}
        }

        {:next_state, :initializing, data,
         [{:state_timeout, data.config.request_timeout, :handshake}]}

      {:error, reason, data} ->
        reconnect(reason, data)
    end
  end

  @doc "The answer to `initialize`."
  @spec initialize_result(map(), Data.t()) :: result()
  def initialize_result(%{"result" => %{"protocolVersion" => version} = result}, data)
      when is_binary(version) do
    if acceptable_legacy_version?(version, data) do
      data = %{
        data
        | era: :legacy,
          version: version,
          server: %{
            server_info: server_info(result["serverInfo"]),
            capabilities: object(result["capabilities"]),
            instructions: if(is_binary(result["instructions"]), do: result["instructions"])
          }
      }

      # The transport learns the session first: over HTTP,
      # `notifications/initialized` must carry `MCP-Protocol-Version` like
      # every request after `initialize` (2025-11-25 transports).
      data = Data.set_session(data)

      case Data.notify(data, "notifications/initialized", %{}) do
        {:ok, data} -> enter_ready(data)
        {:error, reason, data} -> reconnect(reason, data)
      end
    else
      close(Error.new(:protocol, :no_common_version, %{"protocolVersion" => version}), data)
    end
  end

  def initialize_result(%{"error" => error}, data) do
    error = Error.from_rpc_error(error)

    if data.handshake.skipped_probe?,
      do: reconnect(error, data),
      else: close(error, data)
  end

  def initialize_result(_message, data),
    do: close(Error.new(:protocol, :invalid_initialize_result), data)

  defp acceptable_legacy_version?(version, %Data{config: %{protocol: pinned}})
       when is_binary(pinned),
       do: version == pinned

  defp acceptable_legacy_version?(version, _data),
    do: version in Negotiation.client_versions() and Negotiation.era(version) == :legacy

  defp server_info(info) do
    case ServerInfo.from_wire(info) do
      {:ok, server_info} -> server_info
      {:error, _} -> nil
    end
  end

  defp object(map) when is_map(map), do: map
  defp object(_other), do: %{}

  # --- ready, reconnecting, closed ------------------------------------------

  defp ready(data), do: enter_ready(Data.set_session(data))

  defp enter_ready(data) do
    {data, actions} = Listen.on_ready(%{data | handshake: nil})
    {:next_state, :ready, data, actions}
  end

  @doc """
  The `initialize` request failed without an answer: an invalid answer
  (`kind: :protocol`, for example an invalid session id) closes; anything
  else reconnects.
  """
  @spec initialize_failed(pos_integer(), term(), Data.t()) :: result()
  def initialize_failed(id, %Error{kind: kind} = error, %Data{handshake: %{id: id}} = data)
      when kind in [:protocol, :auth],
      do: close(error, data)

  def initialize_failed(id, reason, %Data{handshake: %{id: id}} = data),
    do: reconnect(reason, data)

  def initialize_failed(_id, _reason, _data), do: :keep_state_and_data

  @doc """
  A legacy session expired (HTTP 404 to a request that carried its id):
  initialize a new session without failing the requests in flight; the
  transport re-sends the expired ones once it is ready. Several 404s of
  one session renew it once.
  """
  @spec session_expired(atom(), Data.t()) :: result()
  def session_expired(:ready, %Data{era: :legacy} = data),
    do: begin_initialize(%{data | reason: :session_expired}, false)

  def session_expired(_state, _data), do: :keep_state_and_data

  @doc """
  Something failed that a new connection may fix: fail every pending request
  (never replayed), close the transport and wait `backoff.(attempt)`, or give
  up after `:max_reconnects`.
  """
  @spec reconnect(term(), Data.t()) :: result()
  def reconnect(reason, data) do
    data = %{data | attempt: data.attempt + 1}
    {data, actions} = teardown(data, reason, Error.new(:transport, Telemetry.reason_tag(reason)))

    if exceeded?(data.attempt, data.config.max_reconnects) do
      give_up(%{data | reason: {:gave_up, reason}}, actions)
    else
      delay = Data.backoff(data, data.attempt)
      {:next_state, :reconnecting, data, actions ++ [{:state_timeout, delay, :reconnect}]}
    end
  end

  defp exceeded?(_attempt, :infinity), do: false
  defp exceeded?(attempt, max), do: attempt > max

  @doc """
  A failure no reconnect fixes (no common version, a refused handshake):
  enter `:closed`, or stop when `on_give_up: :stop`.
  """
  @spec close(term(), Data.t()) :: result()
  def close(reason, data) do
    {data, actions} = teardown(data, reason, closed_error(reason))
    give_up(data, actions)
  end

  @doc "`ConduitMcp.Client.close/1`: enter `:closed` whatever `on_give_up` says."
  @spec user_close(Data.t()) :: {Data.t(), [:gen_statem.action()]}
  def user_close(data), do: teardown(data, :closed_by_user, Error.new(:closed, :closed_by_user))

  @doc "`ConduitMcp.Client.reconnect/1`: a fresh connection now, attempt count reset."
  @spec user_reconnect(Data.t()) :: {Data.t(), [:gen_statem.action()]}
  def user_reconnect(data) do
    {data, actions} = teardown(data, :reconnect, Error.new(:transport, :reconnect))
    {%{data | attempt: 0, reason: nil}, actions ++ [{:next_event, :internal, :connect}]}
  end

  # The exit carries only the reason's tag: supervisor reports log it, and a
  # full reason may hold server-supplied data.
  defp give_up(%Data{config: %{on_give_up: :stop}} = data, _actions) do
    cause =
      case data.reason do
        {:gave_up, reason} -> reason
        reason -> reason
      end

    {:stop, {:shutdown, {:gave_up, Telemetry.reason_tag(cause)}}, data}
  end

  defp give_up(data, actions), do: {:next_state, :closed, data, actions}

  defp closed_error(%Error{} = error), do: Error.new(:closed, Telemetry.reason_tag(error), error)
  defp closed_error(reason), do: Error.new(:closed, Telemetry.reason_tag(reason))

  defp teardown(data, reason, %Error{} = error) do
    :ok = Listen.fail_legacy(data.internal, error)

    data = %{
      data
      | reason: reason,
        handshake: nil,
        internal: %{},
        health: {nil, 0}
    }

    {data, actions} = Requests.fail_all(data, error)
    data = Authorize.reset(data, error)
    {data, stop_actions} = ServerRequests.stop_all(data)
    {data, listen_actions} = Listen.reset(data, error)
    Cache.mark_all_stale(data.cache)
    {Data.close_transport(data, reason), actions ++ stop_actions ++ listen_actions}
  end

  @doc "A `state_timeout` fired in `state`."
  @spec state_timeout(atom(), term(), Data.t()) :: result()
  def state_timeout(:connecting, :connect, data), do: reconnect(:connect_timeout, data)

  def state_timeout(:discovering, :handshake, %Data{handshake: %{mode: :pinned}} = data),
    do: reconnect(:timeout, data)

  def state_timeout(:discovering, :handshake, data), do: discover_outcome(:timeout, data)
  def state_timeout(:initializing, :handshake, data), do: reconnect(:timeout, data)

  def state_timeout(:reconnecting, :reconnect, data),
    do: {:next_state, :connecting, data, [{:next_event, :internal, :connect}]}

  def state_timeout(:ready, :stable, data), do: {:keep_state, %{data | attempt: 0}}

  @doc "The transport closed in `state`."
  @spec transport_closed(atom(), term(), Data.t()) :: result()
  def transport_closed(state, _reason, _data) when state in [:reconnecting, :closed],
    do: :keep_state_and_data

  def transport_closed(:discovering, reason, data) do
    outcome =
      if probe_class(data) == :http, do: {:transport_error, reason}, else: {:closed, reason}

    discover_outcome(outcome, data)
  end

  def transport_closed(_state, reason, data), do: reconnect(reason, data)

  # --- internal responses ----------------------------------------------------

  @doc "A response to one of the connection's own requests."
  @spec internal_response(pos_integer(), atom(), map(), atom(), Data.t()) :: result()
  def internal_response(id, :discover, message, :discovering, %Data{handshake: %{id: id}} = data),
    do: discover_outcome(rpc_outcome(message, data), data)

  def internal_response(
        id,
        :initialize,
        message,
        :initializing,
        %Data{handshake: %{id: id}} = data
      ),
      do: initialize_result(message, data)

  def internal_response(id, :health, _message, _state, %Data{health: {id, _misses}} = data),
    do: {:keep_state, %{data | health: {nil, 0}}}

  # The answer to a `tasks/cancel` sent for a dead caller (`TaskWatch`).
  def internal_response(_id, :task_cancel, _message, _state, data), do: {:keep_state, data}

  # A late answer to an abandoned handshake or health check.
  def internal_response(_id, _purpose, _message, _state, _data), do: :keep_state_and_data

  defp rpc_outcome(message, data) do
    case {probe_class(data), message} do
      {:http, message} -> {:http, 200, "application/json", message}
      {:stdio, %{"result" => result}} -> {:result, result}
      {:stdio, %{"error" => error}} -> {:error, error}
      {:stdio, other} -> {:result, other}
    end
  end

  @doc "`{:exchange_done, id, {:error, reason}}` for the discover request."
  @spec discover_failed(pos_integer(), term(), Data.t()) :: result()
  def discover_failed(id, reason, %Data{handshake: %{id: id}} = data) do
    outcome =
      case {probe_class(data), reason} do
        {:http, {:http, _status, _type, _body} = http} -> http
        {:http, {:transport_error, _} = error} -> error
        {:http, other} -> {:transport_error, other}
        {:stdio, other} -> {:closed, other}
      end

    discover_outcome(outcome, data)
  end

  def discover_failed(_id, _reason, _data), do: :keep_state_and_data

  # --- health check ------------------------------------------------------------

  @doc "The `:health` timer in `:ready`: count a missed check, send the next."
  @spec health_tick(Data.t()) :: result()
  def health_tick(data) do
    data =
      case data.health do
        {nil, _misses} ->
          data

        {id, misses} ->
          %{data | health: {nil, misses + 1}, internal: Map.delete(data.internal, id)}
      end

    if elem(data.health, 1) >= 2 do
      reconnect(:health_check_failed, data)
    else
      send_health_check(data)
    end
  end

  defp send_health_check(data) do
    {id, data} = Data.take_id(data)
    method = if data.era == :modern, do: "server/discover", else: "ping"

    case Data.send_request(data, id, method, %{}, %{}, nil, []) do
      {:ok, _handle, data} ->
        {_id, misses} = data.health
        data = %{data | health: {id, misses}, internal: Map.put(data.internal, id, :health)}
        {:keep_state, data, [health_timer(data)]}

      {:error, reason, data} ->
        reconnect(reason, data)
    end
  end

  @doc "The next health-check timer, if health checks are on."
  @spec health_timer(Data.t()) :: :gen_statem.action()
  def health_timer(%Data{config: %{health_check_interval: nil}}),
    do: {{:timeout, :health}, :cancel}

  def health_timer(%Data{config: %{health_check_interval: interval}}),
    do: {{:timeout, :health}, interval, nil}
end

defmodule ConduitMcp.Client.Connection.Requests do
  @moduledoc false

  # Caller requests inside the connection: admission (postpone, queue and
  # in-flight caps, deadline re-check), the pending map, deadlines, progress,
  # cancellation and replies. Every function returns `{data, actions}` (or a
  # tagged variant) for `ConduitMcp.Client.Connection` to turn into a
  # `:gen_statem` result.
  #
  # A pending entry:
  #
  #     %{mref: alias, caller_mon: ref, method: String.t(), handle: term(),
  #       deadline: ms, max_deadline: ms, timeout: ms, reset?: boolean(),
  #       assigns: map() | nil, paused: non_neg_integer(), paused_at: ms | nil,
  #       params: map(), info: map(), wire_opts: keyword()}
  #
  # `params`, `info` and `wire_opts` are what the request was sent with, so
  # a request the server refused with 401 can be sent again once OAuth has
  # a token (`resend/2`; it never reached the server's handler).
  #
  # `refs` maps both the caller's alias and the connection's monitor of the
  # caller to the id, so `$mcp_cancel` and `:DOWN` find the entry in O(1).
  # Deadlines are absolute `System.monotonic_time(:millisecond)` values, the
  # clock `:gen_statem` absolute timeouts use.
  #
  # While a legacy server request tied to a request runs (`paused` > 0), the
  # request's timer is set at its `max_deadline`; when the last one ends the
  # deadline moves forward by the paused time, never past `max_deadline`.
  # The caller is told each new deadline (`{:deadline, ms}`), so its own
  # safety net moves with it.

  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.OAuth.Challenge
  alias ConduitMcp.Client.Telemetry

  @unsupported_protocol_version ConduitMcp.Errors.unsupported_protocol_version()

  @type result :: {Data.t(), [:gen_statem.action()]}

  @doc """
  A `{:"$mcp_request", ...}` message in `state`: dispatched when ready,
  refused when closed, otherwise postponed (bounded by `:max_queued`).
  """
  @spec admit(tuple(), atom(), Data.t()) :: result()
  def admit(request, :ready, data), do: dispatch(request, data)

  def admit({_tag, mref, _caller, _op, _params, _opts}, :closed, data) do
    reply(mref, {:error, closed_error(data)})
    {data, []}
  end

  def admit({_tag, mref, _caller, _op, _params, _opts}, _state, data) do
    if data.queued >= data.config.max_queued do
      reply(mref, {:error, Error.new(:overloaded, :max_queued)})
      {data, []}
    else
      {%{data | queued: data.queued + 1}, [:postpone]}
    end
  end

  @doc "The error a request gets from a closed connection."
  @spec closed_error(Data.t()) :: Error.t()
  def closed_error(data), do: Error.new(:closed, Telemetry.reason_tag(data.reason), data.reason)

  # A postponed request is replayed here when the connection becomes ready;
  # the deadline is checked again, so a request whose caller gave up while
  # it waited is never sent.
  defp dispatch({_tag, mref, caller, op, params, opts}, data) do
    cond do
      Keyword.fetch!(opts, :deadline) <= now_ms() ->
        reply(mref, {:error, Error.new(:timeout)})
        {data, []}

      not alive?(caller) ->
        {data, []}

      true ->
        perform(op_action(op, params, data), mref, caller, opts)
    end
  end

  defp alive?(pid) when node(pid) == node(), do: Process.alive?(pid)
  defp alive?(_remote), do: true

  defp perform({:send, method, params, data}, mref, caller, opts),
    do: send_new(method, params, mref, caller, opts, data)

  defp perform({:notify, method, params, data}, mref, _caller, _opts) do
    case Data.notify(data, method, params) do
      {:ok, data} ->
        reply(mref, {:result, %{}})
        {data, []}

      {:error, reason, data} ->
        reply(mref, {:error, Error.new(:transport, reason)})
        {data, []}
    end
  end

  defp perform({:local, result, data}, mref, _caller, _opts) do
    reply(mref, {:result, result})
    {data, []}
  end

  defp perform({:error, error, data}, mref, _caller, _opts) do
    reply(mref, {:error, error})
    {data, []}
  end

  # Era-dependent operations (`ConduitMcp.Client.Request.op/0`) resolve here,
  # against the era the connection is actually speaking.
  defp op_action(method, params, data) when is_binary(method), do: {:send, method, params, data}

  defp op_action(:ping, _params, %{era: :modern} = data),
    do: {:send, "server/discover", %{}, data}

  defp op_action(:ping, _params, data), do: {:send, "ping", %{}, data}

  defp op_action({:set_log_level, level}, _params, %{era: :modern} = data),
    do: {:local, %{}, put_log_level(data, level)}

  defp op_action({:set_log_level, level}, _params, data),
    do: {:send, "logging/setLevel", %{"level" => level}, put_log_level(data, level)}

  defp op_action(:roots_list_changed, _params, %{era: :modern} = data),
    do: {:error, Error.new(:protocol, {:unsupported_in_era, :modern}), data}

  defp op_action(:roots_list_changed, _params, data) do
    if Map.has_key?(Data.client_capabilities(data, :legacy), "roots"),
      do: {:notify, "notifications/roots/list_changed", %{}, data},
      else: {:error, Error.new(:protocol, :roots_not_declared), data}
  end

  defp put_log_level(data, level), do: %{data | log: %{data.log | level: level}}

  defp send_new(method, params, mref, caller, opts, data) do
    if map_size(data.pending) >= data.config.max_in_flight do
      reply(mref, {:error, Error.new(:overloaded, :max_in_flight)})
      {data, []}
    else
      {id, data} = Data.take_id(data)
      info = if Keyword.get(opts, :progress, false), do: %{progress_token: id}, else: %{}
      info = Map.put(info, :extensions, Keyword.get(opts, :extensions, %{}))
      info = Map.put(info, :traceparent, Keyword.get(opts, :traceparent))

      wire_opts = Keyword.take(opts, [:headers, :max_deadline])

      case Data.send_request(data, id, method, params, info, mref, wire_opts) do
        {:ok, handle, data} ->
          entry = %{
            mref: mref,
            caller_mon: Process.monitor(caller),
            method: method,
            handle: handle,
            deadline: Keyword.fetch!(opts, :deadline),
            max_deadline: Keyword.fetch!(opts, :max_deadline),
            timeout: Keyword.fetch!(opts, :timeout),
            reset?: Keyword.get(opts, :reset_on_progress, false),
            assigns: Keyword.get(opts, :assigns),
            paused: 0,
            paused_at: nil,
            params: params,
            info: info,
            wire_opts: wire_opts
          }

          reply(mref, {:accepted, id})
          {track(data, id, entry), [timer(id, entry.deadline)]}

        {:error, reason, data} ->
          reply(mref, {:error, Error.new(:transport, reason)})
          {data, []}
      end
    end
  end

  defp track(data, id, entry) do
    refs = data.refs |> Map.put(entry.mref, id) |> Map.put(entry.caller_mon, id)
    %{data | pending: Map.put(data.pending, id, entry), refs: refs}
  end

  @doc """
  A response for request `id`. Returns `:renegotiate` (with the caller
  already answered) when a ready modern connection learns the server no
  longer accepts its version (`-32022`).
  """
  @spec response(pos_integer(), map(), atom(), Data.t()) ::
          {:ok | :renegotiate | :dropped, Data.t(), [:gen_statem.action()]}
  def response(id, message, state, data) do
    case pop(data, id) do
      {nil, data} ->
        Telemetry.dropped(Data.telemetry(data), id)
        {:dropped, data, []}

      {entry, data} ->
        reply(entry.mref, {:response, message})
        {renegotiate(message, state, data), data, [cancel_timer(id)]}
    end
  end

  defp renegotiate(%{"error" => %{"code" => @unsupported_protocol_version}}, :ready, %{
         era: :modern
       }),
       do: :renegotiate

  defp renegotiate(_message, _state, _data), do: :ok

  @doc """
  `{:exchange_done, id, outcome}`: the transport finished request `id`. On
  `:ok` it already delivered the response to the caller.
  """
  @spec exchange_done(pos_integer(), :ok | {:error, term()}, Data.t()) :: result()
  def exchange_done(id, outcome, data) do
    case pop(data, id) do
      {nil, data} ->
        {data, []}

      {entry, data} ->
        case outcome do
          :ok -> :ok
          {:error, %Error{} = error} -> reply(entry.mref, {:error, error})
          {:error, reason} -> reply(entry.mref, {:error, Error.new(:transport, reason)})
        end

        {data, [cancel_timer(id)]}
    end
  end

  @doc """
  Sends pending request `id` again, with the same id, params and envelope:
  the server refused it with HTTP 401 and OAuth now has a token. A request
  no longer pending is skipped.
  """
  @spec resend(Data.t(), pos_integer()) :: result()
  def resend(data, id) do
    case Map.fetch(data.pending, id) do
      {:ok, entry} ->
        case Data.send_request(
               data,
               id,
               entry.method,
               entry.params,
               entry.info,
               entry.mref,
               entry.wire_opts
             ) do
          {:ok, handle, data} ->
            {put_entry(data, id, %{entry | handle: handle}), []}

          {:error, reason, data} ->
            exchange_done(id, {:error, reason}, data)
        end

      :error ->
        {data, []}
    end
  end

  @doc """
  The server refused request `id` with HTTP 401 or 403: answer `kind:
  :auth`, with the status and the parsed `WWW-Authenticate` challenges in
  `data`. `:unknown` when `id` is not a caller's request.
  """
  @spec unauthorized(pos_integer(), map(), Data.t()) :: result() | :unknown
  def unauthorized(id, info, data) do
    case pop(data, id) do
      {nil, _data} ->
        :unknown

      {entry, data} ->
        reply(entry.mref, {:error, auth_error(info)})
        {data, [cancel_timer(id)]}
    end
  end

  @doc "The `kind: :auth` error for an HTTP 401/403 (`%{status:, challenges:}`)."
  @spec auth_error(map()) :: Error.t()
  def auth_error(%{status: status} = info) do
    challenges = Map.get(info, :challenges, [])

    reason =
      cond do
        status == 401 -> :unauthorized
        Enum.any?(challenges, &Challenge.insufficient_scope?/1) -> :insufficient_scope
        true -> :forbidden
      end

    Error.new(:auth, reason, %{status: status, challenges: challenges})
  end

  @doc "The deadline of request `id` passed: cancel it and answer `:timeout`."
  @spec timeout(pos_integer(), Data.t()) :: result()
  def timeout(id, data) do
    case Map.fetch(data.pending, id) do
      {:ok, entry} ->
        data = cancel(data, id, entry, :timeout)
        reply(entry.mref, {:error, Error.new(:timeout)})
        {data, []}

      :error ->
        {data, []}
    end
  end

  @doc """
  The caller gave up (`$mcp_cancel` on its alias) or died (`:DOWN` of the
  connection's monitor). `:unknown` when `ref` is not a request's.
  """
  @spec cancel_ref(reference(), atom(), Data.t()) :: result() | :unknown
  def cancel_ref(ref, reason, data) do
    case Map.fetch(data.refs, ref) do
      {:ok, id} ->
        data = cancel(data, id, Map.fetch!(data.pending, id), reason)
        {data, [cancel_timer(id)]}

      :error ->
        :unknown
    end
  end

  defp cancel(data, id, entry, reason) do
    Telemetry.cancel(Data.telemetry(data), entry.method, id, reason)
    {_entry, data} = pop(data, id)
    Data.cancel(data, id, entry.handle, reason)
  end

  @doc """
  `notifications/progress`: forwarded to the request whose id is the
  `progressToken` (unknown tokens are ignored); re-arms its deadline when it
  asked for `reset_timeout_on_progress`.
  """
  @spec progress(map(), Data.t()) :: result()
  def progress(%{"progressToken" => id} = params, data) do
    case Map.fetch(data.pending, id) do
      {:ok, entry} ->
        reply(entry.mref, {:progress, params})
        extend(data, id, entry)

      :error ->
        {data, []}
    end
  end

  def progress(_params, data), do: {data, []}

  defp extend(data, id, %{reset?: true, paused: 0} = entry) do
    deadline = min(now_ms() + entry.timeout, entry.max_deadline)
    entry = %{entry | deadline: deadline}
    {%{data | pending: Map.put(data.pending, id, entry)}, [timer(id, deadline)]}
  end

  defp extend(data, _id, _entry), do: {data, []}

  @doc """
  A legacy server request tied to request `id` started: the request's
  deadline stops running (bounded by its `max_deadline`). `nil` or an id no
  longer pending changes nothing.
  """
  @spec pause(Data.t(), term()) :: result()
  def pause(data, id) do
    case Map.fetch(data.pending, id) do
      {:ok, %{paused: 0} = entry} ->
        reply(entry.mref, {:deadline, entry.max_deadline})
        entry = %{entry | paused: 1, paused_at: now_ms()}
        {put_entry(data, id, entry), [timer(id, entry.max_deadline)]}

      {:ok, entry} ->
        {put_entry(data, id, %{entry | paused: entry.paused + 1}), []}

      :error ->
        {data, []}
    end
  end

  @doc "The server request tied to request `id` ended: undo one `pause/2`."
  @spec resume(Data.t(), term()) :: result()
  def resume(data, id) do
    case Map.fetch(data.pending, id) do
      {:ok, %{paused: 1} = entry} ->
        deadline = min(entry.deadline + (now_ms() - entry.paused_at), entry.max_deadline)
        reply(entry.mref, {:deadline, deadline})
        entry = %{entry | paused: 0, paused_at: nil, deadline: deadline}
        {put_entry(data, id, entry), [timer(id, deadline)]}

      {:ok, %{paused: paused} = entry} when paused > 1 ->
        {put_entry(data, id, %{entry | paused: paused - 1}), []}

      _not_paused ->
        {data, []}
    end
  end

  @doc "The `assigns` of pending request `id`, or `nil`."
  @spec assigns(Data.t(), term()) :: map() | nil
  def assigns(data, id) do
    case Map.fetch(data.pending, id) do
      {:ok, entry} -> entry.assigns
      :error -> nil
    end
  end

  defp put_entry(data, id, entry), do: %{data | pending: Map.put(data.pending, id, entry)}

  @doc "Answers every pending request with `error` and forgets them."
  @spec fail_all(Data.t(), Error.t()) :: result()
  def fail_all(data, %Error{} = error) do
    actions =
      for {id, entry} <- data.pending do
        Process.demonitor(entry.caller_mon, [:flush])
        reply(entry.mref, {:error, error})
        cancel_timer(id)
      end

    {%{data | pending: %{}, refs: %{}}, actions}
  end

  defp pop(data, id) do
    case Map.pop(data.pending, id) do
      {nil, _pending} ->
        {nil, data}

      {entry, pending} ->
        Process.demonitor(entry.caller_mon, [:flush])
        refs = Map.drop(data.refs, [entry.mref, entry.caller_mon])
        {entry, %{data | pending: pending, refs: refs}}
    end
  end

  @doc "Sends `message` to a caller's alias."
  @spec reply(reference(), term()) :: :ok
  def reply(mref, message) do
    send(mref, {mref, message})
    :ok
  end

  defp timer(id, deadline), do: {{:timeout, {:req, id}}, deadline, id, [{:abs, true}]}
  defp cancel_timer(id), do: {{:timeout, {:req, id}}, :cancel}

  defp now_ms, do: System.monotonic_time(:millisecond)
end

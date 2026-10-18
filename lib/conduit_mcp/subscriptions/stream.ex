defmodule ConduitMcp.Subscriptions.Stream do
  @moduledoc false

  # Serves a `subscriptions/listen` stream on a POST: the `{:stream, spec}`
  # branch of `ConduitMcp.Transport.Shared.dispatch_post/2` for a spec of kind
  # `:listen`. Runs in the request process, which registers itself in
  # `ConduitMcp.Subscriptions` and relays what is published to its topics
  # until one side ends the stream. No user code runs here.
  #
  # Admission, before anything is sent, so a refusal is a plain JSON-RPC
  # error body:
  #
  #   * `:max_listens_per_principal` live streams per principal
  #     (`ConduitMcp.Principal.rate_limit_key/1`: the principal id, else the
  #     client's address bucket) - never refused: at the cap, the principal's
  #     OLDEST stream is superseded (`Subscriptions.admit/3`) and ends with
  #     the server-initiated teardown below, reason `:superseded`. A client
  #     that disconnected is only noticed on the next write, so refusing
  #     would lock out a client that opens a listen per run (the MCP
  #     Inspector CLI) for up to two keep-alive intervals; superseding keeps
  #     the same bound (SV-10) without that.
  #   * a `:max_streams` slot in `SSEStream.streams_table/0`, the cap shared
  #     with streamed `tools/call` responses - HTTP 503 when full. A
  #     `tools/call` at the cap can still be answered as plain JSON; a listen
  #     cannot, and the server-wide cap is the server's capacity, not
  #     anything this client did, so it is 503.
  #
  # Then, in order: register the topics (so nothing published after the
  # acknowledgment is missed), open the SSE response, send
  # `notifications/subscriptions/acknowledged`, loop. Every message carries
  # `_meta["io.modelcontextprotocol/subscriptionId"]` = the listen request id.
  #
  # Endings:
  #
  #   * the client goes away - a write (notification or keep-alive) fails:
  #     nothing more is sent;
  #   * the deadline - `:max_stream_lifetime`, or the bearer token's `exp`
  #     when that comes first - or `:listen_idle_timeout` with no
  #     notification delivered, or a newer listen of the same principal
  #     superseding this one at the cap: the server ends the subscription,
  #     sending `notifications/cancelled` for the listen id and then the
  #     graceful-closure result (`SubscriptionsListenResult`), in that order:
  #     the cancellation page makes the first a MUST, the subscriptions page
  #     the second a SHOULD.
  #
  # Registry entries and the slot are released in an `after`: under HTTP/1.1
  # keep-alive this process serves the connection's next request. A killed
  # process leaks neither: the registry drops a dead registrant's entries,
  # and a dead pid's slot row is swept by `SSEStream.acquire_slot/3`.

  require Logger

  import Plug.Conn

  alias ConduitMcp.Ctx
  alias ConduitMcp.Errors
  alias ConduitMcp.Notifications
  alias ConduitMcp.Principal
  alias ConduitMcp.Protocol
  alias ConduitMcp.StreamSpec
  alias ConduitMcp.Subscriptions
  alias ConduitMcp.Transport.SSEStream

  @subscription_id "io.modelcontextprotocol/subscriptionId"

  @doc """
  Serves the listen `spec` on `conn` and returns the finished conn.
  """
  @spec run(Plug.Conn.t(), StreamSpec.t()) :: Plug.Conn.t()
  def run(conn, %StreamSpec{kind: :listen, subscription: filter} = spec) do
    principal = Principal.rate_limit_key(conn)
    table = SSEStream.streams_table()
    ref = make_ref()

    try do
      # The slot first: a listen refused 503 must not supersede anything.
      if acquire_slot(table, conn.private[:max_streams]) do
        :ok = Subscriptions.admit(principal, conn.private[:max_listens_per_principal], ref)
        serve(conn, spec, ref)
      else
        reject(conn, spec, 503, "Too many open streams")
      end
    after
      Subscriptions.leave(filter.topics, principal)
      SSEStream.release_slot(table)
      flush(ref)
    end
  end

  defp acquire_slot(table, max) do
    SSEStream.ensure_slot_table(table)
    SSEStream.acquire_slot(table, max)
  end

  defp reject(conn, spec, status, message) do
    Logger.warning("subscriptions/listen refused: #{message}", status: status)

    body =
      Protocol.error_response(spec.request_id, Errors.server_error(), message)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  # --- the stream -------------------------------------------------------------

  defp serve(conn, %StreamSpec{subscription: filter} = spec, ref) do
    :ok = Subscriptions.subscribe(filter.topics, ref)
    conn = SSEStream.open(conn)
    started = System.monotonic_time()
    metadata = %{filters: filter.kinds, server_module: conn.private[:server_module]}

    :telemetry.execute(
      [:conduit_mcp, :subscription, :start],
      %{system_time: System.system_time(), resource_subscriptions: resource_count(filter)},
      metadata
    )

    ack = Notifications.subscriptions_acknowledged_notification(filter.ack)

    {conn, reason} =
      case SSEStream.send_frame(conn, frame(ack, spec.request_id)) do
        {:ok, conn} -> listen(conn, spec, ref)
        {:error, _reason} -> {conn, :client_closed}
      end

    :telemetry.execute(
      [:conduit_mcp, :subscription, :stop],
      %{duration: System.monotonic_time() - started},
      Map.put(metadata, :reason, reason)
    )

    conn
  end

  defp resource_count(filter),
    do: Enum.count(filter.topics, &match?({:resource, _uri}, &1))

  defp listen(conn, spec, ref) do
    now = now()
    {deadline, deadline_reason} = deadline(conn, now)
    idle_timeout = conn.private[:listen_idle_timeout]

    state = %{
      ref: ref,
      id: spec.request_id,
      idle_timeout: idle_timeout,
      idle_deadline: now + idle_timeout,
      deadline_reason: deadline_reason,
      reason: nil
    }

    conn
    |> SSEStream.loop(state,
      interval: conn.private[:keep_alive_interval],
      deadline: deadline,
      on_message: &on_message/3,
      on_tick: &on_tick/2
    )
    |> finish(spec)
  end

  # SV-3: a stream must not outlive the credential that opened it. `exp` is
  # in the verified OAuth claims (`ConduitMcp.Plugs.OAuth`); no other
  # strategy carries one.
  defp deadline(conn, now) do
    lifetime = now + conn.private[:max_stream_lifetime]

    case token_deadline(conn, now) do
      expiry when is_integer(expiry) and expiry < lifetime -> {expiry, :token_expired}
      _ -> {lifetime, :max_lifetime}
    end
  end

  defp token_deadline(conn, now) do
    case Principal.get(conn) do
      %{claims: %{"exp" => exp}} when is_integer(exp) ->
        now + (exp * 1_000 - System.system_time(:millisecond))

      _ ->
        nil
    end
  end

  # --- loop callbacks ---------------------------------------------------------

  defp on_message({Subscriptions, ref, :superseded}, conn, %{ref: ref} = state),
    do: {:halt, conn, %{state | reason: :superseded}}

  defp on_message({Subscriptions, ref, notification}, conn, %{ref: ref} = state) do
    case encode(notification, state.id) do
      nil ->
        {:cont, conn, state}

      frame ->
        case SSEStream.send_frame(conn, frame) do
          {:ok, conn} -> {:cont, conn, %{state | idle_deadline: now() + state.idle_timeout}}
          {:error, _reason} -> {:closed, conn, state}
        end
    end
  end

  defp on_message(_message, conn, state), do: {:cont, conn, state}

  defp on_tick(conn, state) do
    if now() >= state.idle_deadline do
      {:halt, conn, %{state | reason: :idle_timeout}}
    else
      case SSEStream.keep_alive(conn) do
        {:ok, conn} -> {:cont, conn, state}
        {:error, _reason} -> {:closed, conn, state}
      end
    end
  end

  # `ConduitMcp.Subscriptions.publish/2` takes any map; one that cannot be
  # encoded is dropped here rather than taking the stream down.
  defp encode(notification, id) do
    frame(notification, id)
  rescue
    error ->
      Logger.error("Dropping a subscription notification that is not JSON-encodable",
        error: Exception.message(error)
      )

      nil
  end

  # --- endings ----------------------------------------------------------------

  defp finish({:closed, conn, _state}, _spec), do: {conn, :client_closed}

  defp finish({:deadline, conn, state}, spec),
    do: {teardown(conn, spec, state.deadline_reason), state.deadline_reason}

  defp finish({:halt, conn, state}, spec),
    do: {teardown(conn, spec, state.reason), state.reason}

  defp teardown(conn, spec, reason) do
    Logger.debug("Ending subscriptions/listen stream", reason: reason)

    id = spec.request_id
    cancelled = Notifications.cancelled_notification(id, reason_text(reason))

    result =
      Protocol.Modern.to_response(
        id,
        "subscriptions/listen",
        {:ok, %{"_meta" => %{@subscription_id => id}}},
        server_info: server_info(spec)
      )

    with {:ok, conn} <- SSEStream.send_frame(conn, frame(cancelled, id)),
         {:ok, conn} <- SSEStream.send_frame(conn, SSEStream.frame(result)) do
      conn
    else
      {:error, _reason} -> conn
    end
  end

  defp reason_text(:max_lifetime), do: "Maximum stream lifetime reached"
  defp reason_text(:token_expired), do: "Access token expired"
  defp reason_text(:idle_timeout), do: "Subscription idle timeout"

  defp reason_text(:superseded),
    do: "Superseded by a newer subscriptions/listen stream of the same principal"

  defp server_info(spec) do
    case Ctx.from_conn(spec.conn) do
      %Ctx{server_info: server_info} -> server_info
      nil -> nil
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp frame(message, id), do: message |> tag(id) |> SSEStream.frame()

  defp tag(message, id) do
    params = Map.get(message, "params") || %{}
    meta = Map.get(params, "_meta") || %{}

    Map.put(message, "params", Map.put(params, "_meta", Map.put(meta, @subscription_id, id)))
  end

  # Notifications published after the loop stopped reading.
  defp flush(ref) do
    receive do
      {Subscriptions, ^ref, _notification} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

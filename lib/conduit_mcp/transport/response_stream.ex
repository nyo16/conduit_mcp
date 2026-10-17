defmodule ConduitMcp.Transport.ResponseStream do
  @moduledoc false

  # Sends a `ConduitMcp.StreamSpec` response on a POST: the `{:stream, spec}`
  # branch of `ConduitMcp.Transport.Shared.dispatch_post/2`.
  #
  # The work (`spec.run`) runs in a `Task.async/1` linked to the request
  # process, which meanwhile sits in `ConduitMcp.Transport.SSEStream.loop/3`
  # relaying what the work sends. The request process never runs user code;
  # the task never touches the socket.
  #
  # The stream is opened lazily. Until the work emits a notification, or the
  # first keep-alive tick comes due, nothing has been sent, so a result that
  # arrives first is answered as plain JSON with its proper status - an
  # OAuth insufficient-scope error still gets its 403 challenge. Once open,
  # the stream carries `notifications/*` events, keep-alive comments and
  # finally the response event, then closes.
  #
  # Bounds:
  #
  #   * `:max_streams` slots in `SSEStream.streams_table/0`. A request that
  #     would open a stream at the cap is answered as plain JSON instead: its
  #     notifications are dropped (it still runs - rejecting it would make
  #     sending a progressToken the thing that gets a client refused).
  #   * `:max_stream_lifetime`. At the deadline the request is cancelled; a
  #     tool that returns within `:stream_cancel_timeout` still has its
  #     response sent, otherwise it is killed and the response is -32603.
  #   * Disconnect. A failed write means the client is gone, which on a
  #     modern stream *is* cancellation: the request is marked cancelled
  #     (`ConduitMcp.Cancellation.cancel/3`) so the tool can see
  #     `ConduitMcp.Cancellation.cancelled?/1`, and after
  #     `:stream_cancel_timeout` the task is killed.
  #
  # The request is tracked in flight by the request process for the whole
  # exchange (`Pipeline.in_flight/3`), so its untrack and clear run even when
  # the task is killed. `spec.run` already turns a raise into -32603; a throw
  # or exit from the work is caught in execute/2 the same way, so the task
  # always exits normally and the link never takes the request process down.

  require Logger

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Errors
  alias ConduitMcp.Handler.Pipeline
  alias ConduitMcp.Protocol
  alias ConduitMcp.StreamSpec
  alias ConduitMcp.Transport.SSEStream

  @typedoc "Sends a response as a plain JSON body."
  @type send_json :: (Plug.Conn.t(), map() -> Plug.Conn.t())

  @doc """
  Runs `spec` and answers the POST on `conn`; `send_json` answers it when no
  stream was opened.
  """
  @spec run(Plug.Conn.t(), StreamSpec.t(), send_json()) :: Plug.Conn.t()
  def run(conn, %StreamSpec{} = spec, send_json) do
    Pipeline.in_flight(spec.conn, spec.request_id, fn work_conn ->
      ref = make_ref()
      work_conn = StreamSpec.put_sink(work_conn, self(), ref, spec.progress_token)
      task = Task.async(fn -> execute(spec, work_conn) end)
      state = %{spec: spec, ref: ref, task: task, mode: :pending, send_json: send_json}

      try do
        conn
        |> SSEStream.loop(state,
          interval: conn.private[:keep_alive_interval],
          deadline: System.monotonic_time(:millisecond) + conn.private[:max_stream_lifetime],
          on_message: &on_message/3,
          on_tick: &on_tick/2
        )
        |> finish()
      after
        flush(ref)
        # Releases only a slot this process holds, so a response that never
        # opened a stream frees nothing.
        SSEStream.release_slot(SSEStream.streams_table())
      end
    end)
  end

  # --- the work -------------------------------------------------------------

  defp execute(spec, conn) do
    spec.run.(conn)
  catch
    kind, reason ->
      Logger.error("Error handling streamed request",
        error: Exception.format_banner(kind, reason),
        method: spec.method,
        request_id: spec.request_id
      )

      internal_error(spec, "Internal server error")
  end

  defp internal_error(spec, message) do
    Protocol.Modern.to_response(
      spec.request_id,
      spec.method,
      {:error, Errors.internal_error(), message, nil}
    )
  end

  # --- loop callbacks -------------------------------------------------------

  defp on_message({StreamSpec, ref, {:frame, frame}}, conn, %{ref: ref} = state),
    do: emit(conn, state, frame)

  defp on_message({task_ref, response}, conn, %{task: %Task{ref: task_ref}} = state)
       when is_map(response) do
    Process.demonitor(task_ref, [:flush])
    {:halt, respond(conn, state, response), %{state | task: nil}}
  end

  # The task exited without replying. execute/2 catches everything, so only
  # an exit signal from outside does this.
  defp on_message(
         {:DOWN, task_ref, :process, _pid, _reason},
         conn,
         %{task: %Task{ref: task_ref}} = state
       ) do
    response = internal_error(state.spec, "Internal server error")
    {:halt, respond(conn, state, response), %{state | task: nil}}
  end

  defp on_message(_message, conn, state), do: {:cont, conn, state}

  # The first tick opens the stream: a slow tool's client then sees
  # keep-alives instead of an idle connection an intermediary may drop.
  defp on_tick(conn, %{mode: :pending} = state) do
    {conn, state} = open(conn, state)
    on_tick(conn, state)
  end

  defp on_tick(conn, %{mode: :streaming} = state) do
    case SSEStream.keep_alive(conn) do
      {:ok, conn} -> {:cont, conn, state}
      {:error, _reason} -> {:closed, conn, state}
    end
  end

  defp on_tick(conn, %{mode: :buffered} = state), do: {:cont, conn, state}

  defp emit(conn, %{mode: :pending} = state, frame) do
    {conn, state} = open(conn, state)
    emit(conn, state, frame)
  end

  defp emit(conn, %{mode: :streaming} = state, frame) do
    case SSEStream.send_frame(conn, frame) do
      {:ok, conn} -> {:cont, conn, state}
      {:error, _reason} -> {:closed, conn, state}
    end
  end

  defp emit(conn, %{mode: :buffered} = state, _frame), do: {:cont, conn, state}

  defp open(conn, state) do
    table = SSEStream.streams_table()
    SSEStream.ensure_slot_table(table)

    if SSEStream.acquire_slot(table, conn.private[:max_streams]) do
      {SSEStream.open(conn), %{state | mode: :streaming}}
    else
      Logger.warning(
        "Streamed response sent as JSON: at :max_streams; its notifications are dropped",
        method: state.spec.method,
        request_id: state.spec.request_id
      )

      {conn, %{state | mode: :buffered}}
    end
  end

  defp respond(conn, %{mode: :streaming} = state, response) do
    case SSEStream.send_frame(conn, response_frame(state.spec, response)) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp respond(conn, state, response), do: state.send_json.(conn, response)

  # Encoded here, under a rescue: the stream is already open, so a response
  # that is not JSON-encodable can no longer become an HTTP 500.
  defp response_frame(spec, response) do
    SSEStream.frame(response)
  rescue
    error ->
      Logger.error("Streamed response is not JSON-encodable",
        error: Exception.message(error),
        method: spec.method,
        request_id: spec.request_id
      )

      SSEStream.frame(internal_error(spec, "Internal server error"))
  end

  # --- endings --------------------------------------------------------------

  defp finish({:halt, conn, _state}), do: conn

  defp finish({:closed, conn, state}) do
    cancel(state, "client disconnected")
    stop(state.task, cancel_timeout(conn))
    conn
  end

  defp finish({:deadline, conn, state}) do
    Logger.warning("Streamed request reached :max_stream_lifetime; cancelling it",
      method: state.spec.method,
      request_id: state.spec.request_id
    )

    cancel(state, "maximum stream lifetime reached")

    response =
      case Task.yield(state.task, cancel_timeout(conn)) do
        {:ok, response} when is_map(response) ->
          response

        other ->
          if is_nil(other), do: Task.shutdown(state.task, :brutal_kill)
          internal_error(state.spec, "Request exceeded the maximum stream lifetime")
      end

    respond(conn, state, response)
  end

  defp cancel(%{spec: spec}, reason) do
    _ = Cancellation.cancel(spec.request_id, reason, Cancellation.scope(spec.conn))
    :ok
  end

  # Gives a cancelled tool `timeout` to notice and return, then kills it.
  # `Task.shutdown/2` unlinks first, so the kill never reaches this process.
  defp stop(task, timeout) do
    case Task.yield(task, timeout) do
      nil -> Task.shutdown(task, :brutal_kill)
      _result -> :ok
    end
  end

  defp cancel_timeout(conn), do: conn.private[:stream_cancel_timeout]

  # Notifications the task sent after the loop stopped reading. Under HTTP/1.1
  # keep-alive the next request runs in this same process.
  defp flush(ref) do
    receive do
      {StreamSpec, ^ref, _frame} -> flush(ref)
    after
      0 -> :ok
    end
  end
end

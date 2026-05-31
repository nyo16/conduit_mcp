defmodule ConduitMcp.Cancellation do
  @moduledoc """
  Cooperative request cancellation for long-running tools.

  MCP clients can abort an in-flight request by sending
  `notifications/cancelled` with the original request's id. Because
  ConduitMCP is stateless and each HTTP request runs in its own Bandit
  process, the notification (which arrives on a *different* request)
  cannot directly preempt the in-flight handler. Instead, the handler
  records the cancellation in a shared ETS table and tool code polls
  this module to decide whether to abort.

  ## Tool integration

  Inside a long-running tool, periodically check the conn's request id:

      def my_long_tool(conn, params) do
        ConduitMcp.Cancellation.cancelled?(conn)
        |> case do
          true -> {:error, %{"code" => -32800, "message" => "Request cancelled"}}
          false -> continue_work(...)
        end
      end

  Or use the `Process.exit/2` pattern for hard abort. Tools that complete
  in tens of milliseconds typically do not need cancellation at all — the
  client's notification will arrive after the response has already been
  sent.

  ## Lifecycle

  - The handler stashes the request id into `conn.assigns[:mcp_request_id]`
    before dispatching to the server callback.
  - On `notifications/cancelled` arrival, the cancellation flag is set
    with `cancel/2`.
  - When a request completes (success or error), the handler calls
    `clear/1` to release the flag so the entry does not linger.
  - For pathological cases (cancel arrives after completion has already
    cleared the entry, or the server crashes before clear runs),
    `cleanup/1` can be called periodically to prune stale entries by
    age. There is no janitor wired by default — cancellation entries
    are bounded by the rate of in-flight cancellations.

  Emits `[:conduit_mcp, :request, :cancelled]` telemetry on cancellation
  with metadata `%{request_id: id, reason: reason}`.
  """

  @table :conduit_mcp_cancellations

  @doc """
  Marks a request id as cancelled with an optional reason.
  """
  def cancel(request_id, reason \\ nil)
  def cancel(nil, _reason), do: :ok

  def cancel(request_id, reason) do
    ensure_table()
    id = to_string(request_id)

    :ets.insert(@table, {
      id,
      %{
        "reason" => reason,
        "cancelled_at" => System.system_time(:millisecond)
      }
    })

    :telemetry.execute(
      [:conduit_mcp, :request, :cancelled],
      %{count: 1},
      %{request_id: id, reason: reason}
    )

    :ok
  end

  @doc """
  Returns `true` when the given request has been cancelled.

  Accepts a request id directly, or a `Plug.Conn` whose `assigns` contains
  `:mcp_request_id` (set by `ConduitMcp.Handler` before dispatch).
  """
  def cancelled?(%Plug.Conn{assigns: %{mcp_request_id: id}}), do: cancelled?(id)
  def cancelled?(%Plug.Conn{}), do: false
  def cancelled?(nil), do: false

  def cancelled?(request_id) do
    ensure_table()
    :ets.member(@table, to_string(request_id))
  end

  @doc """
  Returns the cancellation reason recorded for the request, or `nil`.
  """
  def reason(request_id) do
    ensure_table()

    case :ets.lookup(@table, to_string(request_id)) do
      [{_, %{"reason" => reason}}] -> reason
      [] -> nil
    end
  end

  @doc """
  Clears a request id from the cancellation set. Idempotent.
  """
  def clear(nil), do: :ok

  def clear(request_id) do
    ensure_table()
    :ets.delete(@table, to_string(request_id))
    :ok
  end

  @doc """
  Removes cancellation entries older than `ttl_ms` milliseconds. Defensive —
  the handler clears entries inline when a request completes; this is for
  the rare case where a cancel arrived after a crash or after the response
  was already sent.

  Returns the number of entries removed.
  """
  def cleanup(ttl_ms) do
    ensure_table()
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {id, %{"cancelled_at" => at}}, acc ->
        if now - at > ttl_ms do
          :ets.delete(@table, id)
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    # Lost a check-then-create race with a concurrent request — the table
    # now exists, which is all we need.
    ArgumentError -> :ok
  end

  defmodule Owner do
    @moduledoc """
    Long-lived process that owns the `:conduit_mcp_cancellations` ETS
    table so concurrent Bandit request handlers don't race on
    `:ets.new/2` when the table doesn't exist yet (each handler calls
    `Cancellation.clear/1` from a `try/after`). Started under
    `ConduitMcp.Supervisor` by `ConduitMcp.Application`.
    """

    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          :ets.new(:conduit_mcp_cancellations, [
            :named_table,
            :public,
            :set,
            read_concurrency: true
          ])

          :ok
        end,
        name: __MODULE__
      )
    end
  end
end

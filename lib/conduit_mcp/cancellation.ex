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

  Inside a long-running tool, periodically check the conn:

      def my_long_tool(conn, params) do
        if ConduitMcp.Cancellation.cancelled?(conn) do
          {:error, %{"code" => ConduitMcp.Errors.request_cancelled(), "message" => "Request cancelled"}}
        else
          continue_work(...)
        end
      end

  Tools that complete in tens of milliseconds typically do not need
  cancellation at all — the client's notification will arrive after the
  response has already been sent.

  ## Scoping

  JSON-RPC ids are **client-chosen** and conventionally small integers, so
  the table cannot be keyed on the id alone: a single
  `POST {"method":"notifications/cancelled","params":{"requestId":"1"}}`
  would abort every concurrent client's request id `1`, and looping `1..1000`
  would abort every in-flight tool call on the node.

  Rows are therefore keyed `{scope, id}`, where `scope/1` derives the caller
  from the `Plug.Conn`, most specific first:

    1. `conn.private[:mcp_session_id]` — set by
       `ConduitMcp.Transport.StreamableHTTP` when sessions are configured.
    2. `ConduitMcp.Principal.id/1` — the authenticated principal.
    3. `ConduitMcp.Principal.client_ip/1` — the last resort.

  > #### Enable sessions or auth {: .warning}
  >
  > With neither sessions nor authentication, the scope falls back to the
  > client IP, so clients sharing a source address (behind a proxy or NAT)
  > share a cancellation namespace and can still abort each other's requests.
  > Configure `:session` or `:auth` on the transport to get real isolation.

  ## Bounds

  `notifications/cancelled` is reachable unauthenticated, so the table is
  bounded two ways:

    * **Per-scope quota.** `cancel/3` refuses to insert past
      `config :conduit_mcp, :cancellations_max_rows_per_scope` (default 256)
      and returns `{:error, :cancellation_limit_reached}`. This is the bound
      that matters, and the only one that rejects: a *global* cap alone is a
      cross-tenant denial of service, because one unauthenticated client
      filling the table stops every other client's cancellations from being
      recorded.
    * **Global cap.** A memory backstop at
      `config :conduit_mcp, :cancellations_max_rows` (default #{10_000};
      `:infinity` disables it). It never rejects — a caller under its own
      quota is always served. Reaching it reclaims a batch of the *oldest rows
      of the largest scope*, so the client responsible for the pressure is the
      one that pays. Checking it before the per-scope quota, as an earlier
      revision did, reinstated the very DoS the quota exists to prevent: 40
      sessions x 256 rows exceeds 10 000 without any single scope being over
      quota.

  A row is normally removed inline: the handler calls `clear/2` in a
  `try/after` once the request completes. The cap and janitor cover the cases
  where that never happens — a cancel that arrives after completion, or a
  crash before `clear/2` runs.

  Ids must be a string or an integer (JSON-RPC's own constraint); anything
  else is rejected with `{:error, :invalid_request_id}` rather than crashing
  the request process. Reasons are truncated and stripped of control
  characters via `ConduitMcp.Reflect`.

  Emits `[:conduit_mcp, :request, :cancelled]` telemetry on cancellation
  with metadata `%{request_id: id, scope: scope, reason: reason}`, and
  `[:conduit_mcp, :cancellation, :cleanup]` with measurement
  `%{removed: count}` on each `cleanup/1` pass.
  """

  alias ConduitMcp.Principal
  alias ConduitMcp.Reflect

  @table :conduit_mcp_cancellations
  # `ordered_set`, not `set`: rows are keyed `{scope, id}`, so a scope's rows
  # are contiguous and the per-scope quota below is a bounded range scan rather
  # than a full-table one.
  @table_opts [
    :named_table,
    :public,
    :ordered_set,
    read_concurrency: true,
    write_concurrency: :auto
  ]

  @default_max_rows 10_000
  # A global cap alone is a cross-tenant denial of service: one unauthenticated
  # client filling the table stops every *other* client's cancellations from
  # being recorded. The per-scope quota is the bound that matters; the global
  # cap stays as a second backstop.
  @default_max_rows_per_scope 256
  @max_reason_length 200

  @typedoc "The caller a cancellation belongs to. See the Scoping section."
  @type scope :: String.t()

  @typedoc "A JSON-RPC request id: string or integer."
  @type request_id :: String.t() | integer()

  @doc false
  def table_opts, do: @table_opts

  @doc """
  Derives the cancellation scope for a connection.

  The same conn shape must yield the same scope on the request being
  cancelled and on the `notifications/cancelled` that cancels it, which is
  why every component of this is per-client and not per-request.
  """
  @spec scope(Plug.Conn.t() | map() | nil) :: scope()
  def scope(%Plug.Conn{} = conn) do
    conn.private[:mcp_session_id] || Principal.id(conn) || Principal.client_ip(conn)
  end

  def scope(_conn), do: "global"

  @doc """
  Marks a request id as cancelled within `scope`, with an optional reason.

  Returns `:ok`, `{:error, :invalid_request_id}` for an id that is not a
  string or integer, or `{:error, :cancellation_limit_reached}` when the
  table is at its configured cap.
  """
  @spec cancel(request_id() | nil, term(), scope()) ::
          :ok | {:error, :invalid_request_id | :cancellation_limit_reached}
  def cancel(request_id, reason \\ nil, scope \\ "global")

  def cancel(nil, _reason, _scope), do: :ok

  def cancel(request_id, reason, scope) when is_binary(request_id) or is_integer(request_id) do
    ensure_table()
    id = to_string(request_id)

    cond do
      # Per-scope FIRST. The global cap must never refuse a caller that is
      # under its own quota: checking it first meant one unauthenticated client
      # opening 40 sessions and filling each scope's 256 rows (10 240 > the
      # 10 000 global default) denied cancellation to every other client - the
      # exact cross-tenant denial of service the per-scope quota was added to
      # prevent, and which the moduledoc above claims it prevents.
      scope_at_capacity?(scope) ->
        {:error, :cancellation_limit_reached}

      # Global cap reached, but this scope is within its quota. The global cap
      # is a memory backstop, not a fairness control, so reclaim from whoever
      # is actually responsible rather than punishing the caller.
      at_capacity?() ->
        reclaim()
        insert_cancellation(scope, id, reason)

      true ->
        insert_cancellation(scope, id, reason)
    end
  end

  # A JSON-RPC id is a string, a number, or null. Anything else is a
  # malformed request, not a 500: `to_string(%{})` used to raise here and the
  # notification path had no rescue.
  def cancel(_request_id, _reason, _scope), do: {:error, :invalid_request_id}

  defp insert_cancellation(scope, id, reason) do
    reason = truncate_reason(reason)

    :ets.insert(@table, {
      {scope, id},
      %{
        "reason" => reason,
        "cancelled_at" => System.system_time(:millisecond)
      }
    })

    :telemetry.execute(
      [:conduit_mcp, :request, :cancelled],
      %{count: 1},
      %{request_id: id, scope: scope, reason: reason}
    )

    :ok
  end

  @doc """
  Returns `true` when the given request has been cancelled.

  Accepts a `Plug.Conn` whose `assigns` carries `:mcp_request_id` (set by
  `ConduitMcp.Handler` before dispatch) — the conn also supplies the scope —
  or an explicit id plus scope.
  """
  @spec cancelled?(Plug.Conn.t() | request_id() | nil) :: boolean()
  def cancelled?(%Plug.Conn{assigns: %{mcp_request_id: id}} = conn),
    do: cancelled?(id, scope(conn))

  def cancelled?(%Plug.Conn{}), do: false
  def cancelled?(nil), do: false
  def cancelled?(request_id), do: cancelled?(request_id, "global")

  @spec cancelled?(request_id() | nil, scope()) :: boolean()
  def cancelled?(nil, _scope), do: false

  def cancelled?(request_id, scope) when is_binary(request_id) or is_integer(request_id) do
    ensure_table()
    :ets.member(@table, {scope, to_string(request_id)})
  end

  def cancelled?(_request_id, _scope), do: false

  @doc """
  Returns the cancellation reason recorded for the request, or `nil`.
  """
  @spec reason(request_id(), scope()) :: String.t() | nil
  def reason(request_id, scope \\ "global")

  def reason(request_id, scope) when is_binary(request_id) or is_integer(request_id) do
    ensure_table()

    case :ets.lookup(@table, {scope, to_string(request_id)}) do
      [{_key, %{"reason" => reason}}] -> reason
      [] -> nil
    end
  end

  def reason(_request_id, _scope), do: nil

  @doc """
  Clears a request id from the cancellation set. Idempotent.
  """
  @spec clear(request_id() | nil, scope()) :: :ok
  def clear(request_id, scope \\ "global")

  def clear(nil, _scope), do: :ok

  def clear(request_id, scope) when is_binary(request_id) or is_integer(request_id) do
    ensure_table()
    :ets.delete(@table, {scope, to_string(request_id)})
    :ok
  end

  def clear(_request_id, _scope), do: :ok

  @doc """
  Removes cancellation entries older than `ttl_ms` milliseconds.

  Returns the number of entries removed. Emits
  `[:conduit_mcp, :cancellation, :cleanup]` telemetry with measurement
  `%{removed: count}` so eviction is observable.
  """
  @spec cleanup(non_neg_integer()) :: non_neg_integer()
  def cleanup(ttl_ms) do
    ensure_table()
    now = System.system_time(:millisecond)

    # Deleting the *current* element during `:ets.foldl` is guaranteed safe by
    # ETS for set tables — do NOT "fix" this into collect-then-delete.
    removed =
      :ets.foldl(
        fn {key, %{"cancelled_at" => at}}, acc ->
          if now - at > ttl_ms do
            :ets.delete(@table, key)
            acc + 1
          else
            acc
          end
        end,
        0,
        @table
      )

    :telemetry.execute([:conduit_mcp, :cancellation, :cleanup], %{removed: removed}, %{})

    removed
  end

  defp at_capacity? do
    case Application.get_env(:conduit_mcp, :cancellations_max_rows, @default_max_rows) do
      :infinity -> false
      max when is_integer(max) -> :ets.info(@table, :size) >= max
    end
  end

  # Counts only this scope's rows. On an `ordered_set` keyed `{scope, id}` the
  # match spec `{{scope, :_}, :_}` is a bounded range scan, so an attacker
  # cannot make this expensive for anyone but themselves — and cannot consume
  # anyone else's quota.
  defp scope_at_capacity?(scope) do
    case Application.get_env(
           :conduit_mcp,
           :cancellations_max_rows_per_scope,
           @default_max_rows_per_scope
         ) do
      :infinity ->
        false

      max when is_integer(max) ->
        :ets.select_count(@table, [{{{scope, :_}, :_}, [], [true]}]) >= max
    end
  end

  # Reclaims space when the global cap is reached, evicting the oldest rows of
  # whichever scope holds the most. That is the scope responsible for the
  # pressure, so a well-behaved caller is never the one that pays.
  #
  # A batch, not one row: finding the largest scope is a full-table scan, and
  # doing it per insert would hand an attacker an O(n) cost on every request
  # once the table is full. Evicting `max/20` rows amortises the scan to O(20)
  # per insert at the 10 000 default.
  defp reclaim do
    case largest_scope() do
      nil ->
        :ok

      victim ->
        batch = max(1, div(max_rows(), 20))

        @table
        |> :ets.select([{{{victim, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.sort_by(fn {_id, row} -> Map.get(row, "cancelled_at", 0) end)
        |> Enum.take(batch)
        |> Enum.each(fn {id, _row} -> :ets.delete(@table, {victim, id}) end)

        :ok
    end
  end

  defp largest_scope do
    @table
    |> :ets.select([{{{:"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.frequencies()
    |> Enum.max_by(fn {_scope, count} -> count end, fn -> nil end)
    |> case do
      nil -> nil
      {scope, _count} -> scope
    end
  end

  defp max_rows do
    case Application.get_env(:conduit_mcp, :cancellations_max_rows, @default_max_rows) do
      :infinity -> @default_max_rows
      max when is_integer(max) -> max
    end
  end

  defp truncate_reason(nil), do: nil
  defp truncate_reason(reason), do: Reflect.text(reason, @max_reason_length)

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, @table_opts)
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
    `Cancellation.clear/2` from a `try/after`). Started under
    `ConduitMcp.Supervisor` by `ConduitMcp.Application`.
    """

    # Not a GenServer itself: the process is a `ConduitMcp.EtsOwner`
    # registered under this module's name. This module is the child spec.
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    alias ConduitMcp.Cancellation

    def start_link(_opts) do
      ConduitMcp.EtsOwner.start_link(
        __MODULE__,
        :conduit_mcp_cancellations,
        Cancellation.table_opts()
      )
    end
  end
end

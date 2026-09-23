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

  The handler also tracks which requests are in flight: `track/2` when a
  request is dispatched, `untrack/2` when it completes. A cancellation is
  recorded only for a request `in_flight?/2` in the caller's scope; one for
  an unknown or already-completed request is ignored, as MCP permits.
  `cancel/3` itself does not check, so a library caller can still record a
  cancellation directly.

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

    1. `"session:" <> id` from `conn.private[:mcp_session_id]` — set by
       `ConduitMcp.Transport.StreamableHTTP` when sessions are configured.
    2. `"principal:" <> id` from `ConduitMcp.Principal.id/1` — the
       authenticated principal, when its id is a string (as
       `ConduitMcp.Principal.put/2` guarantees).
    3. `"ip:" <> bucket` from `ConduitMcp.Principal.client_bucket/1` — the
       last resort. That is the address for IPv4, and the /64 prefix for
       IPv6 (`"ip:2001:db8:1:2::/64"`), because a host is routinely handed a
       whole /64 and could otherwise rotate addresses to multiply its quota.

  The prefix keeps the three namespaces apart: a principal whose id happens
  to equal a client's IP string does not share that client's rows or quota.

  > #### Enable sessions or auth {: .warning}
  >
  > With neither sessions nor authentication, the scope falls back to the
  > client IP, so clients sharing a source address (behind a proxy or NAT)
  > share a cancellation namespace and can still abort each other's requests.
  > Configure `:session` or `:auth` on the transport to get real isolation.

  ## Bounds

  `notifications/cancelled` is reachable unauthenticated. Through the
  handler, a row is written only for a request in flight in the caller's
  scope, so a client can hold no more rows than it has requests running.
  The table is still bounded two ways, as a backstop for direct `cancel/3`
  callers and for requests that are long-running or leaked:

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
      quota is always served. Reaching it evicts a batch of `max_rows / 20`
      rows, oldest first from the largest scope, then from the next largest,
      so a client holding fewer rows than the largest scopes is evicted only
      after them. When every scope holds one row they all tie and eviction
      falls back to age, so the oldest rows go whoever owns them. The batch is
      always full, even then, so a lone writer runs the full-table scan that
      picks the rows at most once per batch of inserts; writers that hit the
      cap together each scan but evict overlapping rows. The per-scope quota
      is checked first: 40 sessions x 256 rows exceeds 10 000 without any
      single scope being over quota, and a global check that rejected would
      hand exactly that flood a cross-tenant denial of service.

  A row is normally removed inline: the handler calls `clear/2` in a
  `try/after` once the request completes. `clear/2` reads before it writes,
  so the common request, which was never cancelled, takes no write lock on
  the table. The cap and janitor cover the cases where the inline removal
  never happens — a cancel that races the request's completion, or a
  request process killed before `clear/2` runs.

  Ids must be an integer or a string of at most #{256} bytes (JSON-RPC
  requires a string or number); anything else is rejected with
  `{:error, :invalid_request_id}` rather than crashing the request process.
  Reasons are truncated and stripped of control characters via
  `ConduitMcp.Reflect`.

  ## In-flight rows

  `track/2` writes one row per request process, `{{scope, id}, pid}`, to a
  `duplicate_bag`, so concurrent requests reusing an id in one scope each hold
  their own row and one completing (`untrack/2` deletes only its own
  `{key, pid}` object) leaves the other cancellable. A request process killed
  before `untrack/2` runs (as an HTTP/2 stream can be) leaves its row behind;
  `cleanup/1` deletes rows whose process is no longer alive.

  Emits `[:conduit_mcp, :request, :cancelled]` telemetry on cancellation
  with metadata `%{request_id: id, scope: scope, reason: reason}`, where
  `scope` is the prefixed value described under Scoping, and
  `[:conduit_mcp, :cancellation, :cleanup]` on each `cleanup/1` pass with
  measurements `%{removed: count, in_flight_removed: count}`: expired
  cancellation rows and in-flight rows of dead processes respectively.
  """

  alias ConduitMcp.Principal
  alias ConduitMcp.Reflect

  @table :conduit_mcp_cancellations
  @in_flight_table :conduit_mcp_in_flight
  # `ordered_set`, not `set`: rows are keyed `{scope, id}`, so a scope's rows
  # are contiguous and the per-scope quota below is a bounded range scan
  # rather than a full-table one. An ordinary request only reads it (`clear/2`
  # checks before deleting); writes come from real cancels and the sweeps, so
  # the tree's single lock is not contended on the request path.
  @table_opts [
    :named_table,
    :public,
    :ordered_set,
    read_concurrency: true,
    write_concurrency: :auto
  ]

  # Written twice by every request with an id (`track/2`, `untrack/2`), so it
  # must not be an `ordered_set`: that table's contention-adapting tree holds
  # one row per in-flight request, churned constantly, stays a single base
  # node and serializes every writer on one lock. A hash table spreads keys
  # over fine-grained locks. `duplicate_bag` because the same `{scope, id}` may
  # be tracked by several processes at once. `write_concurrency: true` rather
  # than `:auto`: `:auto` also turns on decentralized counters, which make
  # `:ets.info(t, :size)` cost O(schedulers). The hash table's fine-grained
  # locks are what remove the contention; through `ConduitMcp.Handler` the two
  # settings measure the same, so the size stays cheap to read.
  @in_flight_table_opts [
    :named_table,
    :public,
    :duplicate_bag,
    read_concurrency: true,
    write_concurrency: true
  ]

  @max_request_id_bytes 256
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

  # An id this module stores: an integer, or a string within the byte cap. The
  # cap bounds the key of every row a client can make us write.
  defguardp is_request_id(id)
            when is_integer(id) or (is_binary(id) and byte_size(id) <= @max_request_id_bytes)

  @doc false
  def table_opts, do: @table_opts

  @doc false
  def in_flight_table_opts, do: @in_flight_table_opts

  @doc """
  Returns `true` for an id this module accepts: an integer, or a string of
  at most #{@max_request_id_bytes} bytes.
  """
  @spec valid_request_id?(term()) :: boolean()
  def valid_request_id?(request_id), do: is_request_id(request_id)

  @doc """
  Derives the cancellation scope for a connection.

  Returns `"session:" <> session_id`, `"principal:" <> principal_id` or
  `"ip:" <> ConduitMcp.Principal.client_bucket(conn)`, whichever is
  available first (see the Scoping section), and `"global"` for anything
  that is not a `Plug.Conn`. A principal id that is not a string (assigned
  without going through `ConduitMcp.Principal.put/2`) is ignored, and the IP
  scope is used.

  The same conn shape must yield the same scope on the request being
  cancelled and on the `notifications/cancelled` that cancels it, which is
  why every component of this is per-client and not per-request.
  """
  @spec scope(Plug.Conn.t() | map() | nil) :: scope()
  def scope(%Plug.Conn{} = conn) do
    session_id = conn.private[:mcp_session_id]
    principal_id = Principal.id(conn)

    cond do
      session_id -> "session:" <> session_id
      # `Principal.put/2` normalises ids to strings, but a plug can assign the
      # principal map directly. This runs in the handler's `after` block, so
      # raising on a non-binary id would fail every request with an id.
      is_binary(principal_id) -> "principal:" <> principal_id
      true -> "ip:" <> Principal.client_bucket(conn)
    end
  end

  def scope(_conn), do: "global"

  @doc """
  Marks a request id as cancelled within `scope`, with an optional reason.

  Returns `:ok`, `{:error, :invalid_request_id}` for an id that is neither an
  integer nor a string of at most #{@max_request_id_bytes} bytes, or
  `{:error, :cancellation_limit_reached}` when `scope` already holds its
  per-scope quota of rows. Only that quota rejects: when the table-wide cap
  is reached, rows are evicted from the largest scopes and the insert still
  succeeds.

  This records the cancellation whether or not the request is in flight.
  `ConduitMcp.Handler` calls it only for a request `in_flight?/2` in the
  caller's scope.
  """
  @spec cancel(request_id() | nil, term(), scope()) ::
          :ok | {:error, :invalid_request_id | :cancellation_limit_reached}
  def cancel(request_id, reason \\ nil, scope \\ "global")

  def cancel(nil, _reason, _scope), do: :ok

  def cancel(request_id, reason, scope) when is_request_id(request_id) do
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
  # notification path had no rescue. An over-long string is refused too.
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
    key = {scope, to_string(request_id)}

    # The handler clears after every request, and almost none was cancelled.
    # `member/2` takes a read lock, `delete/2` the exclusive one, so checking
    # first keeps ordinary requests off the write lock. Race-safe: the handler
    # untracks first, so no new row is recorded for this request after the
    # check; a row that appears later belongs to another request in flight
    # with the same id and scope, which is not this call's to remove.
    if :ets.member(@table, key), do: :ets.delete(@table, key)
    :ok
  end

  def clear(_request_id, _scope), do: :ok

  @doc """
  Records that the calling process is handling `request_id` in `scope`.

  `ConduitMcp.Handler` calls this before dispatching a request and
  `untrack/2` once it completes. A `nil` id and an id `valid_request_id?/1`
  rejects are ignored: such a request cannot be cancelled.
  """
  @spec track(request_id() | nil, scope()) :: :ok
  def track(request_id, scope) when is_request_id(request_id) do
    ensure_in_flight_table()
    :ets.insert(@in_flight_table, {{scope, to_string(request_id)}, self()})
    :ok
  rescue
    # The table vanished after ensure_in_flight_table/0. The request then
    # simply cannot be cancelled; failing it would be worse.
    ArgumentError -> :ok
  end

  def track(_request_id, _scope), do: :ok

  @doc """
  Removes the calling process's `track/2` row for `request_id` in `scope`.
  Another process tracking the same id in the same scope stays in flight.
  Idempotent.
  """
  @spec untrack(request_id() | nil, scope()) :: :ok
  def untrack(request_id, scope) when is_request_id(request_id) do
    ensure_in_flight_table()
    :ets.delete_object(@in_flight_table, {{scope, to_string(request_id)}, self()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def untrack(_request_id, _scope), do: :ok

  @doc """
  Returns `true` when some process has `track/2`ed `request_id` in `scope`
  and not yet untracked it.
  """
  @spec in_flight?(request_id() | nil, scope()) :: boolean()
  def in_flight?(request_id, scope) when is_request_id(request_id) do
    ensure_in_flight_table()
    :ets.member(@in_flight_table, {scope, to_string(request_id)})
  rescue
    ArgumentError -> false
  end

  def in_flight?(_request_id, _scope), do: false

  @doc """
  Removes cancellation entries older than `ttl_ms` milliseconds, and the
  in-flight rows of processes that are no longer alive.

  Returns the number of cancellation entries removed. Emits
  `[:conduit_mcp, :cancellation, :cleanup]` telemetry with measurements
  `%{removed: count, in_flight_removed: count}` so both are observable.
  """
  @spec cleanup(non_neg_integer()) :: non_neg_integer()
  def cleanup(ttl_ms) do
    ensure_table()
    now = System.system_time(:millisecond)

    # Deleting the element just visited during `:ets.foldl/3` is safe on every
    # ETS table type, this `ordered_set` included: `foldl` walks by key, so the
    # next step does not depend on the deleted row. Do NOT "fix" this into
    # collect-then-delete.
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

    in_flight_removed = sweep_dead_in_flight()

    :telemetry.execute(
      [:conduit_mcp, :cancellation, :cleanup],
      %{removed: removed, in_flight_removed: in_flight_removed},
      %{}
    )

    removed
  end

  # `untrack/2` runs in the handler's `after`, which a process killed from
  # outside (an HTTP/2 stream torn down by its connection) never reaches.
  # Same fold-and-delete pattern as `cleanup/1`; `delete_object/2` removes the
  # dead process's row and leaves any other process tracking the same key.
  # `track/2` only ever writes `self()`, so every pid is local and
  # `Process.alive?/1` applies.
  defp sweep_dead_in_flight do
    ensure_in_flight_table()

    :ets.foldl(
      fn {_key, pid} = row, acc ->
        if Process.alive?(pid) do
          acc
        else
          :ets.delete_object(@in_flight_table, row)
          acc + 1
        end
      end,
      0,
      @in_flight_table
    )
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

  # Reclaims space when the global cap is reached by evicting `batch` rows,
  # oldest first within the largest scope, then the next largest, and so on.
  # Ties between equal-sized scopes break on age. A caller holding fewer rows
  # than the largest scopes is therefore evicted only after them — but when
  # every scope holds one row, all scopes tie and eviction is purely by age,
  # so the oldest well-behaved scopes pay too.
  #
  # Cost: one full-table `select`, `frequencies` and sort, O(n log n) with
  # n = `max_rows`. It always frees `batch = max_rows / 20` rows, even when
  # every scope holds a single row, so a lone writer runs at most one scan
  # per `batch` inserts: amortised O(20 log n) per insert at the cap, not
  # O(n). Writers that race past `at_capacity?/0` together take the same
  # snapshot and delete overlapping rows, so k racers pay k scans to free
  # about one batch. The extra work is bounded by the number of concurrent
  # inserts. Not single-flighted with a lock row: it would sit in this table,
  # count toward `at_capacity?/0`, and break the `cleanup/1` fold pattern.
  defp reclaim do
    rows =
      :ets.select(@table, [
        {{{:"$1", :"$2"}, %{"cancelled_at" => :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])

    counts = Enum.frequencies_by(rows, fn {scope, _id, _at} -> scope end)
    batch = max(1, div(max_rows(), 20))

    rows
    |> Enum.map(fn {scope, id, at} -> {-Map.fetch!(counts, scope), at, scope, id} end)
    |> Enum.sort()
    |> Enum.take(batch)
    |> Enum.each(fn {_count, _at, scope, id} -> :ets.delete(@table, {scope, id}) end)
  end

  defp max_rows do
    case Application.get_env(:conduit_mcp, :cancellations_max_rows, @default_max_rows) do
      :infinity -> @default_max_rows
      max when is_integer(max) -> max
    end
  end

  defp truncate_reason(nil), do: nil
  defp truncate_reason(reason), do: Reflect.text(reason, @max_reason_length)

  defp ensure_table, do: ensure(@table, @table_opts)
  defp ensure_in_flight_table, do: ensure(@in_flight_table, @in_flight_table_opts)

  defp ensure(table, opts) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, opts)
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

  defmodule InFlightOwner do
    @moduledoc """
    Long-lived process that owns the `:conduit_mcp_in_flight` ETS table: one
    row per request `ConduitMcp.Handler` is dispatching, written by
    `ConduitMcp.Cancellation.track/2`. Started under `ConduitMcp.Supervisor`
    by `ConduitMcp.Application`, so the table outlives the request processes
    that write to it.
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
        :conduit_mcp_in_flight,
        Cancellation.in_flight_table_opts()
      )
    end
  end
end

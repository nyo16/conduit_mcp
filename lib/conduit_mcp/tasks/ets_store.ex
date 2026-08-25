defmodule ConduitMcp.Tasks.EtsStore do
  @moduledoc """
  ETS-backed task store. Default implementation of `ConduitMcp.Tasks.Store`.

  All state lives in the named ETS table `:conduit_mcp_tasks`. The table
  is owned by a long-lived `Agent` (`#{inspect(__MODULE__)}.Owner`) started
  from `ConduitMcp.Application` so the table outlives short-lived request
  processes — without this, a Bandit request handler that creates the
  table dies with it, and the next request sees an empty table. The
  table is `:public` so any process can read and write; concurrency is
  safe because each task id is the row key and rows are written
  atomically.

  This store is in-memory only. Terminal-state rows accumulate until the
  BEAM restarts; pair it with `ConduitMcp.Tasks.Janitor` to evict them on
  an interval.
  """

  @behaviour ConduitMcp.Tasks.Store

  @table :conduit_mcp_tasks

  # Default cap on the number of rows the table holds. Because `working`
  # and `input_required` rows are never auto-evicted (see `cleanup/1`), an
  # untrusted client looping a task-creating tool could otherwise grow the
  # table without bound. Override with
  # `config :conduit_mcp, :tasks_max_rows, <n>` (`:infinity` disables it).
  @default_max_rows 10_000

  @doc """
  Creates a new task with the given id and metadata. Returns the stored task,
  or `{:error, :task_limit_reached}` when the configured row cap is hit.

  The cap defaults to #{@default_max_rows} rows and is configurable via
  `config :conduit_mcp, :tasks_max_rows`. Terminal-state rows are reclaimed
  by `ConduitMcp.Tasks.Janitor`; `working`/`input_required` rows are not, so
  the cap is the backstop against unbounded growth.
  """
  @impl true
  def create(task_id, metadata \\ %{}) do
    ensure_table()

    if at_capacity?() do
      {:error, :task_limit_reached}
    else
      task =
        Map.merge(metadata, %{
          "task_id" => task_id,
          "status" => "working",
          "created_at" => System.system_time(:millisecond)
        })

      :ets.insert(@table, {task_id, task})
      {:ok, task}
    end
  end

  defp at_capacity? do
    case Application.get_env(:conduit_mcp, :tasks_max_rows, @default_max_rows) do
      :infinity -> false
      max when is_integer(max) -> :ets.info(@table, :size) >= max
    end
  end

  @doc """
  Fetches a task by id.
  """
  @impl true
  def get(task_id) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Merges `updates` into the existing task. Returns the new task or
  `{:error, :not_found}`.
  """
  @impl true
  def update(task_id, updates) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, existing}] ->
        updated = Map.merge(existing, updates)
        :ets.insert(@table, {task_id, updated})
        {:ok, updated}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancels a task by setting status to `"cancelled"`.
  """
  @impl true
  def cancel(task_id) do
    update(task_id, %{"status" => "cancelled"})
  end

  @doc """
  Deletes a task. Returns `:ok` whether or not it existed.
  """
  @impl true
  def delete(task_id) do
    ensure_table()
    :ets.delete(@table, task_id)
    :ok
  end

  @doc """
  Removes terminal-state tasks (`completed`, `failed`, `cancelled`) older
  than `ttl_ms`. Tasks in `working` or `input_required` are never evicted.
  Returns the number of rows removed.
  """
  @impl true
  def cleanup(ttl_ms) do
    ensure_table()
    now = System.system_time(:millisecond)
    terminal_statuses = ~w(completed failed cancelled)

    # Deleting the *current* element during `:ets.foldl` is guaranteed safe by
    # ETS for set tables — do NOT "fix" this into collect-then-delete.
    :ets.foldl(
      fn {task_id, task}, acc ->
        created_at = Map.get(task, "created_at", 0)
        status = Map.get(task, "status", "working")

        if status in terminal_statuses and now - created_at > ttl_ms do
          :ets.delete(@table, task_id)
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  @doc """
  Lists tasks matching `opts`, evaluated as a single `:ets.select/3` match
  spec so filtering happens in the C layer and only matching rows are copied
  into the caller's heap.

  Options:

    * `:owner` — `{:owner, principal}` restricts to rows the principal may
      see. Pass `:any` (the default) for the unscoped listing.
    * `:status` — restrict to one task status.
    * `:limit` — maximum number of rows to return.

  The previous implementation `:ets.foldl`'d the whole table into a list and
  filtered in Elixir, deep-copying up to #{@default_max_rows} task maps per
  `tasks/list` even when the filter matched nothing.
  """
  @impl true
  def list(opts \\ []) do
    ensure_table()

    spec = [{{:_, :"$1"}, guards(opts), [:"$1"]}]

    case Keyword.get(opts, :limit) do
      nil ->
        :ets.select(@table, spec)

      # This module's own convention for "unbounded", used by `:tasks_max_rows`
      # thirteen lines above. Without this clause it fell into the
      # non-positive branch and returned [] for a caller asking for everything.
      :infinity ->
        :ets.select(@table, spec)

      limit when is_integer(limit) and limit > 0 ->
        case :ets.select(@table, spec, limit) do
          {rows, _continuation} -> rows
          :"$end_of_table" -> []
        end

      _non_positive ->
        []
    end
  end

  defp guards(opts) do
    Enum.reject(
      [status_guard(Keyword.get(opts, :status)), owner_guard(Keyword.get(opts, :owner, :any))],
      &is_nil/1
    )
  end

  defp status_guard(nil), do: nil

  defp status_guard(status) do
    # Every `map_get` sits behind an `is_map_key` `andalso` so a row missing
    # the key fails the guard cleanly rather than raising inside the spec.
    {:andalso, {:is_map_key, "status", :"$1"},
     {:==, {:map_get, "status", :"$1"}, to_string(status)}}
  end

  # `:any` is the unscoped listing used by `ConduitMcp.Tasks.list/1`.
  defp owner_guard(:any), do: nil

  # No principal: only rows nobody owns. Previously a `nil` owner matched
  # *everything*, which made authorization default-open.
  defp owner_guard(nil) do
    if require_owner?(), do: {:==, true, false}, else: unowned_guard()
  end

  defp owner_guard(owner) do
    owned = {:andalso, {:is_map_key, "owner", :"$1"}, {:==, {:map_get, "owner", :"$1"}, owner}}

    if require_owner?(), do: owned, else: {:orelse, unowned_guard(), owned}
  end

  defp unowned_guard do
    {:orelse, {:not, {:is_map_key, "owner", :"$1"}},
     {:andalso, {:is_map_key, "owner", :"$1"}, {:==, {:map_get, "owner", :"$1"}, nil}}}
  end

  defp require_owner?, do: Application.get_env(:conduit_mcp, :tasks_require_owner, false)

  @doc false
  # One source of truth for the table's options. Every sibling owner routes
  # both its `ensure_table/0` and its `Owner` through a function like this;
  # tasks kept two literal copies, so a future edit to one (say adding
  # `write_concurrency: :auto`) would give the table different semantics
  # depending on whether the Owner or the fallback created it first.
  @spec table_opts() :: [atom() | tuple()]
  def table_opts, do: [:named_table, :public, :set, read_concurrency: true]

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, table_opts())
    end

    :ok
  rescue
    # Lost a check-then-create race with a concurrent request — the table
    # now exists, which is all we need.
    ArgumentError -> :ok
  end

  defmodule Owner do
    @moduledoc """
    Long-lived process that owns the `:conduit_mcp_tasks` ETS table so
    the table outlives short-lived request handlers. Started under
    `ConduitMcp.Supervisor` by `ConduitMcp.Application` when the
    configured tasks store is the default `ConduitMcp.Tasks.EtsStore`.

    Users with a custom `:tasks_store` don't need this — it isn't
    started in that case.
    """

    # Not a GenServer itself: the process is a `ConduitMcp.EtsOwner`
    # registered under this module's name. This module is the child spec.
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts) do
      ConduitMcp.EtsOwner.start_link(
        __MODULE__,
        :conduit_mcp_tasks,
        ConduitMcp.Tasks.EtsStore.table_opts()
      )
    end
  end
end

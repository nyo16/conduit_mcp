defmodule ConduitMcp.Ext.Tasks.EtsStore do
  @moduledoc """
  In-memory `ConduitMcp.Ext.Tasks.Store` (experimental, unstable — see
  `ConduitMcp.Ext.Tasks`).

  Records live in the `:public` named ETS table `:conduit_mcp_ext_tasks`,
  owned by `#{inspect(__MODULE__)}.Owner` (a `ConduitMcp.EtsOwner`) which
  `ConduitMcp.Application` starts when the extension is enabled with this
  store. Reads and writes go straight to ETS from the calling process.

  Every read-modify-write is a compare-and-swap: `:ets.select_replace/2`
  replaces the row only if it still equals the record the change was
  computed from, and retries otherwise, so a client's `tasks/update` and a
  worker's `complete/2` cannot overwrite each other.

  Single-node only. Rows are evicted by `cleanup/1` (the Ext.Tasks janitor)
  and capped at `:max_rows` (default 10 000) so a client looping a
  task-creating tool cannot grow the table without bound.
  """

  @behaviour ConduitMcp.Ext.Tasks.Store

  alias ConduitMcp.Ext.Tasks

  @table :conduit_mcp_ext_tasks

  @impl true
  def create(%{task_id: task_id} = record, opts) do
    ensure_table()

    cond do
      at_capacity?(Keyword.get(opts, :max_rows, :infinity)) -> {:error, :task_limit_reached}
      :ets.insert_new(@table, {task_id, record}) -> {:ok, record}
      true -> {:error, :duplicate_task_id}
    end
  end

  defp at_capacity?(:infinity), do: false
  defp at_capacity?(max) when is_integer(max), do: :ets.info(@table, :size) >= max

  @impl true
  def get(task_id, owner) when is_binary(task_id) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, record}] -> authorize(record, owner)
      [] -> {:error, :not_found}
    end
  end

  def get(_task_id, _owner), do: {:error, :not_found}

  @impl true
  def update(task_id, owner, fun) when is_function(fun, 1) do
    with {:ok, record} <- get(task_id, owner),
         {:ok, updated} <- fun.(record) do
      if swap(task_id, record, updated), do: {:ok, updated}, else: update(task_id, owner, fun)
    end
  end

  @impl true
  def cancel(task_id, owner) do
    update(task_id, owner, fn record ->
      if Tasks.terminal?(record.status),
        do: {:ok, record},
        else: {:ok, %{record | status: "cancelled", last_updated_at: now()}}
    end)
  end

  @impl true
  def put_status(task_id, status, fields) do
    update(task_id, :any, fn record ->
      if Tasks.terminal?(record.status),
        do: {:error, :terminal},
        else: {:ok, record |> Map.merge(fields) |> Map.put(:status, status)}
    end)
  end

  @doc """
  Evicts expired records (see `c:ConduitMcp.Ext.Tasks.Store.cleanup/1`)
  as of `now` (Unix milliseconds, default the system clock) and returns
  the count.
  """
  @impl true
  @spec cleanup(non_neg_integer(), integer()) :: non_neg_integer()
  def cleanup(default_ttl_ms, now \\ now()) do
    ensure_table()

    # Deleting the current element during `:ets.foldl/3` is safe for set
    # tables.
    :ets.foldl(
      fn {task_id, record}, acc ->
        if expired?(record, default_ttl_ms, now) do
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

  defp expired?(%{ttl_ms: ttl_ms, created_at: created_at}, _default, now)
       when is_integer(ttl_ms),
       do: now - created_at >= ttl_ms

  defp expired?(%{status: status, created_at: created_at}, default, now),
    do: Tasks.terminal?(status) and now - created_at >= default

  defp authorize(record, :any), do: {:ok, record}
  defp authorize(%{owner: owner} = record, caller) when owner === caller, do: {:ok, record}
  defp authorize(_record, _caller), do: {:error, :not_found}

  # Replaces the row only while it still holds exactly `old` (`=:=`, a deep
  # term comparison; a map *pattern* would also match supersets).
  defp swap(task_id, old, new) do
    spec = [
      {{:"$1", :"$2"}, [{:"=:=", :"$1", {:const, task_id}}, {:"=:=", :"$2", {:const, old}}],
       [{{:"$1", {:const, new}}}]}
    ]

    :ets.select_replace(@table, spec) == 1
  end

  defp now, do: System.system_time(:millisecond)

  @doc false
  @spec table_opts() :: [atom() | tuple()]
  def table_opts, do: [:named_table, :public, :set, read_concurrency: true]

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, table_opts())
    end

    :ok
  rescue
    # Lost a check-then-create race; the table exists now.
    ArgumentError -> :ok
  end

  defmodule Owner do
    @moduledoc """
    Long-lived `ConduitMcp.EtsOwner` process owning `:conduit_mcp_ext_tasks`.
    Started by `ConduitMcp.Application` when `:ext_tasks` is enabled with
    the default `ConduitMcp.Ext.Tasks.EtsStore`.
    """

    @doc false
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    @doc false
    def start_link(_opts) do
      ConduitMcp.EtsOwner.start_link(
        __MODULE__,
        :conduit_mcp_ext_tasks,
        ConduitMcp.Ext.Tasks.EtsStore.table_opts()
      )
    end
  end
end

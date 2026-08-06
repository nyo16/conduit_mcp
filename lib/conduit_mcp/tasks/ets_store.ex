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
  Lists all tasks, optionally filtered by `:status`.
  """
  @impl true
  def list(opts \\ []) do
    ensure_table()
    status_filter = Keyword.get(opts, :status)

    tasks = :ets.foldl(fn {_id, task}, acc -> [task | acc] end, [], @table)

    if status_filter do
      Enum.filter(tasks, fn task -> task["status"] == to_string(status_filter) end)
    else
      tasks
    end
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
    Long-lived process that owns the `:conduit_mcp_tasks` ETS table so
    the table outlives short-lived request handlers. Started under
    `ConduitMcp.Supervisor` by `ConduitMcp.Application` when the
    configured tasks store is the default `ConduitMcp.Tasks.EtsStore`.

    Users with a custom `:tasks_store` don't need this — it isn't
    started in that case.
    """

    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          :ets.new(:conduit_mcp_tasks, [
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

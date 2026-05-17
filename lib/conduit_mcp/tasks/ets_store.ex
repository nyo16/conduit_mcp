defmodule ConduitMcp.Tasks.EtsStore do
  @moduledoc """
  ETS-backed task store. Default implementation used by `ConduitMcp.Tasks`.

  All state lives in the named ETS table `:conduit_mcp_tasks`, which is
  created lazily on first call. The table is `:public` so any process can
  read and write — concurrency is safe because each task id is the row key
  and rows are written atomically.

  This store is in-memory only. Terminal-state rows accumulate until the
  BEAM restarts; pair it with `ConduitMcp.Tasks.Janitor` to evict them on
  an interval.
  """

  @table :conduit_mcp_tasks

  @doc """
  Creates a new task with the given id and metadata. Returns the stored task.
  """
  def create(task_id, metadata \\ %{}) do
    ensure_table()

    task =
      Map.merge(metadata, %{
        "task_id" => task_id,
        "status" => "working",
        "created_at" => System.system_time(:millisecond)
      })

    :ets.insert(@table, {task_id, task})
    {:ok, task}
  end

  @doc """
  Fetches a task by id.
  """
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
  def cancel(task_id) do
    update(task_id, %{"status" => "cancelled"})
  end

  @doc """
  Deletes a task. Returns `:ok` whether or not it existed.
  """
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
  def cleanup(ttl_ms) do
    ensure_table()
    now = System.system_time(:millisecond)
    terminal_statuses = ~w(completed failed cancelled)

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
  end
end

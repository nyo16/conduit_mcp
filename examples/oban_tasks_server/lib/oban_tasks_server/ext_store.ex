defmodule Examples.ObanTasks.ExtStore do
  @moduledoc """
  `ConduitMcp.Ext.Tasks.Store` backed by SQLite — the durable store for the
  modern (`2026-07-28`) tasks extension path of this example.

  Each task is one `ext_tasks` row: the owner and status as columns, the
  whole `ConduitMcp.Ext.Tasks` record as an Erlang term (written only by this
  server, read back with `:safe`), and a `version` counter. Every
  read-modify-write is a compare-and-swap on `version`
  (`UPDATE ... WHERE task_id = ? AND version = ?`), retried when another
  writer got there first — so a client's `tasks/update` cannot overwrite the
  worker's `completed` (see "Atomicity" in `ConduitMcp.Ext.Tasks.Store`).

  There is no `list`: the extension has no `tasks/list`, and task ids are
  bearer tokens.
  """

  @behaviour ConduitMcp.Ext.Tasks.Store

  # Only `from/2`: `Ecto.Query.update/3` would shadow this module's update/3.
  import Ecto.Query, only: [from: 2]

  alias ConduitMcp.Ext.Tasks
  alias Examples.ObanTasks.Repo

  @table "ext_tasks"

  @impl true
  def create(%{task_id: task_id} = task, opts) do
    if at_capacity?(Keyword.get(opts, :max_rows, :infinity)) do
      {:error, :task_limit_reached}
    else
      {1, _} =
        Repo.insert_all(@table, [
          %{
            task_id: task_id,
            owner: task.owner,
            status: task.status,
            created_at: task.created_at,
            version: 0,
            record: encode(task)
          }
        ])

      {:ok, task}
    end
  end

  defp at_capacity?(:infinity), do: false

  defp at_capacity?(max),
    do: Repo.one(from(t in @table, select: count(t.task_id))) >= max

  @impl true
  def get(task_id, owner) do
    case fetch(task_id) do
      {:ok, _version, task} -> authorize(task, owner)
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def update(task_id, owner, fun) do
    with {:ok, version, task} <- fetch(task_id),
         {:ok, task} <- authorize(task, owner),
         {:ok, updated} <- fun.(task) do
      if swap(task_id, version, updated), do: {:ok, updated}, else: update(task_id, owner, fun)
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  @impl true
  def cancel(task_id, owner) do
    update(task_id, owner, fn task ->
      if Tasks.terminal?(task.status),
        do: {:ok, task},
        else: {:ok, %{task | status: "cancelled", last_updated_at: now()}}
    end)
  end

  @impl true
  def put_status(task_id, status, fields) do
    update(task_id, :any, fn task ->
      if Tasks.terminal?(task.status),
        do: {:error, :terminal},
        else: {:ok, task |> Map.merge(fields) |> Map.put(:status, status)}
    end)
  end

  @impl true
  def cleanup(default_ttl_ms) do
    now = now()

    expired =
      for {task_id, record} <- Repo.all(from(t in @table, select: {t.task_id, t.record})),
          expired?(decode(record), default_ttl_ms, now),
          do: task_id

    {count, _} = Repo.delete_all(from(t in @table, where: t.task_id in ^expired))
    count
  end

  defp expired?(%{ttl_ms: ttl_ms, created_at: created_at}, _default, now)
       when is_integer(ttl_ms),
       do: now - created_at >= ttl_ms

  defp expired?(%{status: status, created_at: created_at}, default, now),
    do: Tasks.terminal?(status) and now - created_at >= default

  defp fetch(task_id) when is_binary(task_id) do
    query = from(t in @table, where: t.task_id == ^task_id, select: {t.version, t.record})

    case Repo.one(query) do
      {version, record} -> {:ok, version, decode(record)}
      nil -> :error
    end
  end

  defp fetch(_task_id), do: :error

  defp swap(task_id, version, task) do
    query = from(t in @table, where: t.task_id == ^task_id and t.version == ^version)

    {count, _} =
      Repo.update_all(query,
        set: [status: task.status, version: version + 1, record: encode(task)]
      )

    count == 1
  end

  defp authorize(task, :any), do: {:ok, task}
  defp authorize(%{owner: owner} = task, caller) when owner === caller, do: {:ok, task}
  defp authorize(_task, _caller), do: {:error, :not_found}

  defp encode(task), do: :erlang.term_to_binary(task)
  defp decode(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp now, do: System.system_time(:millisecond)
end

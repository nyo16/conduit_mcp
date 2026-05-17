defmodule Examples.ObanTasks.Store do
  @moduledoc """
  `ConduitMcp.Tasks.Store` implementation backed by SQLite + Oban.

  ## How it plays with the rest of the system

  The standard `tasks/get`, `tasks/cancel`, `tasks/result`, and
  `tasks/list` JSON-RPC routes in `ConduitMcp.Handler` go through
  `ConduitMcp.Tasks`, which dispatches to whichever module is
  configured at `:tasks_store`. Wiring this module via
  `config :conduit_mcp, :tasks_store, Examples.ObanTasks.Store` is the
  only thing needed to flip the library from in-memory ETS to durable
  SQLite — no handler changes.

  ## Cancel semantics

  `cancel/1` is overridden (vs the framework's default
  `update(_, %{"status" => "cancelled"})`) because tasks here are
  backed by Oban jobs — we want to mark the row cancelled *and* tell
  Oban to drop the job from its queue so it doesn't keep retrying.
  """

  @behaviour ConduitMcp.Tasks.Store

  import Ecto.Query

  alias Examples.ObanTasks.Repo
  alias Examples.ObanTasks.Schema.McpTask

  @impl true
  def create(task_id, metadata \\ %{}) do
    attrs = %{
      task_id: task_id,
      status: "working",
      created_at: System.system_time(:millisecond),
      tool: metadata["tool"],
      args: metadata["args"],
      metadata: Map.drop(metadata, ["tool", "args"]) |> nilify_if_empty(),
      oban_job_id: metadata["oban_job_id"]
    }

    %McpTask{}
    |> McpTask.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, McpTask.to_map(row)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def get(task_id) do
    case Repo.get(McpTask, task_id) do
      nil -> {:error, :not_found}
      row -> {:ok, McpTask.to_map(row)}
    end
  end

  @impl true
  def update(task_id, updates) do
    case Repo.get(McpTask, task_id) do
      nil ->
        {:error, :not_found}

      row ->
        attrs = normalize_updates(row, updates)

        row
        |> McpTask.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, McpTask.to_map(updated)}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @impl true
  def cancel(task_id) do
    case Repo.get(McpTask, task_id) do
      nil ->
        {:error, :not_found}

      %McpTask{oban_job_id: job_id} = row ->
        if job_id, do: cancel_oban_job(job_id)

        row
        |> McpTask.changeset(%{status: "cancelled"})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, McpTask.to_map(updated)}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @impl true
  def delete(task_id) do
    from(t in McpTask, where: t.task_id == ^task_id) |> Repo.delete_all()
    :ok
  end

  @impl true
  def list(opts \\ []) do
    query = from(t in McpTask, order_by: [desc: t.created_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(t in query, where: t.status == ^to_string(status))
      end

    query
    |> Repo.all()
    |> Enum.map(&McpTask.to_map/1)
  end

  @impl true
  def cleanup(ttl_ms) do
    cutoff = System.system_time(:millisecond) - ttl_ms
    terminal = ~w(completed failed cancelled)

    {removed, _} =
      from(t in McpTask,
        where: t.status in ^terminal and t.created_at < ^cutoff
      )
      |> Repo.delete_all()

    removed
  end

  # --- helpers ---

  defp normalize_updates(%McpTask{metadata: existing_meta}, updates) do
    updates
    |> Enum.reduce(%{}, fn
      {"status", v}, acc ->
        Map.put(acc, :status, v)

      {"oban_job_id", v}, acc ->
        Map.put(acc, :oban_job_id, v)

      {"tool", v}, acc ->
        Map.put(acc, :tool, v)

      {"args", v}, acc ->
        Map.put(acc, :args, v)

      {"result", v}, acc ->
        Map.put(acc, :result, v)

      {"metadata", v}, acc ->
        Map.put(acc, :metadata, merge_meta(existing_meta, v))

      # Anything else (e.g., progress, custom worker keys) lives under
      # the metadata blob so the schema stays narrow.
      {k, v}, acc when is_binary(k) ->
        Map.update(acc, :metadata, merge_meta(existing_meta, %{k => v}), fn meta ->
          Map.merge(meta || existing_meta || %{}, %{k => v})
        end)
    end)
  end

  defp merge_meta(nil, new) when is_map(new), do: new

  defp merge_meta(existing, new) when is_map(existing) and is_map(new),
    do: Map.merge(existing, new)

  defp merge_meta(_, new), do: new

  defp nilify_if_empty(map) when map == %{}, do: nil
  defp nilify_if_empty(map), do: map

  defp cancel_oban_job(job_id) do
    # Oban.cancel_job/1 is a no-op for jobs not currently in queue/exec.
    # Wrap in a tolerant call so a stale job id doesn't blow up cancel/1.
    try do
      Oban.cancel_job(job_id)
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule ConduitMcp.Tasks do
  @moduledoc """
  Task management for long-running MCP operations (experimental).

  Tasks provide a durable state machine for operations that may take time to complete.
  Clients can poll for status, cancel in-flight operations, and receive results
  asynchronously.

  ## Task Lifecycle

      working → completed
      working → failed
      working → cancelled
      working → input_required → working (after elicitation)

  ## Usage

  Tasks are stored in a pluggable store (defaults to ETS via `ConduitMcp.Session.EtsStore`
  pattern). The task registry is managed per-server.

  ## Configuration

  Enable tasks in your transport config:

      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        tasks: [enabled: true]}
  """

  @type task_id :: String.t()
  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @valid_statuses ~w(working input_required completed failed cancelled)a

  @doc """
  Generates a unique task ID.
  """
  def generate_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc """
  Creates a new task in the ETS store.
  """
  def create(task_id, metadata \\ %{}) do
    ensure_table()

    task =
      Map.merge(metadata, %{
        "task_id" => task_id,
        "status" => "working",
        "created_at" => System.system_time(:millisecond)
      })

    :ets.insert(:conduit_mcp_tasks, {task_id, task})
    {:ok, task}
  end

  @doc """
  Gets a task by ID.
  """
  def get(task_id) do
    ensure_table()

    case :ets.lookup(:conduit_mcp_tasks, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Updates a task's status and/or metadata.
  """
  def update(task_id, updates) do
    ensure_table()

    case :ets.lookup(:conduit_mcp_tasks, task_id) do
      [{^task_id, existing}] ->
        updated = Map.merge(existing, updates)
        :ets.insert(:conduit_mcp_tasks, {task_id, updated})
        {:ok, updated}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancels a task.
  """
  def cancel(task_id) do
    update(task_id, %{"status" => "cancelled"})
  end

  @doc """
  Lists all tasks, optionally filtered by status.
  """
  def list(opts \\ []) do
    ensure_table()
    status_filter = Keyword.get(opts, :status)

    tasks =
      :ets.foldl(
        fn {_id, task}, acc -> [task | acc] end,
        [],
        :conduit_mcp_tasks
      )

    if status_filter do
      Enum.filter(tasks, fn task -> task["status"] == to_string(status_filter) end)
    else
      tasks
    end
  end

  @doc """
  Validates that a status transition is allowed.
  """
  def valid_transition?(from, to) do
    case {String.to_existing_atom(from), String.to_existing_atom(to)} do
      {:working, :completed} -> true
      {:working, :failed} -> true
      {:working, :cancelled} -> true
      {:working, :input_required} -> true
      {:input_required, :working} -> true
      {:input_required, :cancelled} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Returns the list of valid task statuses."
  def valid_statuses, do: @valid_statuses

  defp ensure_table do
    if :ets.whereis(:conduit_mcp_tasks) == :undefined do
      :ets.new(:conduit_mcp_tasks, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end
end

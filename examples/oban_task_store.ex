# Oban-backed MCP task store for multi-node deployments.
#
# Postgres-flavored reference implementation of `ConduitMcp.Tasks.Store`.
# Wire it in via `config :conduit_mcp, :tasks_store, MyApp.ObanTaskStore`
# and the standard tasks/* JSON-RPC routes start writing here.
#
# For a runnable, single-node SQLite variant of the same shape see
# `examples/oban_tasks_server/` — same `@behaviour` but its own mix
# project so you can boot it directly.
#
# Uses Oban jobs as the backing store for MCP Tasks. This gives you:
# - PostgreSQL persistence across all nodes
# - Built-in retries and error handling
# - Job uniqueness (prevent duplicate tasks)
# - Oban Pro workflows for chained tasks
# - Observable via Oban Web dashboard
#
# Requires: {:oban, "~> 2.18"} in your deps
#
# Migration: Oban's standard migration (mix oban.install)
#
# Additional migration for MCP task metadata:
#
#     defmodule MyApp.Repo.Migrations.CreateMcpTasks do
#       use Ecto.Migration
#
#       def change do
#         create table(:mcp_tasks, primary_key: false) do
#           add :task_id, :string, primary_key: true
#           add :oban_job_id, :integer
#           add :status, :string, default: "working"
#           add :method, :string
#           add :result, :map
#           add :metadata, :map, default: %{}
#           timestamps()
#         end
#
#         create index(:mcp_tasks, [:status])
#         create index(:mcp_tasks, [:oban_job_id])
#       end
#     end
#
# ## How it maps
#
# MCP Task Status  → Oban Job State
# ─────────────────────────────────
# working          → executing / available
# input_required   → (custom state in mcp_tasks table)
# completed        → completed
# failed           → discarded
# cancelled        → cancelled
#
# ## Usage
#
#     # In your MCP server tool handler
#     tool "long_analysis", "Runs a long analysis" do
#       scope "analysis:run"
#       param :dataset, :string, "Dataset ID", required: true
#
#       handle fn conn, %{"dataset" => dataset_id} ->
#         # Create an Oban job for the long-running work
#         task_id = ConduitMcp.Tasks.generate_id()
#
#         %{task_id: task_id, dataset_id: dataset_id}
#         |> MyApp.AnalysisWorker.new()
#         |> Oban.insert!()
#
#         # Return immediately with task reference
#         {:ok, %{
#           "content" => [%{"type" => "text", "text" => "Analysis started"}],
#           "_meta" => %{"taskId" => task_id, "status" => "working"}
#         }}
#       end
#     end
#

# Schema for tracking MCP task ↔ Oban job mapping
defmodule MyApp.McpTask do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:task_id, :string, autogenerate: false}
  schema "mcp_tasks" do
    field(:oban_job_id, :integer)
    field(:status, :string, default: "working")
    field(:method, :string)
    field(:result, :map)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:task_id, :oban_job_id, :status, :method, :result, :metadata])
    |> validate_required([:task_id])
    |> validate_inclusion(:status, ~w(working input_required completed failed cancelled))
  end
end

# Oban worker that executes the long-running MCP task
defmodule MyApp.McpTaskWorker do
  use Oban.Worker,
    queue: :mcp_tasks,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:task_id]]

  @repo MyApp.Repo

  # Allowlist mapping the client-supplied "handler" string to a known module
  # with an `execute/1`. NEVER resolve a client string to a module via
  # `String.to_existing_atom/1` + `apply/3` — that lets a client invoke any
  # loaded module. Map names you control to modules you control.
  @handlers %{
    "analysis" => MyApp.AnalysisHandler
    # "report" => MyApp.ReportHandler,
  }

  @impl Oban.Worker
  def perform(%Oban.Job{
        attempt: attempt,
        max_attempts: max_attempts,
        args: %{"task_id" => task_id, "handler" => handler} = args
      }) do
    # Update task status to working
    update_task_status(task_id, "working")

    # Dispatch to the actual handler
    case execute_handler(handler, args) do
      {:ok, result} ->
        update_task(task_id, %{status: "completed", result: result})
        :ok

      {:error, reason} ->
        # Only write "failed" on the final attempt. On earlier attempts leave
        # the row "working" and let Oban retry silently, so the client doesn't
        # see the status flicker working → failed → working → failed.
        if attempt >= max_attempts do
          update_task(task_id, %{status: "failed", result: %{"error" => inspect(reason)}})
        end

        {:error, reason}

      {:input_required, schema} ->
        update_task(task_id, %{status: "input_required", metadata: %{"schema" => schema}})
        # Snooze for 5 min, retry after elicitation
        {:snooze, 300}
    end
  end

  defp execute_handler(handler, args) when is_binary(handler) do
    case Map.fetch(@handlers, handler) do
      {:ok, module} -> module.execute(args)
      :error -> {:error, "unknown handler: #{handler}"}
    end
  end

  defp update_task_status(task_id, status) do
    update_task(task_id, %{status: status})
  end

  defp update_task(task_id, updates) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil ->
        :ok

      task ->
        MyApp.McpTask.changeset(task, updates)
        |> @repo.update()
    end
  end
end

# MCP Task store backed by the mcp_tasks table + Oban
defmodule MyApp.ObanTaskStore do
  @behaviour ConduitMcp.Tasks.Store

  import Ecto.Query

  @repo MyApp.Repo

  @doc """
  Creates a new MCP task and optionally enqueues an Oban job.

  When the caller stamps an owner via `ConduitMcp.Tasks.create/3`, it arrives
  under `metadata["owner"]` and is persisted verbatim in the `metadata` column.
  `to_map/1` promotes it back to the top-level `"owner"` key so the framework's
  owner-scoping (`get/2`, `cancel/2`, `list/2`) can enforce it — see the "Owner
  scoping" section of `ConduitMcp.Tasks.Store`. For heavy multi-tenant use,
  prefer a dedicated indexed `owner` column over the JSON blob.
  """
  @impl true
  def create(task_id, metadata \\ %{}) do
    attrs = %{
      task_id: task_id,
      status: "working",
      method: Map.get(metadata, "method"),
      metadata: metadata
    }

    case @repo.insert(MyApp.McpTask.changeset(%MyApp.McpTask{}, attrs)) do
      {:ok, task} -> {:ok, to_map(task)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Creates a task and enqueues an Oban job for it, atomically.

  The task insert, job insert, and `oban_job_id` back-link all commit in a
  single transaction (`Ecto.Multi` + `Oban.insert/2`). A crash mid-sequence
  rolls everything back — no orphaned task row and no job left unlinked
  (which would make `cancel/1` unable to reach `Oban.cancel_job/1`).
  """
  def create_with_job(task_id, worker_args, opts \\ []) do
    metadata = Map.get(worker_args, :metadata, %{})
    job_args = Map.put(worker_args, :task_id, task_id)
    worker = Keyword.get(opts, :worker, MyApp.McpTaskWorker)

    task_changeset =
      MyApp.McpTask.changeset(%MyApp.McpTask{}, %{
        task_id: task_id,
        status: "working",
        method: Map.get(metadata, "method"),
        metadata: metadata
      })

    # NOTE: `Oban.insert/2` participates in this transaction only when Oban's
    # configured repo is the same repo that runs `@repo.transaction/1` below.
    # They match here (both MyApp.Repo); if you split them, the job insert
    # would commit outside the transaction and break atomicity.
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:task, task_changeset)
    |> Oban.insert(:job, worker.new(job_args))
    |> Ecto.Multi.update(:link, fn %{task: task, job: job} ->
      MyApp.McpTask.changeset(task, %{oban_job_id: job.id})
    end)
    |> @repo.transaction()
    |> case do
      {:ok, %{link: task}} -> {:ok, to_map(task)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @impl true
  def get(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, to_map(task)}
    end
  end

  @impl true
  def update(task_id, updates) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        case @repo.update(MyApp.McpTask.changeset(task, updates)) do
          {:ok, updated} -> {:ok, to_map(updated)}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @impl true
  def cancel(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        # Cancel the Oban job if it exists. Don't crash on a non-:ok return
        # (e.g. the job already finished) — log and proceed to mark the row.
        with id when not is_nil(id) <- task.oban_job_id,
             {:error, reason} <- Oban.cancel_job(id) do
          require Logger
          Logger.warning("Oban.cancel_job(#{id}) failed: #{inspect(reason)}")
        end

        update(task_id, %{status: "cancelled"})
    end
  end

  @impl true
  def delete(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil ->
        :ok

      task ->
        case @repo.delete(task) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            require Logger
            Logger.warning("delete of task #{task_id} failed: #{inspect(reason)}")
            :ok
        end
    end
  end

  @impl true
  def list(opts \\ []) do
    query = from(t in MyApp.McpTask, order_by: [desc: t.inserted_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(t in query, where: t.status == ^to_string(status))
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> from(t in query, limit: ^limit)
      end

    @repo.all(query) |> Enum.map(&to_map/1)
  end

  defp to_map(%MyApp.McpTask{} = task) do
    %{
      "task_id" => task.task_id,
      "status" => task.status,
      "method" => task.method,
      "result" => task.result,
      "metadata" => task.metadata,
      "created_at" => task.inserted_at
    }
    |> promote_owner(task.metadata)
  end

  # Surface the stamped owner at the top level so ConduitMcp.Tasks owner-scoping
  # can read it. No-op for unowned tasks (back-compat).
  defp promote_owner(map, %{"owner" => owner}) when not is_nil(owner),
    do: Map.put(map, "owner", owner)

  defp promote_owner(map, _metadata), do: map
end

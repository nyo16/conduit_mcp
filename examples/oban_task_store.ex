# Oban-backed MCP task store for multi-node deployments.
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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id, "handler" => handler} = args}) do
    # Update task status to working
    update_task_status(task_id, "working")

    # Dispatch to the actual handler
    case execute_handler(handler, args) do
      {:ok, result} ->
        update_task(task_id, %{status: "completed", result: result})
        :ok

      {:error, reason} ->
        update_task(task_id, %{status: "failed", result: %{"error" => inspect(reason)}})
        {:error, reason}

      {:input_required, schema} ->
        update_task(task_id, %{status: "input_required", metadata: %{"schema" => schema}})
        # Snooze for 5 min, retry after elicitation
        {:snooze, 300}
    end
  end

  defp execute_handler(handler, args) when is_binary(handler) do
    module = String.to_existing_atom("Elixir." <> handler)
    apply(module, :execute, [args])
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
  import Ecto.Query

  @repo MyApp.Repo

  @doc """
  Creates a new MCP task and optionally enqueues an Oban job.
  """
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
  Creates a task and enqueues an Oban job for it.
  """
  def create_with_job(task_id, worker_args, opts \\ []) do
    with {:ok, task} <- create(task_id, Map.get(worker_args, :metadata, %{})) do
      job_args = Map.put(worker_args, :task_id, task_id)
      worker = Keyword.get(opts, :worker, MyApp.McpTaskWorker)

      case worker.new(job_args) |> Oban.insert() do
        {:ok, job} ->
          @repo.update(
            MyApp.McpTask.changeset(
              @repo.get!(MyApp.McpTask, task_id),
              %{oban_job_id: job.id}
            )
          )

          {:ok, task}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, to_map(task)}
    end
  end

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

  def cancel(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        # Cancel the Oban job if it exists
        if task.oban_job_id do
          Oban.cancel_job(task.oban_job_id)
        end

        update(task_id, %{status: "cancelled"})
    end
  end

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
  end
end

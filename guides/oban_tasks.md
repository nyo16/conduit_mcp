# Using Oban for MCP Tasks

[Oban](https://hexdocs.pm/oban) is a natural fit for MCP's Tasks protocol. Oban job states
map directly to MCP task statuses, PostgreSQL persistence works across nodes, and
Oban Pro workflows enable chained task execution.

ConduitMCP makes the storage layer pluggable via the
`ConduitMcp.Tasks.Store` behaviour — flip the framework from its
default in-memory ETS store to an Oban-backed store with one config line:

```elixir
config :conduit_mcp, :tasks_store, MyApp.ObanTaskStore
```

The standard `tasks/get`, `tasks/cancel`, `tasks/result`, and
`tasks/list` JSON-RPC routes dispatch through the configured store
without any handler changes.

> **Runnable examples**
>
> - SQLite (single-node, dependency-light): [`examples/oban_tasks_server/`](https://github.com/nyo16/conduit_mcp/tree/master/examples/oban_tasks_server) — full mix project; `cd` in and `iex -S mix`.
> - Postgres (multi-node, production shape): [`examples/oban_task_store.ex`](https://github.com/nyo16/conduit_mcp/blob/master/examples/oban_task_store.ex) — drop-in reference.

## Status Mapping

| MCP Task Status | Oban Job State |
|-----------------|----------------|
| `working` | `executing` / `available` |
| `input_required` | `{:snooze, seconds}` |
| `completed` | `completed` |
| `failed` | `discarded` |
| `cancelled` | `cancelled` |

## Setup

Add to your deps:

```elixir
{:oban, "~> 2.18"}
```

### Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateMcpTasks do
  use Ecto.Migration

  def change do
    create table(:mcp_tasks, primary_key: false) do
      add :task_id, :string, primary_key: true
      add :oban_job_id, :integer
      add :status, :string, default: "working"
      add :method, :string
      add :result, :map
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:mcp_tasks, [:status])
    create index(:mcp_tasks, [:oban_job_id])
  end
end
```

### Schema

```elixir
defmodule MyApp.McpTask do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:task_id, :string, autogenerate: false}
  schema "mcp_tasks" do
    field :oban_job_id, :integer
    field :status, :string, default: "working"
    field :method, :string
    field :result, :map
    field :metadata, :map, default: %{}
    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:task_id, :oban_job_id, :status, :method, :result, :metadata])
    |> validate_required([:task_id])
    |> validate_inclusion(:status, ~w(working input_required completed failed cancelled))
  end
end
```

### Worker

```elixir
defmodule MyApp.McpTaskWorker do
  use Oban.Worker,
    queue: :mcp_tasks,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:task_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id} = args}) do
    update_status(task_id, "working")

    case execute(args) do
      {:ok, result} ->
        update_task(task_id, %{status: "completed", result: result})
        :ok

      {:error, reason} ->
        update_task(task_id, %{status: "failed", result: %{"error" => inspect(reason)}})
        {:error, reason}

      {:input_required, schema} ->
        update_task(task_id, %{
          status: "input_required",
          metadata: %{"schema" => schema}
        })
        {:snooze, 300}  # Snooze 5 min, retry after user provides input
    end
  end

  defp execute(%{"handler" => handler} = args) do
    module = String.to_existing_atom("Elixir." <> handler)
    apply(module, :execute, [args])
  end

  defp update_status(task_id, status), do: update_task(task_id, %{status: status})

  defp update_task(task_id, updates) do
    case MyApp.Repo.get(MyApp.McpTask, task_id) do
      nil -> :ok
      task -> MyApp.Repo.update(MyApp.McpTask.changeset(task, updates))
    end
  end
end
```

### Task Store

A `ConduitMcp.Tasks.Store` implementation. The framework dispatches every
`tasks/*` route through this module once configured.

```elixir
defmodule MyApp.ObanTaskStore do
  @behaviour ConduitMcp.Tasks.Store

  import Ecto.Query
  @repo MyApp.Repo

  def create_with_job(task_id, worker_args, opts \\ []) do
    # Create the task record
    attrs = %{task_id: task_id, status: "working", method: worker_args["method"]}
    {:ok, _task} = @repo.insert(MyApp.McpTask.changeset(%MyApp.McpTask{}, attrs))

    # Enqueue the Oban job
    job_args = Map.put(worker_args, "task_id", task_id)
    worker = Keyword.get(opts, :worker, MyApp.McpTaskWorker)
    {:ok, job} = worker.new(job_args) |> Oban.insert()

    # Link task to job
    @repo.get!(MyApp.McpTask, task_id)
    |> MyApp.McpTask.changeset(%{oban_job_id: job.id})
    |> @repo.update()

    {:ok, %{"task_id" => task_id, "status" => "working"}}
  end

  def get(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, to_map(task)}
    end
  end

  def cancel(task_id) do
    case @repo.get(MyApp.McpTask, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        if task.oban_job_id, do: Oban.cancel_job(task.oban_job_id)
        @repo.update(MyApp.McpTask.changeset(task, %{status: "cancelled"}))
        :ok
    end
  end

  def list(opts \\ []) do
    query = from(t in MyApp.McpTask, order_by: [desc: t.inserted_at])
    query = if s = opts[:status], do: where(query, [t], t.status == ^s), else: query
    query = if l = opts[:limit], do: limit(query, ^l), else: query
    @repo.all(query) |> Enum.map(&to_map/1)
  end

  defp to_map(task) do
    %{
      "task_id" => task.task_id,
      "status" => task.status,
      "result" => task.result,
      "metadata" => task.metadata,
      "created_at" => task.inserted_at
    }
  end
end
```

## Usage in MCP Server

Register the store once in config:

```elixir
# config/config.exs
config :conduit_mcp, :tasks_store, MyApp.ObanTaskStore
```

Then write tools that use the standard `ConduitMcp.Tasks` API and the
`task/2` helper — the storage layer is transparent:

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  tool "analyze_dataset", "Run long-running analysis" do
    task_support :supported
    scope "analysis:run"
    param :dataset_id, :string, "Dataset ID", required: true

    handle fn _conn, %{"dataset_id" => dataset_id} ->
      task_id = ConduitMcp.Tasks.generate_id()

      {:ok, _} = MyApp.ObanTaskStore.create_with_job(task_id, %{
        "handler" => "MyApp.DatasetAnalyzer",
        "dataset_id" => dataset_id
      })

      # Returns {:ok, %{"content" => [...], "_meta" => %{"task" => %{"id" => task_id}}}}.
      # Clients see the task id in the spec-compliant _meta.task.id shape.
      task(task_id, "Analysis started")
    end
  end
end
```

## Why Oban?

- **Multi-node**: All nodes share the PostgreSQL-backed job queue
- **Retries**: Failed tasks retry automatically (configurable)
- **Uniqueness**: Prevent duplicate tasks with `unique` option
- **Observability**: Oban Web dashboard shows task status in real-time
- **Cancellation**: `Oban.cancel_job/1` maps directly to MCP task cancellation
- **Snooze**: `{:snooze, seconds}` handles `input_required` → wait for user input → resume
- **Oban Pro Workflows**: Chain dependent tasks (e.g., fetch → transform → analyze)

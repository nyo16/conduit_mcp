# Using Oban for MCP Tasks

[Oban](https://hexdocs.pm/oban) is a natural fit for MCP tasks. Job states map onto task
statuses, PostgreSQL persistence works across nodes, and Oban Pro workflows enable chained
task execution.

ConduitMCP has two task implementations, one per protocol era:

| Era | Module | Status |
|---|---|---|
| Modern (`2026-07-28`) | `ConduitMcp.Ext.Tasks`, the `io.modelcontextprotocol/tasks` extension | experimental |
| Legacy (`2025-11-25`) | `ConduitMcp.Tasks` | frozen: no new features; goes away with the legacy era |

New code should target the [modern path](#modern-era-the-tasks-extension). The
[legacy section](#legacy-era-conduitmcp-tasks-frozen) documents the frozen store for servers
that still serve `2025-11-25` clients. A server serving both eras keeps both.

> **Runnable examples**
>
> - SQLite (single-node, dependency-light, both eras): [`examples/oban_tasks_server/`](https://github.com/nyo16/conduit_mcp/tree/master/examples/oban_tasks_server) — full mix project; `cd` in and `iex -S mix`. `Examples.ObanTasks.ExtStore` is a modern `ConduitMcp.Ext.Tasks.Store`.
> - Postgres (multi-node, production shape, legacy store): [`examples/oban_task_store.ex`](https://github.com/nyo16/conduit_mcp/blob/master/examples/oban_task_store.ex) — drop-in reference.

## Modern era: the tasks extension

Enable the extension and, for durability across nodes, point it at your own
`ConduitMcp.Ext.Tasks.Store` (see [Tasks Extension](tasks_extension.md#storage)):

```elixir
config :conduit_mcp, :ext_tasks, store: MyApp.ExtTaskStore
```

### The tool

The tool returns `{:task, attrs}`. The library stores the task first, then calls `:start`
with its id; enqueue the job there. The job can never see a missing task.

```elixir
tool "analyze_dataset", "Run a long-running analysis" do
  param :dataset_id, :string, "Dataset ID", required: true

  handle fn _conn, %{"dataset_id" => dataset_id} ->
    {:task,
     ttl_ms: :timer.hours(1),
     poll_interval_ms: 2_000,
     status_message: "Queued",
     start: fn task_id ->
       {:ok, _job} =
         %{"task_id" => task_id, "dataset_id" => dataset_id}
         |> MyApp.AnalysisWorker.new()
         |> Oban.insert()
     end}
  end
end
```

The client must declare `io.modelcontextprotocol/tasks` in the request's client capabilities,
otherwise it gets `-32021`. It then polls `tasks/get`, sending `Mcp-Name: <taskId>`, or
listens for changes (see [Status notifications](#status-notifications)).

### The worker

The worker reports through `ConduitMcp.Ext.Tasks`, addressing the task by id:

```elixir
defmodule MyApp.AnalysisWorker do
  use Oban.Worker, queue: :mcp_tasks, max_attempts: 3, unique: [period: 300, keys: [:task_id]]

  alias ConduitMcp.Ext.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => id, "dataset_id" => dataset_id}}) do
    case Tasks.status(id) do
      {:ok, %{status: "cancelled"}} ->
        {:cancel, "cancelled by client"}

      {:ok, %{status: "working"}} ->
        :ok = Tasks.progress(id, "Analyzing #{dataset_id}")
        report = MyApp.Analysis.run(dataset_id)
        _ = Tasks.complete(id, %{"content" => [%{"type" => "text", "text" => report}]})
        :ok

      {:ok, %{status: "input_required"}} ->
        {:snooze, 5}

      _terminal_or_expired ->
        {:cancel, "task gone"}
    end
  end
end
```

| Task status | Worker side |
|---|---|
| `working` | the job runs; `Tasks.progress/2` updates the status message |
| `input_required` | `Tasks.require_input/3`, then `{:snooze, seconds}` until the client's `tasks/update` answers |
| `completed` | `Tasks.complete/2` with the `CallToolResult` |
| `failed` | `Tasks.fail/2` with a JSON-RPC error, e.g. from an `[:oban, :job, :exception]` handler on the final attempt |
| `cancelled` | the client's `tasks/cancel`; check `Tasks.cancelled?/1` and return `{:cancel, _}` |

Terminal states are final: after `cancelled`, a late `complete/2` returns
`{:error, :terminal}` instead of overwriting it. Answers to `require_input/3` arrive in
`Tasks.status/1`'s `input_responses` once every outstanding key is answered. Each key is
single-use over the task's life.

### Status notifications

Instead of polling, a modern client can name its tasks in the `taskIds` filter of
`subscriptions/listen` and receive `notifications/tasks` (the full task state) on every
change. The default notifier, `ConduitMcp.Ext.Tasks.ListenNotifier`, delivers them only to
streams whose principal owns the task.

To also wake a snoozed job when the client answers, configure your own notifier and keep
listen delivery by calling the default from it:

```elixir
config :conduit_mcp, :ext_tasks, store: MyApp.ExtTaskStore, notifier: MyApp.TaskNotifier

defmodule MyApp.TaskNotifier do
  @behaviour ConduitMcp.Ext.Tasks.Notifier

  @impl true
  def task_changed(task) do
    ConduitMcp.Ext.Tasks.ListenNotifier.task_changed(task)
    if task.status == "working", do: MyApp.Jobs.wake(task.task_id)
  end
end
```

`task_changed/1` runs in the process that made the change, and an exception in it is logged
and swallowed. Delivery is node-local; see [Subscriptions](subscriptions.md#multi-node) for
fan-out across a cluster. `notifier: nil` turns notifications off.

### The store

An Oban-backed `ConduitMcp.Ext.Tasks.Store` keeps the task record next to its job:

- **Owner checks.** `get/2`, `update/3` and `cancel/2` must answer `{:error, :not_found}` for
  another owner, exactly as for a missing id.
- **Atomicity.** Every read-modify-write must be atomic (a version column with
  compare-and-swap, `SELECT … FOR UPDATE`, a transaction). Otherwise a client's
  `tasks/update` can overwrite the worker's `completed`.
- **No `list`.** There is no `tasks/list`; task ids are bearer tokens.

`Examples.ObanTasks.ExtStore` in `examples/oban_tasks_server/` implements this over SQLite
with a version column.

## Legacy era: `ConduitMcp.Tasks` (frozen)

> #### Frozen {: .info}
>
> This store serves `2025-11-25` clients only. It is frozen: no new features, and it goes
> away with the legacy era.

`ConduitMcp.Tasks` makes the storage layer pluggable via the
`ConduitMcp.Tasks.Store` behaviour — flip the framework from its
default in-memory ETS store to an Oban-backed store with one config line:

```elixir
config :conduit_mcp, :tasks_store, MyApp.ObanTaskStore
```

The legacy `tasks/get`, `tasks/cancel`, `tasks/result`, and
`tasks/list` JSON-RPC routes dispatch through the configured store
without any handler changes.

### Status Mapping

| MCP Task Status | Oban Job State |
|-----------------|----------------|
| `working` | `executing` / `available` |
| `input_required` | `{:snooze, seconds}` |
| `completed` | `completed` |
| `failed` | `discarded` |
| `cancelled` | `cancelled` |

### Setup

Add to your deps:

```elixir
{:oban, "~> 2.18"}
```

#### Migration

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

#### Schema

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

#### Worker

```elixir
defmodule MyApp.McpTaskWorker do
  use Oban.Worker,
    queue: :mcp_tasks,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:task_id]]

  # Allowlist of handler names → modules. NEVER resolve a client-supplied
  # string to a module via String.to_existing_atom/1 + apply/3.
  @handlers %{"analysis" => MyApp.AnalysisHandler}

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, max_attempts: max, args: %{"task_id" => task_id} = args}) do
    update_status(task_id, "working")

    case execute(args) do
      {:ok, result} ->
        update_task(task_id, %{status: "completed", result: result})
        :ok

      {:error, reason} ->
        # Only mark "failed" on the final attempt; let earlier retries stay
        # "working" so the client doesn't see status flicker on each retry.
        if attempt >= max do
          update_task(task_id, %{status: "failed", result: %{"error" => inspect(reason)}})
        end

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
    case Map.fetch(@handlers, handler) do
      {:ok, module} -> module.execute(args)
      :error -> {:error, "unknown handler: #{handler}"}
    end
  end

  defp update_status(task_id, status), do: update_task(task_id, %{status: status})

  # Returns {:ok, task} | {:error, changeset} | {:error, :not_found} so callers
  # can react to a failed write instead of silently dropping it.
  defp update_task(task_id, updates) do
    case MyApp.Repo.get(MyApp.McpTask, task_id) do
      nil -> {:error, :not_found}
      task -> MyApp.Repo.update(MyApp.McpTask.changeset(task, updates))
    end
  end
end
```

#### Task Store

A `ConduitMcp.Tasks.Store` implementation. The framework dispatches every
`tasks/*` route through this module once configured.

```elixir
defmodule MyApp.ObanTaskStore do
  @behaviour ConduitMcp.Tasks.Store

  import Ecto.Query
  @repo MyApp.Repo

  # Task insert, job insert, and the oban_job_id back-link all commit in one
  # transaction. A crash mid-sequence rolls back — no orphaned task, no
  # unlinked job (which would leave cancel/1 unable to reach the job).
  def create_with_job(task_id, worker_args, opts \\ []) do
    attrs = %{task_id: task_id, status: "working", method: worker_args["method"]}
    job_args = Map.put(worker_args, "task_id", task_id)
    worker = Keyword.get(opts, :worker, MyApp.McpTaskWorker)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:task, MyApp.McpTask.changeset(%MyApp.McpTask{}, attrs))
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
        # Don't crash if the job already finished — log a non-:ok return.
        with id when not is_nil(id) <- task.oban_job_id,
             {:error, reason} <- Oban.cancel_job(id) do
          require Logger
          Logger.warning("Oban.cancel_job(#{id}) failed: #{inspect(reason)}")
        end

        # Return the updated task per the Store `cancel/1` contract
        # ({:ok, task} | {:error, :not_found}), not a bare :ok.
        case @repo.update(MyApp.McpTask.changeset(task, %{status: "cancelled"})) do
          {:ok, updated} -> {:ok, to_map(updated)}
          {:error, changeset} -> {:error, changeset}
        end
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

### Usage in MCP Server

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
        # Must be a key registered in the worker's @handlers allowlist
        # (see above) — never the raw module name from the client.
        "handler" => "analysis",
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

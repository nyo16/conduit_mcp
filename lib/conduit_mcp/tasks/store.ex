defmodule ConduitMcp.Tasks.Store do
  @moduledoc """
  Behaviour for pluggable task storage backends.

  ConduitMCP uses tasks to model long-running MCP operations (the
  `tasks/*` JSON-RPC routes in the 2025-11-25 spec). The default
  implementation, `ConduitMcp.Tasks.EtsStore`, keeps tasks in-memory and
  is ideal for single-node, ephemeral workloads. To survive restarts,
  distribute across nodes, or back tasks with a job queue, implement
  this behaviour and configure it as the application's task store:

      config :conduit_mcp, :tasks_store, MyApp.MyTasksStore

  The standard `tasks/get`, `tasks/cancel`, `tasks/result`, and
  `tasks/list` handler routes dispatch through `ConduitMcp.Tasks`, which
  forwards every storage call to the configured store. No handler
  changes are required.

  ## Implementing a Custom Store

  A custom store must persist whatever map shape the worker writes (the
  framework adds `"task_id"`, `"status"`, and `"created_at"` on `create/2`
  and never reads other keys itself, so any extra fields are preserved
  verbatim).

  ### Example: Postgres-backed Store

      defmodule MyApp.PostgresTaskStore do
        @behaviour ConduitMcp.Tasks.Store

        alias MyApp.{Repo, McpTask}

        @impl true
        def create(task_id, metadata) do
          task = Map.merge(metadata, %{"task_id" => task_id, "status" => "working",
                                       "created_at" => System.system_time(:millisecond)})
          %McpTask{}
          |> McpTask.changeset(task)
          |> Repo.insert()
          |> case do
            {:ok, row} -> {:ok, McpTask.to_map(row)}
            err        -> err
          end
        end

        @impl true
        def get(task_id) do
          case Repo.get(McpTask, task_id) do
            nil -> {:error, :not_found}
            row -> {:ok, McpTask.to_map(row)}
          end
        end

        # ...update/2, cancel/1, delete/1, list/1, cleanup/1
      end

  See `examples/oban_tasks_server/` for an Oban + SQLite implementation
  and `examples/oban_task_store.ex` for a Postgres-flavored reference.

  ## Configuration

      # Default — in-memory ETS, zero config
      # (equivalent to omitting the key)
      config :conduit_mcp, :tasks_store, ConduitMcp.Tasks.EtsStore

      # Custom store
      config :conduit_mcp, :tasks_store, MyApp.MyTasksStore
  """

  @typedoc "Opaque task identifier (typically `Base.url_encode64/1` of 16 random bytes)."
  @type task_id :: String.t()

  @typedoc "Task state. Worker code is responsible for keeping it consistent with the spec lifecycle."
  @type task :: map()

  @doc """
  Creates a new task with the given id and initial metadata.

  The store is responsible for setting `"task_id"`, `"status" => "working"`,
  and `"created_at"` on the stored row (the default `EtsStore` does this; a
  custom store should mirror that behaviour so the rest of the framework can
  rely on those fields).
  """
  @callback create(task_id, metadata :: map()) ::
              {:ok, task} | {:error, term()}

  @doc """
  Fetches a task by id.
  """
  @callback get(task_id) :: {:ok, task} | {:error, :not_found}

  @doc """
  Merges `updates` into the existing task and returns the new task. The
  store may also use this hook to emit side effects (e.g., publish a
  pub/sub event when a status flips to a terminal state).
  """
  @callback update(task_id, updates :: map()) :: {:ok, task} | {:error, :not_found}

  @doc """
  Cancels a task.

  Defaults to `update(task_id, %{"status" => "cancelled"})` via the facade
  when not implemented. Stores backed by a job queue should override this
  to also cancel the underlying job (e.g., `Oban.cancel_job/1`).
  """
  @callback cancel(task_id) :: {:ok, task} | {:error, :not_found}

  @doc """
  Deletes a task. Returns `:ok` whether or not the row existed.
  """
  @callback delete(task_id) :: :ok

  @doc """
  Lists tasks, optionally filtered by `:status`.
  """
  @callback list(opts :: keyword()) :: [task]

  @doc """
  Removes terminal-state tasks (`completed`, `failed`, `cancelled`) older
  than `ttl_ms`. Tasks still in `working` or `input_required` should
  never be evicted.

  Optional. Stores implementing this callback can be paired with
  `ConduitMcp.Tasks.Janitor` for periodic background eviction. Stores
  backed by systems with native TTL (e.g., Redis with `EX`, or an Oban
  pruner) can omit it.

  Returns the number of tasks removed, or `:ok`.
  """
  @callback cleanup(ttl_ms :: non_neg_integer()) :: non_neg_integer() | :ok

  @optional_callbacks cleanup: 1, cancel: 1
end

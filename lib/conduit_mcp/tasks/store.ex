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

  ## Owner scoping (BOLA/IDOR protection)

  The `tasks/*` routes key purely on the client-supplied `taskId`. To stop one
  principal from reading or cancelling another's task, `ConduitMcp.Tasks`
  applies **owner scoping** in the facade — the store behaviour itself stays
  unchanged. When a task is created with an owner
  (`ConduitMcp.Tasks.create/3`, typically `create(id, meta, owner(conn))`), the
  facade compares the caller's principal against the task's owner on every
  `get/2`, `cancel/2`, and `list/2`, returning `{:error, :not_found}` on a
  mismatch so existence isn't leaked.

  For this to work, **a store must round-trip the owner at the top-level
  `"owner"` key** of the map returned by `get/1` and `list/1` — the same place
  `create/2` received it in `metadata`. The default `EtsStore` does this for
  free because it persists the metadata map verbatim. A store that shreds
  metadata into columns (or a nested JSON blob) must promote `"owner"` back to
  the top level in its `to_map`/read path, e.g. add an `owner` column and
  surface it as `"owner"`.

  Scoping is **opt-in per task**: it only bites once a task is created with an
  owner. But it is **not** default-open. The matrix is documented on
  `ConduitMcp.Tasks.get/2`; the short version is that a caller with no
  principal sees only unowned tasks, and
  `config :conduit_mcp, :tasks_require_owner, true` removes even those.
  Apps that never stamp an owner are unaffected; a task stamped with an owner
  is never visible to an unauthenticated caller.

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
  Lists tasks matching `opts`.

  Recognised options:

    * `:status` — restrict to one task status (a string or atom).
    * `:limit` — maximum number of rows to return.
    * `:owner` — the caller's principal, or `:any` for an unscoped listing.
      `nil` = no principal: sees only unowned tasks; nothing under
      `:tasks_require_owner` (see `ConduitMcp.Tasks.get/2`).

  **`:owner` is an authorization filter, not a convenience.** Expressing it as
  a query predicate is what keeps `tasks/list` from copying every row into the
  caller's heap before deciding they may not see it. Compare owners with exact
  equality (`===`), as `ConduitMcp.Tasks` does, so `1` and `1.0` are distinct
  principals.

  `ConduitMcp.Tasks.list/2` re-checks the returned rows and re-applies
  `:limit`, so a store that ignores `:owner` cannot leak another principal's
  tasks. **A store that ignores `:owner` must also ignore `:limit`**: honouring
  `:limit` alone returns the first N rows of *any* owner, and the owner
  re-check then leaves the caller with fewer of their own rows than exist, or
  none. Even when it ignores both, the store copies every row on each call,
  which on a large table is the DoS this contract exists to prevent.
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

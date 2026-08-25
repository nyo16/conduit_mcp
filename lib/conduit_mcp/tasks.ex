defmodule ConduitMcp.Tasks do
  @moduledoc """
  Task management for long-running MCP operations (experimental).

  Tasks provide a durable state machine for operations that may take time to
  complete. Clients can poll for status, cancel in-flight operations, and
  receive results asynchronously.

  ## Task Lifecycle

      working → completed
      working → failed
      working → cancelled
      working → input_required → working (after elicitation)

  ## Storage

  Storage is delegated to a pluggable store module implementing
  `ConduitMcp.Tasks.Store`. The default store is
  `ConduitMcp.Tasks.EtsStore` (in-memory, single-node). For durable,
  multi-node deployments — or to back tasks with a job queue like Oban —
  implement the behaviour and configure it as the application's task store:

      config :conduit_mcp, :tasks_store, MyApp.MyTasksStore

  The standard `tasks/get`, `tasks/cancel`, `tasks/result`, and
  `tasks/list` JSON-RPC routes dispatch through this module, so swapping
  the store requires no handler changes. See
  `examples/oban_tasks_server/` for an Oban + SQLite implementation and
  `examples/oban_task_store.ex` for a Postgres-flavored reference.

  ## Configuration

  Enable tasks in your transport config:

      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        tasks: [enabled: true]}
  """

  @type task_id :: String.t()
  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @valid_statuses ~w(working input_required completed failed cancelled)a
  @default_store ConduitMcp.Tasks.EtsStore

  # Allowed status transitions (string keys match the on-the-wire task map).
  @transitions %{
    "working" => ~w(completed failed cancelled input_required),
    "input_required" => ~w(working cancelled)
  }

  @doc """
  Generates a unique task ID.
  """
  def generate_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc """
  Creates a new task. See `ConduitMcp.Tasks.Store`.

  Pass `owner` (typically `owner(conn)`) to stamp the task with a principal so
  it can be owner-scoped via `get/2`, `cancel/2`, and `list/2`. When `owner` is
  `nil` (the default) the task is left unowned and readable by anyone, which
  preserves back-compatibility for apps that don't use scoping.

  The owner is stored under the top-level `"owner"` key of the task metadata —
  see the "Owner scoping" section of `ConduitMcp.Tasks.Store`.
  """
  def create(task_id, metadata \\ %{}, owner \\ nil)
  def create(task_id, metadata, nil), do: store().create(task_id, metadata)

  def create(task_id, metadata, owner),
    do: store().create(task_id, Map.put(metadata, "owner", owner))

  @doc "Gets a task by ID. See `ConduitMcp.Tasks.Store`."
  def get(task_id), do: store().get(task_id)

  @doc """
  Gets a task by ID, scoped to `owner`.

  Returns `{:error, :not_found}` when the caller may not see the task, so a
  task's existence is never leaked to a non-owner.

  | task `"owner"` | caller `owner` | default | `:tasks_require_owner` |
  |---|---|---|---|
  | unowned | `nil` | allow | deny |
  | unowned | `X` | allow | deny |
  | `Y` | `nil` | **deny** | deny |
  | `Y` | `Y` | allow | allow |
  | `Y` | `X` | deny | deny |

  The `Y`/`nil` row is the fix: a `nil` caller used to match *everything*,
  which made authorization default-open — an unauthenticated request read any
  principal's task. Set `config :conduit_mcp, :tasks_require_owner, true` to
  also refuse unowned tasks, which is the right posture once every creation
  site stamps an owner.

  See the "Owner scoping" section of `ConduitMcp.Tasks.Store`.
  """
  def get(task_id, owner), do: authorize(store().get(task_id), owner)

  @doc "Updates a task's status and/or metadata. See `ConduitMcp.Tasks.Store`."
  def update(task_id, updates), do: store().update(task_id, updates)

  @doc """
  Cancels a task. Dispatches to the configured store's `cancel/1` callback;
  falls back to `update(task_id, %{"status" => "cancelled"})` for stores
  that don't implement it.
  """
  def cancel(task_id) do
    mod = store()

    if function_exported?(mod, :cancel, 1) do
      mod.cancel(task_id)
    else
      mod.update(task_id, %{"status" => "cancelled"})
    end
  end

  @doc """
  Cancels a task, scoped to `owner`.

  Returns `{:error, :not_found}` (without cancelling) when the task is owned by
  a different principal. See `get/2` for the scoping rules.
  """
  def cancel(task_id, owner) do
    case authorize(store().get(task_id), owner) do
      {:ok, _task} -> cancel(task_id)
      {:error, :not_found} = err -> err
    end
  end

  @doc "Deletes a task by ID. See `ConduitMcp.Tasks.Store`."
  def delete(task_id), do: store().delete(task_id)

  @doc """
  Prunes terminal-state tasks older than `ttl_ms`. Dispatches to the
  configured store's `cleanup/1` callback; returns `0` for stores that
  don't implement it (e.g., stores backed by native TTL like Redis).
  """
  def cleanup(ttl_ms) do
    mod = store()

    if function_exported?(mod, :cleanup, 1) do
      mod.cleanup(ttl_ms)
    else
      0
    end
  end

  @doc "Lists tasks, optionally filtered by `:status` and `:limit`. See `ConduitMcp.Tasks.Store`."
  def list(opts \\ []), do: store().list(opts)

  @doc """
  Lists tasks scoped to `owner`, optionally filtered by `:status` and
  `:limit`.

  The owner is pushed into the store query rather than applied afterwards, so
  a store can express it as a predicate (the default `EtsStore` compiles all
  three options into one `:ets.select/3` match spec). The facade re-checks the
  returned rows: a custom store that ignores `:owner` must not turn into a
  silent authorization bypass.

  Returns the caller's own tasks plus unowned ones. A `nil` `owner` (no
  principal) sees **only** unowned tasks — it no longer matches everything.
  Set `config :conduit_mcp, :tasks_require_owner, true` to make unowned tasks
  inaccessible too. See `get/2` for the full matrix.
  """
  def list(opts, owner) do
    opts
    |> Keyword.put(:owner, owner)
    |> store().list()
    |> Enum.filter(&authorized?(&1, owner))
  end

  @doc """
  Extracts the owner principal from a `Plug.Conn` (or conn-like map).

  Applies the configured `:task_owner_fun`
  (`config :conduit_mcp, :task_owner_fun`), which defaults to
  `ConduitMcp.Principal.id/1` — the stable scalar identity assigned by both
  auth plugs. Returns `nil` for `nil`/non-conn input or when no principal is
  present; `nil` means "no scoping" throughout this module.

  > #### Return a stable scalar {: .warning}
  >
  > Ownership is checked by **exact match** (`==`), so a custom extractor must
  > return a stable, comparable identity — the user's `sub`/`id` scalar, never
  > a struct or claims map. A term carrying any per-request volatile field
  > (`exp`, `iat`, `jti`) fails to match its own tasks on the next request, so
  > the owner's own task 404s; an extractor mapping distinct users to equal
  > terms leaks tasks between them. `ConduitMcp.Principal.id/1` is already
  > such a scalar — prefer it.
  """
  def owner(nil), do: nil

  def owner(conn) do
    fun = Application.get_env(:conduit_mcp, :task_owner_fun, &default_owner/1)
    fun.(conn)
  end

  defp default_owner(%{assigns: assigns} = conn) when is_map(assigns) do
    case ConduitMcp.Principal.id(conn) do
      nil -> legacy_scalar_owner(assigns)
      id -> id
    end
  end

  defp default_owner(_), do: nil

  # Back-compat: an app that assigned a bare scalar to :current_user (the one
  # shape the old default actually worked for) keeps working. A map or struct
  # is deliberately *not* accepted — that is the shape that silently 404'd.
  defp legacy_scalar_owner(assigns) do
    case Map.get(assigns, :current_user) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  # A task is accessible when the owners match, or when the task is unowned
  # and unowned tasks are still readable. On mismatch we report
  # `{:error, :not_found}` so a non-owner can't distinguish "exists but
  # yours" from "doesn't exist".
  defp authorize({:ok, task} = ok, owner) do
    if authorized?(task, owner), do: ok, else: {:error, :not_found}
  end

  defp authorize({:error, _} = err, _owner), do: err

  defp authorized?(task, owner) do
    case Map.get(task, "owner") do
      nil -> not require_owner?()
      ^owner -> true
      _other -> false
    end
  end

  defp require_owner?, do: Application.get_env(:conduit_mcp, :tasks_require_owner, false)

  @doc """
  Validates that a status transition is allowed.
  """
  def valid_transition?(from, to) do
    to in Map.get(@transitions, from, [])
  end

  @doc "Returns the list of valid task statuses."
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns the configured task store module. Reads from
  `Application.get_env(:conduit_mcp, :tasks_store)`, defaulting to
  `ConduitMcp.Tasks.EtsStore`.
  """
  def store, do: Application.get_env(:conduit_mcp, :tasks_store, @default_store)
end

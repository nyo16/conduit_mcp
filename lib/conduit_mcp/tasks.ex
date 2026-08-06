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

  Returns `{:error, :not_found}` when the task is owned by a *different*
  principal, so a task's existence is never leaked to a non-owner. A `nil`
  `owner` (no principal) or an unowned task is always accessible — see the
  "Owner scoping" section of `ConduitMcp.Tasks.Store`.
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

  @doc "Lists tasks, optionally filtered by `:status`. See `ConduitMcp.Tasks.Store`."
  def list(opts \\ []), do: store().list(opts)

  @doc """
  Lists tasks scoped to `owner`, optionally filtered by `:status`.

  Returns only tasks the caller may see: their own (matching `"owner"`) plus
  any unowned tasks. A `nil` `owner` (no principal) returns everything, matching
  `list/1`. See `get/2` for the scoping rules.
  """
  def list(opts, owner), do: store().list(opts) |> Enum.filter(&authorized?(&1, owner))

  @doc """
  Extracts the owner principal from a `Plug.Conn` (or conn-like map).

  Applies the configured `:task_owner_fun`
  (`config :conduit_mcp, :task_owner_fun`), which defaults to
  `conn.assigns[:current_user]`. Returns `nil` for `nil`/non-conn input or when
  no principal is present — `nil` means "no scoping" throughout this module.

  > #### Return a stable scalar {: .warning}
  >
  > Ownership is checked by **exact match** (`==`), so the extractor should
  > return a stable, comparable identity — typically the user's `sub`/`id`
  > scalar, not the whole `current_user` struct. A struct carrying any
  > per-request volatile field would fail to match its own tasks on a later
  > request, and an extractor that maps distinct users to equal terms would
  > leak tasks between them. The default works when `current_user` is itself a
  > stable id; map it to one otherwise, e.g.
  > `task_owner_fun: &(&1.assigns[:current_user] && &1.assigns.current_user.id)`.
  """
  def owner(nil), do: nil

  def owner(conn) do
    fun = Application.get_env(:conduit_mcp, :task_owner_fun, &default_owner/1)
    fun.(conn)
  end

  defp default_owner(%{assigns: assigns}) when is_map(assigns),
    do: Map.get(assigns, :current_user)

  defp default_owner(_), do: nil

  # A task is accessible when the caller has no principal (no scoping requested),
  # the task is unowned (back-compat), or the owners match. On mismatch we report
  # `{:error, :not_found}` so a non-owner can't distinguish "exists but yours"
  # from "doesn't exist".
  defp authorize({:ok, task} = ok, owner) do
    if authorized?(task, owner), do: ok, else: {:error, :not_found}
  end

  defp authorize({:error, _} = err, _owner), do: err

  defp authorized?(_task, nil), do: true

  defp authorized?(task, owner) do
    case Map.get(task, "owner") do
      nil -> true
      ^owner -> true
      _ -> false
    end
  end

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

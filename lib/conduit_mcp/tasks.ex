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

  @doc """
  Generates a unique task ID.
  """
  def generate_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc "Creates a new task. See `ConduitMcp.Tasks.Store`."
  def create(task_id, metadata \\ %{}), do: store().create(task_id, metadata)

  @doc "Gets a task by ID. See `ConduitMcp.Tasks.Store`."
  def get(task_id), do: store().get(task_id)

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

  @doc """
  Returns the configured task store module. Reads from
  `Application.get_env(:conduit_mcp, :tasks_store)`, defaulting to
  `ConduitMcp.Tasks.EtsStore`.
  """
  def store, do: Application.get_env(:conduit_mcp, :tasks_store, @default_store)
end

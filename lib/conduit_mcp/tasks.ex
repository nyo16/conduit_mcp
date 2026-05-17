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

  Storage is delegated to a pluggable store module. The default is
  `ConduitMcp.Tasks.EtsStore` (in-memory, single-node). For durable, multi-node
  deployments — or to back tasks with a job queue like Oban — implement
  `ConduitMcp.Tasks.Store` and override the store via application config:

      config :conduit_mcp, :tasks_store, MyApp.MyTasksStore

  See `examples/oban_tasks_server/` for an Oban + SQLite implementation and
  `examples/oban_task_store.ex` for a Postgres-flavored reference.

  ## Configuration

  Enable tasks in your transport config:

      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        tasks: [enabled: true]}
  """

  alias ConduitMcp.Tasks.EtsStore

  @type task_id :: String.t()
  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @valid_statuses ~w(working input_required completed failed cancelled)a

  @doc """
  Generates a unique task ID.
  """
  def generate_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc "Creates a new task. See `ConduitMcp.Tasks.Store`."
  defdelegate create(task_id, metadata \\ %{}), to: EtsStore

  @doc "Gets a task by ID. See `ConduitMcp.Tasks.Store`."
  defdelegate get(task_id), to: EtsStore

  @doc "Updates a task's status and/or metadata. See `ConduitMcp.Tasks.Store`."
  defdelegate update(task_id, updates), to: EtsStore

  @doc "Cancels a task. See `ConduitMcp.Tasks.Store`."
  defdelegate cancel(task_id), to: EtsStore

  @doc "Deletes a task by ID. See `ConduitMcp.Tasks.Store`."
  defdelegate delete(task_id), to: EtsStore

  @doc "Prunes terminal-state tasks older than `ttl_ms`. See `ConduitMcp.Tasks.Store`."
  defdelegate cleanup(ttl_ms), to: EtsStore

  @doc "Lists tasks, optionally filtered by `:status`. See `ConduitMcp.Tasks.Store`."
  defdelegate list(opts \\ []), to: EtsStore

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
end

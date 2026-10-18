defmodule ConduitMcp.Ext.Tasks.Store do
  @moduledoc """
  Storage behaviour for `ConduitMcp.Ext.Tasks` (experimental, unstable — see
  that module).

  A store holds one `t:record/0` per task. `ConduitMcp.Ext.Tasks.EtsStore`
  is the in-memory reference implementation; implement this behaviour to
  keep tasks in a database or job queue and configure it with
  `config :conduit_mcp, :ext_tasks, store: MyStore`.

  ## Contract

    * **No enumeration.** There is deliberately no `list` callback: the
      extension has no `tasks/list`, and a task id is a bearer token.
    * **Owner scoping.** `get/2`, `update/3` and `cancel/2` take the
      caller's owner (`ConduitMcp.Principal.id/1` of the request, `nil`
      when unauthenticated) and must answer `{:error, :not_found}` when the
      record's `owner` differs (`===`), exactly as for a missing id, so a
      caller cannot tell "exists but not yours" from "does not exist".
      `get/2` also accepts `:any`, used only by server-side code that
      already holds the id (the task's own worker).
    * **Atomicity.** `update/3`, `cancel/2` and `put_status/3` are
      read-modify-write operations. A store must apply each atomically
      with respect to the others (compare-and-swap, a row lock, a
      transaction), otherwise a client's `tasks/update` can overwrite a
      worker's `completed` with `working`.
    * **Terminal states are final.** `put_status/3` and `cancel/2` must not
      change a record whose status is `completed`, `failed` or `cancelled`.
    * **Durability.** `create/2` returns only once a `get/2` for the id
      would find the record: the handler answers `CreateTaskResult` right
      after it.

  `cleanup/1` is optional; `ConduitMcp.Session.Janitor` calls it on an
  interval when the application starts the Ext.Tasks janitor.
  """

  @typedoc "A task id: 32 random bytes, url-safe Base64 without padding."
  @type task_id :: String.t()

  @typedoc "A task status; the last three are terminal."
  @type status :: String.t()

  @typedoc "The owning principal id (`ConduitMcp.Principal.id/1`), or `nil`."
  @type owner :: String.t() | nil

  @typedoc """
  A stored task. Timestamps are Unix milliseconds; `ttl_ms` `nil` means
  unlimited. `input_requests` holds the outstanding MRTR input requests,
  `input_responses` every answer received so far.
  """
  @type task :: %{
          task_id: task_id(),
          status: status(),
          status_message: String.t() | nil,
          created_at: integer(),
          last_updated_at: integer(),
          ttl_ms: non_neg_integer() | nil,
          poll_interval_ms: pos_integer() | nil,
          input_requests: %{optional(String.t()) => map()},
          input_responses: %{optional(String.t()) => map()},
          result: map() | nil,
          error: map() | nil,
          owner: owner()
        }

  @typedoc "A pure transformation applied by `update/3`."
  @type update_fun :: (task() -> {:ok, task()} | {:error, term()})

  @doc """
  Stores a new record. `opts` carries `:max_rows` (a row cap, or
  `:infinity`).
  """
  @callback create(task(), opts :: keyword()) ::
              {:ok, task()} | {:error, :task_limit_reached | term()}

  @doc "Fetches the record `owner` may see (`:any` skips the owner check)."
  @callback get(task_id(), owner() | :any) :: {:ok, task()} | {:error, :not_found}

  @doc """
  Atomically replaces `owner`'s record with the result of `fun`; an
  `{:error, reason}` from `fun` leaves it unchanged and is returned.
  `:any` skips the owner check (server-side callers only).
  """
  @callback update(task_id(), owner() | :any, update_fun()) ::
              {:ok, task()} | {:error, :not_found | term()}

  @doc """
  Records a cancellation request: a non-terminal record becomes
  `cancelled`; a terminal one is returned unchanged.
  """
  @callback cancel(task_id(), owner()) :: {:ok, task()} | {:error, :not_found}

  @doc """
  Moves a non-terminal record to `status`, merging `fields` (worker side;
  not owner-scoped). A terminal record is left unchanged:
  `{:error, :terminal}`.
  """
  @callback put_status(task_id(), status(), fields :: map()) ::
              {:ok, task()} | {:error, :not_found | :terminal}

  @doc """
  Evicts expired records and returns how many were removed. A record
  expires `ttl_ms` after `created_at`; one with a `nil` `ttl_ms` is evicted
  only once terminal and older than `default_ttl_ms`.
  """
  @callback cleanup(default_ttl_ms :: non_neg_integer()) :: non_neg_integer()

  @optional_callbacks cleanup: 1
end

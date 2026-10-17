defmodule ConduitMcp.Client.Task do
  @moduledoc """
  A server-side task a tool call was turned into.

  `ConduitMcp.Client.call_tool/4` with `task: :return` returns one when the
  server ran the call as a task:

    * **modern** (`2026-07-28`, the `io.modelcontextprotocol/tasks`
      extension): the server answered `resultType: "task"`;
    * **legacy** (`2025-11-25`): the client task-augmented the call (the
      tool's `execution.taskSupport` allowed it and the server declared
      `tasks.requests.tools.call`) and the server answered
      `CreateTaskResult`.

  Poll it with `ConduitMcp.Client.get_task/3`, wait for its result with
  `ConduitMcp.Client.await_task/3`, or cancel it with
  `ConduitMcp.Client.cancel_task/3`.

  ## Fields

    * `id` - the server's task id. Task ids are bound to the credential that
      created them and may act as bearer tokens: never log them.
    * `status` - `:working`, `:input_required`, `:completed`, `:failed`,
      `:cancelled`, or `:unknown` for a value this client does not know.
    * `status_message`, `created_at`, `last_updated_at` (ISO 8601 strings).
    * `ttl_ms` - how long the server keeps it (`nil` for unlimited).
    * `poll_interval_ms` - the server's suggested polling interval, or `nil`.
    * `input_requests` - modern `input_required` only: the outstanding
      requests, keyed as the server keyed them.
    * `result` - modern `completed` only: the final result map.
    * `error` - modern `failed` only: the JSON-RPC error object.
    * `era`, `server_id` - where it lives; the poll functions use them.
    * `raw` - the server's string-keyed task map.
  """

  alias ConduitMcp.Client.Wire

  @enforce_keys [:id, :status, :era, :server_id, :raw]
  defstruct [
    :id,
    :status,
    :status_message,
    :created_at,
    :last_updated_at,
    :ttl_ms,
    :poll_interval_ms,
    :input_requests,
    :result,
    :error,
    :era,
    :server_id,
    :raw
  ]

  @type status :: :working | :input_required | :completed | :failed | :cancelled | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          status_message: String.t() | nil,
          created_at: String.t() | nil,
          last_updated_at: String.t() | nil,
          ttl_ms: non_neg_integer() | nil,
          poll_interval_ms: non_neg_integer() | nil,
          input_requests: map() | nil,
          result: map() | nil,
          error: map() | nil,
          era: :modern | :legacy,
          server_id: String.t(),
          raw: map()
        }

  @statuses %{
    "working" => :working,
    "input_required" => :input_required,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled
  }

  @doc """
  Builds a task from a wire `Task` map: the modern `CreateTaskResult` /
  `tasks/get` result, or a legacy `Task` (legacy keys `ttl` and
  `pollInterval` are read as well). A map without a string `taskId` is a
  `:protocol` error with reason `:invalid_task`.

      iex> {:ok, task} =
      ...>   ConduitMcp.Client.Task.from_wire("files", :modern, %{
      ...>     "taskId" => "t1",
      ...>     "status" => "working",
      ...>     "pollIntervalMs" => 500
      ...>   })
      iex> {task.status, task.poll_interval_ms}
      {:working, 500}
  """
  @spec from_wire(String.t(), :modern | :legacy, term()) ::
          {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(server_id, era, %{"taskId" => id, "status" => status} = raw)
      when is_binary(id) and is_binary(status) do
    {:ok,
     %__MODULE__{
       id: id,
       status: Map.get(@statuses, status, :unknown),
       status_message: Wire.string(raw, "statusMessage"),
       created_at: Wire.string(raw, "createdAt"),
       last_updated_at: Wire.string(raw, "lastUpdatedAt"),
       ttl_ms: non_neg(Map.get(raw, "ttlMs", Map.get(raw, "ttl"))),
       poll_interval_ms: non_neg(Map.get(raw, "pollIntervalMs", Map.get(raw, "pollInterval"))),
       input_requests: Wire.object(raw, "inputRequests"),
       result: Wire.object(raw, "result"),
       error: Wire.object(raw, "error"),
       era: era,
       server_id: server_id,
       raw: raw
     }}
  end

  def from_wire(_server_id, _era, other), do: Wire.invalid(:invalid_task, other)

  @doc "Whether `task` reached a terminal status."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :cancelled]

  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: nil
end

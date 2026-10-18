defmodule ConduitMcp.Ext.Tasks do
  @moduledoc """
  The MCP Tasks extension (`io.modelcontextprotocol/tasks`) for the modern
  (`2026-07-28`) protocol era.

  > #### Experimental and unstable {: .warning}
  >
  > The extension's own repository describes it as experimental and still
  > tracking SEP-2663, and it already disagrees with the core specification
  > (it documents `-32003` where `2026-07-28` uses `-32021`; this library
  > follows the core specification). This API, its configuration and its
  > wire output may change in any release. It is off unless enabled.

  Specification: <https://modelcontextprotocol.io/extensions/tasks> and
  <https://github.com/modelcontextprotocol/ext-tasks> (schema
  `2026-07-28`). For legacy-era (`2025-11-25`) tasks see the frozen
  `ConduitMcp.Tasks`.

  ## Enabling

      config :conduit_mcp, :ext_tasks, true

      # or, with options:
      config :conduit_mcp, :ext_tasks,
        store: MyApp.TaskStore,        # default ConduitMcp.Ext.Tasks.EtsStore
        janitor: [interval: 30_000],   # Session.Janitor options, or false
        max_rows: 10_000,              # row cap passed to create/2, or :infinity
        notifier: MyApp.TaskNotifier   # default ConduitMcp.Ext.Tasks.ListenNotifier; nil for none

  The value is validated when `:conduit_mcp` starts. When enabled, the
  application starts `ConduitMcp.Ext.Tasks.EtsStore.Owner` (default store
  only) and a `ConduitMcp.Session.Janitor` named
  `ConduitMcp.Ext.Tasks.Janitor` that calls the store's `cleanup/1` (TTL
  expiry; `janitor: [ttl: ...]` is the age at which terminal tasks without
  a TTL are evicted, default one hour), and `server/discover` advertises
  `capabilities.extensions["io.modelcontextprotocol/tasks"]`.

  ## Returning a task

  A `tools/call` callback (`c:ConduitMcp.Server.handle_call_tool/3`, a DSL
  `handle`, a `c:ConduitMcp.Component.execute/2`) returns `{:task, attrs}`:

      def handle_call_tool(_conn, "build", %{"ref" => ref}) do
        {:task,
         ttl_ms: :timer.minutes(30),
         poll_interval_ms: 2_000,
         status_message: "Queued",
         start: fn task_id -> MyApp.Builds.enqueue(task_id, ref) end}
      end

  `attrs` (keyword list or atom-keyed map), all optional:

    * `:ttl_ms` — lifetime from creation (default one hour); `nil` means
      unlimited.
    * `:poll_interval_ms` — suggested polling interval (positive integer).
    * `:status_message` — initial status message.
    * `:start` — `fn task_id -> ... end`, called once the task is stored.
      **This is where the work starts**: spawn it (a `Task` under your
      supervisor, an Oban job, a message to a GenServer) and return; the
      request is waiting. If it raises, the task is failed with `-32603`.

  The library then requires that the client declared the extension in this
  request's `io.modelcontextprotocol/clientCapabilities.extensions`
  (otherwise `-32021` with `data.requiredCapabilities`, HTTP 400), stores
  the task **before** answering, calls `:start`, and answers with a
  `CreateTaskResult` (`resultType: "task"`). The task is owned by the
  request's principal (`ConduitMcp.Principal.id/1`): `tasks/get`,
  `tasks/update` and `tasks/cancel` from any other principal answer
  "Task not found". Unauthenticated tasks are owned by `nil`; their id is
  then their only protection (32 random bytes).

  Only `tools/call` may return a task. From any other callback, on the
  legacy era, or with the extension disabled, `{:task, _}` is logged and
  answered with `-32603`.

  ## Driving a task from the worker

  The worker reports through `complete/2`, `fail/2`, `require_input/3` and
  `progress/2`, and reads the task with `status/1` (or `cancelled?/1`).
  These address the task by id alone: the id is the capability, so keep it
  out of logs.

      def perform(%{args: %{"task_id" => id, "ref" => ref}}) do
        :ok = ConduitMcp.Ext.Tasks.progress(id, "Building")
        result = MyApp.Builds.run(ref)
        ConduitMcp.Ext.Tasks.complete(id, %{"content" => [%{"type" => "text", "text" => result}]})
      end

  `complete/2` takes what the tool would have returned synchronously (a
  `CallToolResult` map, `isError: true` included). `fail/2` is for JSON-RPC
  errors only.

  Input mid-flight: `require_input/3` moves the task to `input_required`
  with MRTR input requests (built with `ConduitMcp.MRTR.elicit/2`); the
  client reads them with `tasks/get` and answers with `tasks/update`. Once
  every outstanding key is answered the task returns to `working` and the
  answers are in `status/1`'s `input_responses`. Each key must be unique
  over the task's lifetime. Poll `status/1`, or configure a notifier to be
  told.

  Cancellation is cooperative: `tasks/cancel` moves a non-terminal task to
  `cancelled` (after which `complete/2`/`fail/2` return
  `{:error, :terminal}`); the worker should check `cancelled?/1` and stop.

  Terminal states — `completed`, `failed`, `cancelled` — are final.

  ## Status notifications

  Every change is handed to the configured `ConduitMcp.Ext.Tasks.Notifier`.
  The default, `ConduitMcp.Ext.Tasks.ListenNotifier`, sends it as
  `notifications/tasks` (the full task state, `to_wire/1`) to the
  `subscriptions/listen` streams that named the task in their `taskIds`
  filter, and only to those whose principal owns the task (SV-1; see
  `ConduitMcp.Subscriptions.Filter`). A custom notifier replaces it;
  `notifier: nil` turns notifications off.
  """

  require Logger

  alias ConduitMcp.Ext.Tasks.EtsStore
  alias ConduitMcp.Ext.Tasks.ListenNotifier
  alias ConduitMcp.Ext.Tasks.Store

  @extension "io.modelcontextprotocol/tasks"
  @statuses ~w(working input_required completed failed cancelled)
  @terminal ~w(completed failed cancelled)
  @default_ttl_ms :timer.hours(1)
  @default_max_rows 10_000
  @config_keys [:store, :janitor, :max_rows, :notifier]
  @attr_keys [:ttl_ms, :poll_interval_ms, :status_message, :start]

  @typedoc ~s(A JSON-RPC error object: `"code"`, `"message"`, optional `"data"`.)
  @type rpc_error :: %{required(String.t()) => term()}

  @doc "The extension identifier, `\"io.modelcontextprotocol/tasks\"`."
  @spec extension() :: String.t()
  def extension, do: @extension

  @doc "Every task status; see `terminal?/1`."
  @spec statuses() :: [Store.status()]
  def statuses, do: @statuses

  @doc "Whether `status` is terminal (`completed`, `failed`, `cancelled`)."
  @spec terminal?(term()) :: boolean()
  def terminal?(status), do: status in @terminal

  @doc "Whether `config :conduit_mcp, :ext_tasks` enables the extension."
  @spec enabled?() :: boolean()
  def enabled?, do: options() != false

  @doc "The configured store (default `ConduitMcp.Ext.Tasks.EtsStore`)."
  @spec store() :: module()
  def store, do: Keyword.get(options() || [], :store, EtsStore)

  @doc """
  Validates a `:ext_tasks` config value; returns it normalized to `false`
  or a keyword list. Raises `ArgumentError` naming the key otherwise.
  """
  @spec validate_config!(term()) :: false | keyword()
  def validate_config!(value) when value in [nil, false], do: false
  def validate_config!(true), do: []

  def validate_config!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_config!(opts)

    case Keyword.keys(opts) -- @config_keys do
      [] -> :ok
      unknown -> invalid_config!("unknown option(s) #{inspect(unknown)}")
    end

    Enum.each(opts, &validate_option!/1)
    opts
  end

  def validate_config!(other), do: invalid_config!(other)

  defp validate_option!({:store, store}) when is_atom(store) and not is_nil(store), do: :ok
  defp validate_option!({:notifier, mod}) when is_atom(mod), do: :ok
  defp validate_option!({:janitor, janitor}) when is_boolean(janitor), do: :ok
  defp validate_option!({:max_rows, :infinity}), do: :ok
  defp validate_option!({:max_rows, n}) when is_integer(n) and n > 0, do: :ok

  defp validate_option!({:janitor, opts}) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: invalid_config!(janitor: opts)
  end

  defp validate_option!(option), do: invalid_config!([option])

  defp invalid_config!(detail) do
    raise ArgumentError,
          "config :conduit_mcp, :ext_tasks accepts true, false or a keyword list of " <>
            "#{inspect(@config_keys)} (store: module, janitor: boolean | keyword, " <>
            "max_rows: pos_integer | :infinity, notifier: module | nil); got #{inspect(detail)}"
  end

  # Read at runtime so tests and releases can change it; validated at boot.
  defp options, do: validate_config!(Application.get_env(:conduit_mcp, :ext_tasks, false))

  @doc """
  A fresh task id: 32 bytes from `:crypto.strong_rand_bytes/1`, url-safe
  Base64 without padding (task ids are bearer tokens).
  """
  @spec new_id() :: Store.task_id()
  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # ---------------------------------------------------------------------------
  # Worker API (by id; not owner-scoped)

  @doc "Reads the task (worker side; not owner-scoped)."
  @spec status(Store.task_id()) :: {:ok, Store.task()} | {:error, :not_found}
  def status(task_id), do: store().get(task_id, :any)

  @doc "Whether the task was cancelled (`false` for an unknown id)."
  @spec cancelled?(Store.task_id()) :: boolean()
  def cancelled?(task_id), do: match?({:ok, %{status: "cancelled"}}, status(task_id))

  @doc """
  Completes the task with `result` — what the request would have returned
  synchronously, e.g. a `CallToolResult` map. Options: `:status_message`.
  """
  @spec complete(Store.task_id(), map(), keyword()) :: :ok | {:error, :not_found | :terminal}
  def complete(task_id, result, opts \\ []) when is_map(result) do
    finish(task_id, "completed", %{result: result, input_requests: %{}}, opts)
  end

  @doc """
  Fails the task with a JSON-RPC error: `%{"code" => integer, "message" =>
  string}` (optional `"data"`) or `{code, message}`. The status message
  defaults to the error message. Options: `:status_message`.
  """
  @spec fail(Store.task_id(), rpc_error() | {integer(), String.t()}, keyword()) ::
          :ok | {:error, :not_found | :terminal}
  def fail(task_id, error, opts \\ [])

  def fail(task_id, {code, message}, opts), do: fail(task_id, rpc_error(code, message), opts)

  def fail(task_id, %{"code" => code, "message" => message} = error, opts)
      when is_integer(code) and is_binary(message) do
    opts = Keyword.put_new(opts, :status_message, message)
    finish(task_id, "failed", %{error: Map.take(error, ["code", "message", "data"])}, opts)
  end

  defp finish(task_id, status, fields, opts) do
    fields =
      fields
      |> Map.put(:last_updated_at, now())
      |> maybe_put(:status_message, Keyword.get(opts, :status_message))

    task_id |> store().put_status(status, fields) |> notified()
  end

  @doc """
  Moves the task to `input_required` with `input_requests` (string keys to
  MRTR input requests built with `ConduitMcp.MRTR`), added to any still
  outstanding. A key already used by this task is rejected:
  `{:error, {:duplicate_keys, keys}}`. Options: `:status_message`.
  """
  @spec require_input(Store.task_id(), %{optional(String.t()) => map()}, keyword()) ::
          :ok
          | {:error, :not_found | :terminal | :invalid_input_requests | {:duplicate_keys, list()}}
  def require_input(task_id, input_requests, opts \\ []) do
    if ConduitMcp.Handler.MRTR.valid_input_requests?(input_requests) and input_requests != %{} do
      task_id
      |> store().update(:any, &put_input_requests(&1, input_requests, opts))
      |> notified()
    else
      {:error, :invalid_input_requests}
    end
  end

  defp put_input_requests(record, input_requests, opts) do
    used = Map.keys(record.input_requests) ++ Map.keys(record.input_responses)

    cond do
      terminal?(record.status) ->
        {:error, :terminal}

      (duplicates = Enum.filter(Map.keys(input_requests), &(&1 in used))) != [] ->
        {:error, {:duplicate_keys, duplicates}}

      true ->
        {:ok,
         %{
           record
           | status: "input_required",
             input_requests: Map.merge(record.input_requests, input_requests),
             status_message: Keyword.get(opts, :status_message, record.status_message),
             last_updated_at: now()
         }}
    end
  end

  @doc """
  Updates a non-terminal task's status message (and `lastUpdatedAt`)
  without changing its status.
  """
  @spec progress(Store.task_id(), String.t()) :: :ok | {:error, :not_found | :terminal}
  def progress(task_id, status_message) when is_binary(status_message) do
    task_id
    |> store().update(:any, fn record ->
      if terminal?(record.status),
        do: {:error, :terminal},
        else: {:ok, %{record | status_message: status_message, last_updated_at: now()}}
    end)
    |> notified()
  end

  # ---------------------------------------------------------------------------
  # Wire shape

  @doc """
  The extension's `DetailedTask` for `record` — the `tasks/get` result
  (before `resultType`) and the `notifications/tasks` params: `taskId`,
  `status`, ISO 8601 `createdAt`/`lastUpdatedAt`, `ttlMs` (`null` when
  unlimited), optional `statusMessage`/`pollIntervalMs`, plus
  `inputRequests` (`input_required`), `result` (`completed`) or `error`
  (`failed`).
  """
  @spec to_wire(Store.task()) :: map()
  def to_wire(record) do
    record
    |> to_task()
    |> put_detail(record)
  end

  @doc """
  The bare `Task` for `record` (no status-specific payload): the body of a
  `CreateTaskResult`.
  """
  @spec to_task(Store.task()) :: map()
  def to_task(record) do
    %{
      "taskId" => record.task_id,
      "status" => record.status,
      "createdAt" => iso8601(record.created_at),
      "lastUpdatedAt" => iso8601(record.last_updated_at),
      "ttlMs" => record.ttl_ms
    }
    |> maybe_put("statusMessage", record.status_message)
    |> maybe_put("pollIntervalMs", record.poll_interval_ms)
  end

  defp put_detail(task, %{status: "input_required", input_requests: requests}),
    do: Map.put(task, "inputRequests", requests)

  defp put_detail(task, %{status: "completed", result: result}),
    do: Map.put(task, "result", result || %{})

  defp put_detail(task, %{status: "failed", error: error}),
    do: Map.put(task, "error", error || rpc_error(-32_603, "Internal error"))

  defp put_detail(task, _record), do: task

  defp iso8601(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # ---------------------------------------------------------------------------
  # Client-facing operations, used by the handler (owner-scoped)

  @doc false
  # Builds, stores and starts a task for `owner` from a callback's `attrs`.
  @spec create(Store.owner(), keyword() | map()) ::
          {:ok, Store.task()} | {:error, {:invalid_attrs, term()} | term()}
  def create(owner, attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs),
         record = new_record(owner, attrs),
         {:ok, record} <- store().create(record, max_rows: max_rows()) do
      notify(record)
      start(record, Map.get(attrs, :start))
      {:ok, record}
    end
  end

  defp max_rows, do: Keyword.get(options() || [], :max_rows, @default_max_rows)

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: normalize_attrs(Map.new(attrs)), else: invalid_attrs(attrs)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    case Map.keys(attrs) -- @attr_keys do
      [] -> Enum.reduce_while(attrs, {:ok, attrs}, &check_attr/2)
      unknown -> invalid_attrs(unknown)
    end
  end

  defp normalize_attrs(attrs), do: invalid_attrs(attrs)

  defp check_attr({:ttl_ms, ttl}, acc) when is_nil(ttl) or (is_integer(ttl) and ttl >= 0),
    do: {:cont, acc}

  defp check_attr({:poll_interval_ms, ms}, acc) when is_nil(ms) or (is_integer(ms) and ms > 0),
    do: {:cont, acc}

  defp check_attr({:status_message, msg}, acc) when is_nil(msg) or is_binary(msg),
    do: {:cont, acc}

  defp check_attr({:start, fun}, acc) when is_nil(fun) or is_function(fun, 1), do: {:cont, acc}
  defp check_attr(attr, _acc), do: {:halt, invalid_attrs(attr)}

  defp invalid_attrs(detail), do: {:error, {:invalid_attrs, detail}}

  defp new_record(owner, attrs) do
    now = now()

    %{
      task_id: new_id(),
      status: "working",
      status_message: Map.get(attrs, :status_message),
      created_at: now,
      last_updated_at: now,
      ttl_ms: Map.get(attrs, :ttl_ms, @default_ttl_ms),
      poll_interval_ms: Map.get(attrs, :poll_interval_ms),
      input_requests: %{},
      input_responses: %{},
      result: nil,
      error: nil,
      owner: owner
    }
  end

  defp start(_record, nil), do: :ok

  defp start(record, fun) do
    fun.(record.task_id)
    :ok
  rescue
    exception ->
      Logger.error(
        "ConduitMcp.Ext.Tasks: the task's :start function raised " <>
          Exception.format_banner(:error, exception, __STACKTRACE__)
      )

      fail(record.task_id, rpc_error(-32_603, "Internal error"))
  end

  @doc false
  @spec get(Store.task_id(), Store.owner()) :: {:ok, Store.task()} | {:error, :not_found}
  def get(task_id, owner), do: store().get(task_id, owner)

  @doc false
  # `tasks/update`: accepts answers for outstanding keys only (others are
  # ignored, per the extension); back to `working` once none is outstanding.
  @spec answer(Store.task_id(), Store.owner(), map()) :: :ok | {:error, :not_found}
  def answer(task_id, owner, responses) when is_map(responses) do
    case store().update(task_id, owner, &accept_responses(&1, responses)) do
      {:error, :unchanged} -> :ok
      result -> notified(result)
    end
  end

  defp accept_responses(%{status: "input_required"} = record, responses) do
    accepted = Map.take(responses, Map.keys(record.input_requests))

    if accepted == %{} do
      {:error, :unchanged}
    else
      outstanding = Map.drop(record.input_requests, Map.keys(accepted))

      {:ok,
       %{
         record
         | input_requests: outstanding,
           input_responses: Map.merge(record.input_responses, accepted),
           status: if(outstanding == %{}, do: "working", else: "input_required"),
           last_updated_at: now()
       }}
    end
  end

  defp accept_responses(_record, _responses), do: {:error, :unchanged}

  @doc false
  @spec cancel(Store.task_id(), Store.owner()) :: :ok | {:error, :not_found}
  def cancel(task_id, owner), do: task_id |> store().cancel(owner) |> notified()

  # ---------------------------------------------------------------------------

  defp notified({:ok, record}) do
    notify(record)
    :ok
  end

  defp notified({:error, _reason} = error), do: error

  defp notify(record) do
    case Keyword.get(options() || [], :notifier, ListenNotifier) do
      nil -> :ok
      notifier -> notifier.task_changed(record)
    end
  rescue
    exception ->
      Logger.error(
        "ConduitMcp.Ext.Tasks notifier raised " <>
          Exception.format_banner(:error, exception, __STACKTRACE__)
      )
  end

  defp rpc_error(code, message), do: %{"code" => code, "message" => message}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now, do: System.system_time(:millisecond)
end

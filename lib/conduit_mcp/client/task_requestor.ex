defmodule ConduitMcp.Client.TaskRequestor do
  @moduledoc false

  # The requestor side of server tasks, run in the calling process
  # (`ConduitMcp.Client.call_tool/4` with `task:`, `get_task/3`,
  # `await_task/3`, `cancel_task/3`).
  #
  # Modern (`io.modelcontextprotocol/tasks` extension): the extension is
  # declared in `clientCapabilities` only on requests that use it. The server
  # decides whether a `tools/call` becomes a task (`resultType: "task"`).
  # Awaiting polls `tasks/get` at the task's `pollIntervalMs`; an
  # `input_required` task's `inputRequests` are answered by the client's
  # handler (same capability gate and safety layer as MRTR, each key once)
  # and sent with `tasks/update`; `completed` carries the result, `failed`
  # the JSON-RPC error.
  #
  # Legacy (`2025-11-25`): the client decides. It task-augments
  # (`params.task`) only when the server declares
  # `tasks.requests.tools.call`, and then by the tool's
  # `execution.taskSupport`: `"required"` always (awaiting when no `task:`
  # was asked), `"optional"` when `task:` is given, never otherwise.
  # Awaiting polls `tasks/get` until the task leaves `working`, then reads
  # `tasks/result` (which blocks while the server asks for input through
  # ordinary server requests).
  #
  # Awaiting is bounded by the call's `:timeout`; when it passes, the task is
  # cancelled with `tasks/cancel`. The connection is asked to cancel it too if
  # the awaiting process dies (`ConduitMcp.Client.Connection.TaskWatch`).

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Input
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Task
  alias ConduitMcp.Client.ToolResult

  @extensions %{"io.modelcontextprotocol/tasks" => %{}}
  @default_poll_ms 1_000
  @min_poll_ms 25
  @control_timeout 5_000

  @type mode :: :return | :await | nil

  @doc "The extension capabilities to declare for a modern request with `task:` `mode`."
  @spec extensions(mode()) :: map()
  def extensions(nil), do: %{}
  def extensions(_mode), do: @extensions

  @doc """
  Whether a legacy `tools/call` of `name` must be task-augmented, and how to
  treat the task: `{:augment, :return | :await}` or `:plain`.
  """
  @spec legacy_plan(term(), map(), String.t(), mode(), keyword()) :: {:augment, mode()} | :plain
  def legacy_plan(client, view, name, mode, opts) do
    if server_supports?(view) do
      case {task_support(client, view, name, opts), mode} do
        {"required", nil} -> {:augment, :await}
        {"required", mode} -> {:augment, mode}
        {"optional", mode} when mode != nil -> {:augment, mode}
        _other -> :plain
      end
    else
      :plain
    end
  end

  defp server_supports?(%{server: %{capabilities: caps}}) when is_map(caps),
    do: match?(%{"tasks" => %{"requests" => %{"tools" => %{"call" => %{}}}}}, caps)

  defp server_supports?(_view), do: false

  # The tool's definition comes from the cache; a never-fetched list (or
  # one not cached for this credential, HT-11) is fetched once first.
  defp task_support(client, view, name, opts) do
    tool =
      if Cache.list(view.cache, :tools) == :miss do
        case ConduitMcp.Client.__list_all__(client, :tools, Keyword.take(opts, [:timeout])) do
          {:ok, tools} -> Enum.find(tools, &(&1.name == name))
          {:error, _} -> nil
        end
      else
        case Cache.lookup(view.cache, :tools, name) do
          {:ok, tool} -> tool
          _miss -> nil
        end
      end

    case tool do
      %{execution: %{"taskSupport" => support}} -> support
      _other -> nil
    end
  end

  @doc """
  A `tools/call` answered with a task (`raw` is the modern `CreateTaskResult`
  or the legacy `CreateTaskResult.task`): return it, or await its result.
  """
  @spec created(term(), map(), :modern | :legacy, term(), mode(), keyword()) ::
          {:ok, Task.t() | ToolResult.t()} | {:error, Error.t()}
  def created(client, view, era, raw, mode, opts) do
    with {:ok, task} <- Task.from_wire(view.server_id, era, raw) do
      case mode do
        :return -> {:ok, task}
        :await -> await(client, task, opts)
      end
    end
  end

  @doc "`ConduitMcp.Client.get_task/3`."
  @spec get(term(), Task.t() | String.t(), keyword()) :: {:ok, Task.t()} | {:error, Error.t()}
  def get(client, task, opts) do
    with {:ok, _pid, view} <- Request.lookup(client),
         {id, era} = identify(task, view),
         {:ok, result} <-
           Request.run(client, "tasks/get", %{"taskId" => id}, request_opts(era, opts)) do
      Task.from_wire(view.server_id, era, task_map(era, result))
    end
  end

  # Legacy `GetTaskResult` is the task itself; this library's own legacy
  # server wraps it as `{"task": ...}`.
  defp task_map(:legacy, %{"task" => %{} = task}), do: task
  defp task_map(_era, result), do: result

  @doc "`ConduitMcp.Client.cancel_task/3`."
  @spec cancel(term(), Task.t() | String.t(), keyword()) :: :ok | {:error, Error.t()}
  def cancel(client, task, opts) do
    with {:ok, _pid, view} <- Request.lookup(client),
         {id, era} = identify(task, view),
         {:ok, _ack} <-
           Request.run(client, "tasks/cancel", %{"taskId" => id}, request_opts(era, opts)),
         do: :ok
  end

  @doc "`ConduitMcp.Client.await_task/3`."
  @spec await(term(), Task.t() | String.t(), keyword()) ::
          {:ok, ToolResult.t()} | {:error, Error.t()}
  def await(client, task, opts) do
    with {:ok, _pid, view} <- Request.lookup(client),
         {:ok, task} <- seed(client, task, opts) do
      timeout = Keyword.get(opts, :timeout, view.request_timeout)
      state = %{deadline: now_ms() + timeout, answered: MapSet.new(), view: view, opts: opts}
      _ = Request.call(client, {:watch_task, self(), task.id}, @control_timeout)

      try do
        step(client, task, state)
      after
        _ = Request.call(client, {:unwatch_task, self(), task.id}, @control_timeout)
      end
    end
  end

  defp seed(_client, %Task{} = task, _opts), do: {:ok, task}

  defp seed(client, id, opts) when is_binary(id),
    do: get(client, id, Keyword.take(opts, [:timeout]))

  defp step(_client, %Task{status: :completed, era: :modern} = task, _state) do
    case task.result do
      %{} = result -> ToolResult.from_wire(result)
      nil -> {:error, Error.new(:protocol, :task_result_missing)}
    end
  end

  defp step(_client, %Task{status: :failed, era: :modern} = task, _state),
    do: {:error, Error.from_rpc_error(task.error)}

  defp step(_client, %Task{status: :cancelled}, _state),
    do: {:error, Error.new(:protocol, :task_cancelled)}

  defp step(client, %Task{status: status, era: :legacy} = task, state)
       when status in [:completed, :failed, :input_required] do
    with {:ok, timeout} <- remaining(client, task, state),
         {:ok, result} <-
           Request.run(client, "tasks/result", %{"taskId" => task.id}, timeout: timeout) do
      ToolResult.from_wire(result)
    end
  end

  defp step(client, %Task{status: :input_required, era: :modern} = task, state) do
    with {:ok, state} <- supply_input(client, task, state) do
      poll(client, task, state)
    end
  end

  defp step(client, task, state), do: poll(client, task, state)

  defp poll(client, task, state) do
    interval = max(task.poll_interval_ms || @default_poll_ms, @min_poll_ms)

    if now_ms() + interval >= state.deadline do
      expire(client, task)
    else
      Process.sleep(interval)

      with {:ok, timeout} <- remaining(client, task, state),
           {:ok, task} <- get(client, task, timeout: timeout) do
        step(client, task, state)
      end
    end
  end

  defp remaining(client, task, state) do
    case state.deadline - now_ms() do
      left when left > 0 -> {:ok, left}
      _gone -> expire(client, task)
    end
  end

  defp expire(client, task) do
    _ = cancel(client, task, timeout: @control_timeout)
    {:error, Error.new(:timeout, :task_deadline)}
  end

  # Each outstanding key is answered once: a later poll repeats keys the
  # server has not processed yet.
  defp supply_input(client, task, state) do
    requests =
      (task.input_requests || %{})
      |> Enum.reject(fn {key, _request} -> MapSet.member?(state.answered, key) end)
      |> Enum.sort()

    if requests == [] do
      {:ok, state}
    else
      env = Input.caller_env(client, state.view, Keyword.get(state.opts, :assigns))

      with {:ok, responses} <- answer_all(requests, state.view.client_capabilities, env),
           {:ok, timeout} <- remaining(client, task, state),
           {:ok, _ack} <-
             Request.run(
               client,
               "tasks/update",
               %{"taskId" => task.id, "inputResponses" => responses},
               request_opts(:modern, timeout: timeout)
             ) do
        {:ok, %{state | answered: MapSet.union(state.answered, MapSet.new(Map.keys(responses)))}}
      end
    end
  end

  defp answer_all(requests, capabilities, env) do
    Enum.reduce_while(requests, {:ok, %{}}, fn {key, request}, {:ok, acc} ->
      case Input.answer_input(key, request, capabilities, env) do
        {:ok, response} -> {:cont, {:ok, Map.put(acc, key, response)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp identify(%Task{id: id, era: era}, _view), do: {id, era}
  defp identify(id, view) when is_binary(id), do: {id, view.era || :legacy}

  defp request_opts(:modern, opts),
    do: opts |> Keyword.take([:timeout]) |> Keyword.put(:extensions, @extensions)

  defp request_opts(_legacy, opts), do: Keyword.take(opts, [:timeout])

  defp now_ms, do: System.monotonic_time(:millisecond)
end

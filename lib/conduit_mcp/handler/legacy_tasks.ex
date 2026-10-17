defmodule ConduitMcp.Handler.LegacyTasks do
  @moduledoc false

  # The legacy-era `tasks/*` methods. Returns neutral
  # `ConduitMcp.Handler.result/0` values.
  #
  # The routes are owner-scoped: the caller's principal is extracted from
  # `conn` (via `ConduitMcp.Tasks.owner/1`) and passed to the owner-aware
  # facade arities so a client can't read or cancel another principal's task.
  # When there is no principal (unauthenticated, or the 2-arg
  # `ConduitMcp.Handler.handle_request/2` path) the owner is `nil`. `nil` = no
  # principal: sees only unowned tasks; nothing under `:tasks_require_owner`
  # (see `ConduitMcp.Tasks.get/2`).

  alias ConduitMcp.Errors
  alias ConduitMcp.Handler

  @doc "`tasks/get`."
  @spec get(map(), module(), Plug.Conn.t()) :: Handler.result()
  def get(params, _server_module, conn) do
    case Map.get(params, "taskId") do
      nil ->
        missing_task_id()

      task_id ->
        case ConduitMcp.Tasks.get(task_id, ConduitMcp.Tasks.owner(conn)) do
          {:ok, task} -> {:ok, %{"task" => task}}
          {:error, :not_found} -> task_not_found(task_id)
        end
    end
  end

  @doc "`tasks/cancel`."
  @spec cancel(map(), module(), Plug.Conn.t()) :: Handler.result()
  def cancel(params, _server_module, conn) do
    case Map.get(params, "taskId") do
      nil ->
        missing_task_id()

      task_id ->
        case ConduitMcp.Tasks.cancel(task_id, ConduitMcp.Tasks.owner(conn)) do
          {:ok, task} -> {:ok, %{"task" => task}}
          {:error, :not_found} -> task_not_found(task_id)
        end
    end
  end

  @doc "`tasks/result`."
  @spec result(map(), module(), Plug.Conn.t()) :: Handler.result()
  def result(params, _server_module, conn) do
    case Map.get(params, "taskId") do
      nil ->
        missing_task_id()

      task_id ->
        case ConduitMcp.Tasks.get(task_id, ConduitMcp.Tasks.owner(conn)) do
          {:ok, task} -> task_result(task)
          {:error, :not_found} -> task_not_found(task_id)
        end
    end
  end

  defp task_result(task) do
    case Map.get(task, "status") do
      "completed" ->
        {:ok, Map.get(task, "result", %{})}

      "failed" ->
        {:ok, %{"error" => Map.get(task, "error")}}

      other ->
        {:error, Errors.task_not_ready(), "Task not finished (status: #{other})", nil}
    end
  end

  # `tasks/list` used to serialize the whole table into one response with no
  # client-visible bound at all. The client may now ask for a limit; the
  # server clamps it either way.
  @default_tasks_list_limit 100

  @doc "`tasks/list`."
  @spec list(map(), module(), Plug.Conn.t()) :: Handler.result()
  def list(params, _server_module, conn) do
    case tasks_list_opts(params) do
      {:ok, opts} ->
        tasks = ConduitMcp.Tasks.list(opts, ConduitMcp.Tasks.owner(conn))
        {:ok, %{"tasks" => tasks}}

      {:error, message} ->
        {:error, Errors.invalid_params(), message, nil}
    end
  end

  defp tasks_list_opts(params) do
    with {:ok, status} <- tasks_list_status(Map.get(params, "status")) do
      opts = [limit: tasks_list_limit(Map.get(params, "limit"))]
      {:ok, if(status, do: [{:status, status} | opts], else: opts)}
    end
  end

  defp tasks_list_status(nil), do: {:ok, nil}
  defp tasks_list_status(status) when is_binary(status), do: {:ok, status}
  defp tasks_list_status(_status), do: {:error, "status must be a string"}

  defp tasks_list_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, max_tasks_list_limit())
  end

  defp tasks_list_limit(_limit), do: max_tasks_list_limit()

  defp max_tasks_list_limit do
    Application.get_env(:conduit_mcp, :tasks_list_max_limit, @default_tasks_list_limit)
  end

  defp missing_task_id, do: {:error, Errors.invalid_params(), "Missing taskId", nil}

  defp task_not_found(task_id) do
    {:error, Errors.resource_not_found(), "Task not found: #{ConduitMcp.Reflect.text(task_id)}",
     nil}
  end
end

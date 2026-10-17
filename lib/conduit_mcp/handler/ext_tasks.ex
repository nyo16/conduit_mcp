defmodule ConduitMcp.Handler.ExtTasks do
  @moduledoc false

  # The `io.modelcontextprotocol/tasks` extension on the modern era: task
  # creation from a `tools/call` callback's `{:task, attrs}` (via
  # `ConduitMcp.Handler.MRTR`) and the `tasks/get`, `tasks/update` and
  # `tasks/cancel` routes of `ConduitMcp.Handler.Modern`. State lives in
  # `ConduitMcp.Ext.Tasks`; this module returns neutral results only.
  #
  # Every route requires the client to declare the extension on the request
  # (-32021 otherwise, per the extension's "Protocol Errors") and is scoped
  # to the request's principal: another principal's task is "Task not
  # found", exactly like a missing one. The task id is never echoed - it is
  # a bearer token.

  require Logger

  alias ConduitMcp.Ctx
  alias ConduitMcp.Errors
  alias ConduitMcp.Ext.Tasks
  alias ConduitMcp.Handler

  @doc """
  Turns a `tools/call` callback's `{:task, attrs}` into `{:task, task}`.
  """
  @spec start(Plug.Conn.t(), Ctx.t(), term(), String.t()) :: Handler.result()
  def start(conn, ctx, attrs, callback_name) do
    cond do
      not Tasks.enabled?() ->
        Logger.error(
          "#{callback_name} returned {:task, ...} but the tasks extension is disabled; " <>
            "set config :conduit_mcp, :ext_tasks, true"
        )

        internal_error()

      not declared?(ctx) ->
        missing_capability()

      true ->
        create(conn, attrs, callback_name)
    end
  end

  defp create(conn, attrs, callback_name) do
    case Tasks.create(ConduitMcp.Principal.id(conn), attrs) do
      {:ok, record} ->
        {:task, Tasks.to_task(record)}

      {:error, {:invalid_attrs, detail}} ->
        Logger.error(
          "#{callback_name} returned {:task, attrs} with invalid attrs " <>
            "(expected :ttl_ms, :poll_interval_ms, :status_message, :start): " <>
            ConduitMcp.Reflect.text(detail, 200)
        )

        internal_error()

      {:error, :task_limit_reached} ->
        {:error, Errors.internal_error(), "Task limit reached", nil}

      {:error, reason} ->
        Logger.error("Could not store task: #{ConduitMcp.Reflect.text(reason, 200)}")
        internal_error()
    end
  end

  @doc "`tasks/get`."
  @spec get(map(), Plug.Conn.t()) :: Handler.result()
  def get(params, conn) do
    with {:ok, task_id} <- checked(params, conn),
         {:ok, record} <- Tasks.get(task_id, ConduitMcp.Principal.id(conn)) do
      {:ok, Tasks.to_wire(record)}
    else
      error -> not_found(error)
    end
  end

  @doc "`tasks/update`."
  @spec update(map(), Plug.Conn.t()) :: Handler.result()
  def update(params, conn) do
    with {:ok, task_id} <- checked(params, conn),
         {:ok, responses} <- input_responses(params),
         :ok <- Tasks.answer(task_id, ConduitMcp.Principal.id(conn), responses) do
      {:ok, %{}}
    else
      error -> not_found(error)
    end
  end

  @doc "`tasks/cancel`."
  @spec cancel(map(), Plug.Conn.t()) :: Handler.result()
  def cancel(params, conn) do
    with {:ok, task_id} <- checked(params, conn),
         :ok <- Tasks.cancel(task_id, ConduitMcp.Principal.id(conn)) do
      {:ok, %{}}
    else
      error -> not_found(error)
    end
  end

  defp checked(params, conn) do
    cond do
      not declared?(Ctx.from_conn(conn)) -> missing_capability()
      is_binary(params["taskId"]) -> {:ok, params["taskId"]}
      true -> {:error, Errors.invalid_params(), "Missing taskId", nil}
    end
  end

  defp input_responses(%{"inputResponses" => responses}) when is_map(responses),
    do: {:ok, responses}

  defp input_responses(_params),
    do: {:error, Errors.invalid_params(), "inputResponses must be an object", nil}

  defp declared?(%Ctx{extensions: extensions}) when is_map(extensions),
    do: is_map_key(extensions, Tasks.extension())

  defp declared?(_ctx), do: false

  defp not_found({:error, :not_found}),
    do: {:error, Errors.invalid_params(), "Failed to retrieve task: Task not found", nil}

  defp not_found({:error, _code, _message, _data} = error), do: error

  defp missing_capability do
    {:error, Errors.missing_required_client_capability(), "Missing required client capability",
     %{"requiredCapabilities" => %{"extensions" => %{Tasks.extension() => %{}}}}}
  end

  defp internal_error, do: {:error, Errors.internal_error(), "Internal server error", nil}
end

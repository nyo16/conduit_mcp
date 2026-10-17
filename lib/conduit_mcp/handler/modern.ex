defmodule ConduitMcp.Handler.Modern do
  @moduledoc false

  # The modern (`2026-07-28`) protocol era: one routing table, no lifecycle.
  # Requests are already classified by `ConduitMcp.Era`; every neutral result
  # is shaped by `ConduitMcp.Protocol.Modern.to_response/4`. See
  # `ConduitMcp.Handler.dispatch/3` for the documented contract.
  #
  # Methods the legacy era routes but this one does not - `initialize`,
  # `ping`, `logging/setLevel`, `resources/subscribe|unsubscribe`, the legacy
  # `tasks/result|list` - fall through to -32601, which
  # `Protocol.Modern.http_status/1` maps to HTTP 404. `tasks/get`,
  # `tasks/update` and `tasks/cancel` are routed (to
  # `ConduitMcp.Handler.ExtTasks`) only while `ConduitMcp.Ext.Tasks` is
  # enabled. The modern HTTP transport defines no client-to-server
  # notifications, so a notification is dropped.
  #
  # Cacheable complete results get their `ttlMs`/`cacheScope` from
  # `ConduitMcp.CacheHints.resolve/4` (per-component hints, SV-9).

  require Logger

  alias ConduitMcp.Ctx
  alias ConduitMcp.Discover
  alias ConduitMcp.Era
  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Completion
  alias ConduitMcp.Handler.ExtTasks
  alias ConduitMcp.Handler.Pipeline
  alias ConduitMcp.Handler.Prompts
  alias ConduitMcp.Handler.Resources
  alias ConduitMcp.Handler.Tools
  alias ConduitMcp.Protocol

  # The one modern routing table; `ConduitMcp.Handler.methods/1` publishes it.
  @request_methods %{
    "server/discover" => :discover,
    "tools/list" => :list_tools,
    "tools/call" => :call_tool,
    "resources/list" => :list_resources,
    "resources/templates/list" => :list_resource_templates,
    "resources/read" => :read_resource,
    "prompts/list" => :list_prompts,
    "prompts/get" => :get_prompt,
    "completion/complete" => :complete
  }

  # The `io.modelcontextprotocol/tasks` extension's methods, routed only
  # while it is enabled.
  @task_methods %{
    "tasks/get" => :get_ext_task,
    "tasks/update" => :update_ext_task,
    "tasks/cancel" => :cancel_ext_task
  }

  @doc """
  Every method this era routes, mapped to its internal name (the tasks
  extension's only while `ConduitMcp.Ext.Tasks.enabled?/0`).
  """
  @spec methods() :: %{optional(String.t()) => atom()}
  def methods do
    if ConduitMcp.Ext.Tasks.enabled?(),
      do: Map.merge(@request_methods, @task_methods),
      else: @request_methods
  end

  @doc """
  Handles a modern-era message; see `ConduitMcp.Handler.dispatch/3`.
  """
  @spec dispatch(map(), module(), Ctx.t()) :: {:reply, map()} | :noreply
  def dispatch(request, server_module, %Ctx{era: :modern} = ctx) do
    conn = Ctx.put(ctx.conn, ctx)

    reply =
      Pipeline.instrument(request, server_module, ctx, fn ->
        cond do
          Protocol.valid_request?(request) ->
            handle_method(request, server_module, ctx, conn)

          Protocol.valid_notification?(request) ->
            Logger.debug("Dropping modern-era notification",
              method: ConduitMcp.Reflect.text(Map.get(request, "method"))
            )

            :ok

          true ->
            Protocol.error_response(
              Map.get(request, "id"),
              Protocol.invalid_request(),
              "Invalid JSON-RPC 2.0 request"
            )
        end
      end)

    case reply do
      :ok -> :noreply
      response -> {:reply, response}
    end
  end

  defp handle_method(request, server_module, ctx, conn) do
    method = Map.get(request, "method")
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    Logger.debug("Handling method", method: ConduitMcp.Reflect.text(method))

    result =
      with :ok <- Era.check_version(ctx),
           {:ok, route} <- fetch_route(method) do
        Pipeline.in_flight(conn, id, fn conn ->
          Pipeline.guard(method, id, fn -> route(route, params, server_module, conn) end)
        end)
      end

    Protocol.Modern.to_response(id, method, result,
      server_info: ctx.server_info,
      cache: cache(server_module, method, params, result)
    )
  end

  defp cache(server_module, method, params, {:ok, result}),
    do: ConduitMcp.CacheHints.resolve(server_module, method, params, result)

  defp cache(_server_module, _method, _params, _result), do: nil

  defp fetch_route(method) do
    case Map.fetch(methods(), method) do
      {:ok, route} ->
        {:ok, route}

      :error ->
        {:error, Errors.method_not_found(),
         "Method not found: #{ConduitMcp.Reflect.text(method)}", nil}
    end
  end

  @spec route(atom(), map(), module(), Plug.Conn.t()) :: Handler.result()
  defp route(:discover, _params, server_module, conn),
    do: {:ok, Discover.result(server_module, conn)}

  defp route(:list_tools, params, server_module, conn),
    do: Tools.list(params, server_module, conn)

  defp route(:call_tool, params, server_module, conn),
    do: Tools.call(params, server_module, conn)

  defp route(:list_resources, params, server_module, conn),
    do: Resources.list(params, server_module, conn)

  defp route(:list_resource_templates, params, server_module, conn),
    do: Resources.list_templates(params, server_module, conn)

  defp route(:read_resource, params, server_module, conn),
    do: Resources.read(params, server_module, conn)

  defp route(:list_prompts, params, server_module, conn),
    do: Prompts.list(params, server_module, conn)

  defp route(:get_prompt, params, server_module, conn),
    do: Prompts.get(params, server_module, conn)

  defp route(:complete, params, server_module, conn),
    do: Completion.complete(params, server_module, conn)

  defp route(:get_ext_task, params, _server_module, conn), do: ExtTasks.get(params, conn)
  defp route(:update_ext_task, params, _server_module, conn), do: ExtTasks.update(params, conn)
  defp route(:cancel_ext_task, params, _server_module, conn), do: ExtTasks.cancel(params, conn)
end

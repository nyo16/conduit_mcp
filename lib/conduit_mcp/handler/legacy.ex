defmodule ConduitMcp.Handler.Legacy do
  @moduledoc false

  # The legacy (`initialize`-negotiated) protocol era: request validation,
  # notifications, the routing tables, and the lifecycle/logging/subscription
  # methods only this era has. Every neutral result is shaped into a JSON-RPC
  # response by `ConduitMcp.Protocol.Legacy.to_response/2`. See
  # `ConduitMcp.Handler.handle_request/3` for the documented contract.

  require Logger

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Capabilities
  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Handler.Completion
  alias ConduitMcp.Handler.LegacyTasks
  alias ConduitMcp.Handler.Pipeline
  alias ConduitMcp.Handler.Prompts
  alias ConduitMcp.Handler.Resources
  alias ConduitMcp.Handler.Tools
  alias ConduitMcp.Protocol
  alias ConduitMcp.ServerMeta

  # The one routing table. `ConduitMcp.Protocol.methods/0` publishes exactly
  # this map, so the documented method list and the dispatcher cannot drift:
  # they are the same data. Previously `Protocol.methods/0` was a second,
  # hand-maintained copy that did not know about six routed methods.
  @request_methods %{
    # Lifecycle
    "initialize" => :initialize,
    "ping" => :ping,

    # Tools
    "tools/list" => :list_tools,
    "tools/call" => :call_tool,

    # Resources
    "resources/list" => :list_resources,
    "resources/templates/list" => :list_resource_templates,
    "resources/read" => :read_resource,
    "resources/subscribe" => :subscribe_resource,
    "resources/unsubscribe" => :unsubscribe_resource,

    # Prompts
    "prompts/list" => :list_prompts,
    "prompts/get" => :get_prompt,

    # Completion
    "completion/complete" => :complete,

    # Logging
    "logging/setLevel" => :set_log_level,

    # Tasks
    "tasks/get" => :get_task,
    "tasks/cancel" => :cancel_task,
    "tasks/result" => :task_result,
    "tasks/list" => :list_tasks
  }

  @notification_methods %{
    "notifications/initialized" => :initialized,
    "notifications/cancelled" => :cancelled
  }

  @doc """
  Every method this era routes, mapped to its internal name.
  """
  @spec methods() :: %{optional(String.t()) => atom()}
  def methods, do: Map.merge(@request_methods, @notification_methods)

  @doc """
  Handles a decoded JSON-RPC message; see `ConduitMcp.Handler.handle_request/3`.
  """
  @spec handle_request(map(), module(), Plug.Conn.t() | map()) :: map() | :ok
  def handle_request(request, server_module, conn) do
    Pipeline.instrument(request, server_module, fn ->
      cond do
        Protocol.valid_request?(request) ->
          handle_method(request, server_module, conn)

        Protocol.valid_notification?(request) ->
          handle_notification(request, server_module, conn)

        # This era sends the client no requests, so no response can be
        # awaited: an incoming one is accepted and dropped, like an unknown
        # notification. Replying to it would answer a reply.
        Protocol.valid_response?(request) ->
          Logger.debug("Ignoring JSON-RPC response",
            id: ConduitMcp.Reflect.text(request["id"], 64)
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
  end

  defp handle_method(request, server_module, conn) do
    method = Map.get(request, "method")
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    Logger.debug("Handling method", method: ConduitMcp.Reflect.text(method))

    result =
      Pipeline.in_flight(conn, id, fn conn ->
        Pipeline.guard(method, id, fn -> dispatch(method, params, server_module, conn) end)
      end)

    Protocol.Legacy.to_response(id, result)
  end

  defp dispatch(method, params, server_module, conn) do
    case Map.get(@request_methods, method) do
      nil ->
        {:error, Errors.method_not_found(),
         "Method not found: #{ConduitMcp.Reflect.text(method)}", nil}

      route ->
        route(route, params, server_module, conn)
    end
  end

  @spec route(atom(), map(), module(), Plug.Conn.t()) :: Handler.result()
  defp route(:initialize, params, server_module, conn),
    do: initialize(params, server_module, conn)

  defp route(:ping, _params, _server_module, _conn), do: {:ok, %{}}

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

  defp route(:subscribe_resource, params, server_module, conn),
    do: subscription(params, server_module, conn, :subscribe)

  defp route(:unsubscribe_resource, params, server_module, conn),
    do: subscription(params, server_module, conn, :unsubscribe)

  defp route(:list_prompts, params, server_module, conn),
    do: Prompts.list(params, server_module, conn)

  defp route(:get_prompt, params, server_module, conn),
    do: Prompts.get(params, server_module, conn)

  defp route(:complete, params, server_module, conn),
    do: Completion.complete(params, server_module, conn)

  defp route(:set_log_level, params, server_module, conn),
    do: set_log_level(params, server_module, conn)

  defp route(:get_task, params, server_module, conn),
    do: LegacyTasks.get(params, server_module, conn)

  defp route(:cancel_task, params, server_module, conn),
    do: LegacyTasks.cancel(params, server_module, conn)

  defp route(:task_result, params, server_module, conn),
    do: LegacyTasks.result(params, server_module, conn)

  defp route(:list_tasks, params, server_module, conn),
    do: LegacyTasks.list(params, server_module, conn)

  defp handle_notification(notification, _server_module, conn) do
    method = Map.get(notification, "method")
    Logger.debug("Handling notification", method: ConduitMcp.Reflect.text(method))

    # Routed off `@notification_methods` for the same reason requests are
    # routed off `@request_methods`: a hand-written `case` over string literals
    # is a second copy of the table, and adding an entry to the table without
    # touching the copy makes `Protocol.methods/0` advertise a method this
    # function logs as unknown and drops.
    case Map.get(@notification_methods, method) do
      :initialized ->
        Logger.info("Client initialized")
        :ok

      :cancelled ->
        handle_cancelled(notification, conn)

      nil ->
        Logger.warning("Unknown notification", method: ConduitMcp.Reflect.text(method))
        :ok
    end
  end

  # A notification carries no id, so a malformed one is answered with a
  # JSON-RPC error whose id is null. Returning :ok here turned a client mistake
  # into a 500: this path is outside `ConduitMcp.Handler.Pipeline.guard/3`'s
  # rescue, so a non-map `params` (`Map.get/2` raises BadMapError) or a
  # non-scalar requestId (the interpolation raised) escaped handle_request/3
  # entirely. A missing `params` is a well-formed notification with no
  # requestId, which is ignored.
  defp handle_cancelled(notification, conn) do
    case Map.get(notification, "params", %{}) do
      %{} = params ->
        cancel_request(params, conn)

      _ ->
        Protocol.error_response(
          nil,
          Protocol.invalid_params(),
          "notifications/cancelled requires a params object"
        )
    end
  end

  # Validation first, so a malformed id is reported whether or not anything
  # is in flight; then the in-flight gate, so a cancel naming no running
  # request writes no row. MCP lets a receiver ignore such a cancel, and
  # recording it let an unauthenticated client fill its quota with ids that
  # name nothing.
  defp cancel_request(params, conn) do
    request_id = Map.get(params, "requestId")
    scope = Cancellation.scope(conn)

    cond do
      is_nil(request_id) ->
        :ok

      not Cancellation.valid_request_id?(request_id) ->
        invalid_request_id_error()

      Cancellation.in_flight?(request_id, scope) ->
        request_id
        |> Cancellation.cancel(Map.get(params, "reason"), scope)
        |> cancel_result()

      true ->
        :ok
    end
  end

  defp cancel_result(:ok), do: :ok
  defp cancel_result({:error, :invalid_request_id}), do: invalid_request_id_error()

  defp cancel_result({:error, :cancellation_limit_reached}) do
    Logger.warning("cancellation quota reached for caller; dropping notifications/cancelled")

    # -32000, not -32603: a per-caller quota is a server-defined refusal,
    # not a fault in the server.
    Protocol.error_response(
      nil,
      Protocol.server_error(),
      "Too many outstanding cancellations; try again shortly."
    )
  end

  defp invalid_request_id_error do
    Protocol.error_response(
      nil,
      Protocol.invalid_params(),
      "notifications/cancelled requires a string or integer requestId " <>
        "(strings at most 256 bytes)"
    )
  end

  defp initialize(params, server_module, conn) do
    case Map.get(params, "protocolVersion") do
      version when is_binary(version) ->
        negotiate_and_initialize(version, params, server_module, conn)

      other ->
        # `protocolVersion: {}` used to make the interpolation below raise, and
        # the surrounding rescue turned a client mistake into a misleading
        # "Internal server error".
        {:error, Errors.invalid_params(),
         "protocolVersion must be a string, got: #{ConduitMcp.Reflect.text(other, 40)}", nil}
    end
  end

  defp negotiate_and_initialize(client_version, params, server_module, conn) do
    client_info = Map.get(params, "clientInfo", %{})

    Logger.info("Initializing connection with client", client_info: client_info)

    # Clamped and control-character-stripped: a 1 MB protocolVersion sits well
    # inside the transports' body limit and used to be reflected in full into
    # both the error message and the log line.
    safe_version = ConduitMcp.Reflect.text(client_version, 40)

    Logger.debug("Protocol version", version: safe_version)

    negotiated_version = Protocol.negotiate_version(client_version)

    if is_nil(negotiated_version) do
      Logger.warning(
        "Client requested unsupported protocol version: #{safe_version}. " <>
          "Supported: #{inspect(Protocol.supported_versions())}"
      )

      {:error, Errors.invalid_request(),
       "Unsupported protocol version: #{safe_version}. " <>
         "Supported versions: #{Enum.join(Protocol.supported_versions(), ", ")}", nil}
    else
      server_name =
        Map.get(conn.private, :server_name) || "conduit-mcp"

      server_version =
        Map.get(conn.private, :server_version) ||
          Application.spec(:conduit_mcp, :vsn) |> to_string()

      {:ok,
       %{
         "protocolVersion" => negotiated_version,
         "serverInfo" => %{
           "name" => server_name,
           "version" => server_version
         },
         "capabilities" => Capabilities.build(server_module)
       }}
    end
  end

  defp set_log_level(params, server_module, conn) do
    level = Map.get(params, "level")

    if ServerMeta.has?(server_module, :set_log_level) do
      Common.dispatch_callback(
        fn -> server_module.handle_set_log_level(conn, level) end,
        "handle_set_log_level"
      )
    else
      {:ok, %{}}
    end
  end

  # Subscribing to a resource delivers its change notifications, so it is
  # gated on the same scope as reading it. Without this, a caller lacking
  # `vault:read` could subscribe to a scoped `vault://` resource.
  defp subscription(params, server_module, conn, kind) do
    uri = Map.get(params, "uri")

    case Resources.authorize(uri, server_module, conn) do
      :ok ->
        dispatch_subscription(server_module, conn, kind, uri)

      {:error, :insufficient_scope, required} ->
        Common.insufficient_scope_error(required)

      {:error, :invalid_uri} ->
        Common.invalid_uri_error(uri)
    end
  end

  defp dispatch_subscription(server_module, conn, :subscribe, uri) do
    if ServerMeta.has?(server_module, :subscribe) do
      Common.dispatch_callback(
        fn -> server_module.handle_subscribe_resource(conn, uri) end,
        "handle_subscribe_resource"
      )
    else
      subscriptions_not_supported()
    end
  end

  defp dispatch_subscription(server_module, conn, :unsubscribe, uri) do
    if ServerMeta.has?(server_module, :unsubscribe) do
      Common.dispatch_callback(
        fn -> server_module.handle_unsubscribe_resource(conn, uri) end,
        "handle_unsubscribe_resource"
      )
    else
      subscriptions_not_supported()
    end
  end

  defp subscriptions_not_supported,
    do: {:error, Errors.method_not_found(), "Resource subscriptions not supported", nil}
end

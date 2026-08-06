defmodule ConduitMcp.Handler do
  @moduledoc """
  Routes JSON-RPC 2.0 MCP requests to a server module's behaviour callbacks.

  `handle_request/3` is the single entry point: transports decode the
  request body, hand the resulting map to this module, and serialize the
  returned map back out. The handler itself is stateless — it does not own
  the server module, the connection, or any process state. Each request
  is independent and can run concurrently in its own Bandit process.

  ## Routed methods

  - `initialize` — version negotiation and capability advertisement
  - `ping` — round-trip liveness check
  - `tools/list`, `tools/call`
  - `resources/list`, `resources/templates/list`, `resources/read`
  - `resources/subscribe`, `resources/unsubscribe`
  - `prompts/list`, `prompts/get`
  - `completion/complete`
  - `logging/setLevel`
  - `tasks/get`, `tasks/cancel`, `tasks/result`, `tasks/list`
  - `notifications/initialized`, `notifications/cancelled`

  Unknown methods return `-32601 Method not found`. Unknown notifications
  are logged and dropped (per JSON-RPC notification semantics).

  ## Capability detection

  When the server module defines `__capabilities__/0` (typically generated
  by `ConduitMcp.Endpoint`), it is consulted for the `initialize` reply.
  Otherwise the base `tools`/`resources`/`prompts` set is used.
  Capability flags for optional features (`completions`, `logging`,
  `resources.subscribe`) are overlaid at runtime based on which callbacks
  the server exports, via `ConduitMcp.ServerMeta`.

  ## Telemetry

  Emits these events:

  - `[:conduit_mcp, :request, :stop]` — every request, with
    `%{duration: <native>}` and metadata `%{method, server_module, status}`.
  - `[:conduit_mcp, :tool, :execute]` — per `tools/call`.
  - `[:conduit_mcp, :resource, :read]` — per `resources/read`.
  - `[:conduit_mcp, :prompt, :get]` — per `prompts/get`.
  - `[:conduit_mcp, :request, :cancelled]` — when
    `notifications/cancelled` is received.

  ## Cancellation

  The handler stashes the request id into `conn.assigns[:mcp_request_id]`
  before dispatch and uses `try/after` to clear any cancellation flag
  after the response is produced. Tools poll
  `ConduitMcp.Cancellation.cancelled?(conn)` for cooperative aborts.
  """

  require Logger
  alias ConduitMcp.Protocol
  alias ConduitMcp.ServerMeta

  @doc """
  Handles an MCP request and returns a JSON-RPC response.
  Emits telemetry events for monitoring and metrics.
  """
  def handle_request(request, server_module, conn \\ %Plug.Conn{}) do
    start_time = System.monotonic_time()

    result =
      cond do
        Protocol.valid_request?(request) ->
          handle_method(request, server_module, conn)

        Protocol.valid_notification?(request) ->
          handle_notification(request, server_module)
          :ok

        true ->
          Protocol.error_response(
            Map.get(request, "id"),
            Protocol.invalid_request(),
            "Invalid JSON-RPC 2.0 request"
          )
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :request, :stop],
      %{duration: duration},
      %{
        method: Map.get(request, "method"),
        server_module: server_module,
        status: if(match?(%{"error" => _}, result), do: :error, else: :ok)
      }
    )

    result
  end

  defp handle_method(request, server_module, conn) do
    method = Map.get(request, "method")
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})
    conn = Plug.Conn.assign(conn, :mcp_request_id, id)

    Logger.debug("Handling method", method: method)

    try do
      do_handle_method(method, id, params, server_module, conn)
    after
      ConduitMcp.Cancellation.clear(id)
    end
  end

  defp do_handle_method(method, id, params, server_module, conn) do
    case method do
      "initialize" ->
        handle_initialize(id, params, server_module, conn)

      "ping" ->
        Protocol.success_response(id, %{})

      "tools/list" ->
        dispatch_list(id, server_module, :handle_list_tools, conn, params)

      "tools/call" ->
        handle_tool_call(id, params, server_module, conn)

      "resources/list" ->
        dispatch_list(id, server_module, :handle_list_resources, conn, params)

      "resources/templates/list" ->
        handle_list_resource_templates(id, server_module, conn)

      "resources/read" ->
        handle_resource_read(id, params, server_module, conn)

      "prompts/list" ->
        dispatch_list(id, server_module, :handle_list_prompts, conn, params)

      "prompts/get" ->
        handle_prompt_get(id, params, server_module, conn)

      "completion/complete" ->
        handle_completion(id, params, server_module, conn)

      "logging/setLevel" ->
        handle_logging(id, params, server_module, conn)

      "resources/subscribe" ->
        handle_subscribe(id, params, server_module, conn)

      "resources/unsubscribe" ->
        handle_unsubscribe(id, params, server_module, conn)

      "tasks/get" ->
        handle_tasks_get(id, params, conn)

      "tasks/cancel" ->
        handle_tasks_cancel(id, params, conn)

      "tasks/result" ->
        handle_tasks_result(id, params, conn)

      "tasks/list" ->
        handle_tasks_list(id, params, conn)

      _ ->
        Protocol.error_response(
          id,
          Protocol.method_not_found(),
          "Method not found: #{String.slice(to_string(method), 0, 200)}"
        )
    end
  rescue
    error ->
      Logger.error("Error handling method",
        error: Exception.message(error),
        method: method,
        request_id: id
      )

      Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
  end

  defp handle_notification(notification, _server_module) do
    method = Map.get(notification, "method")
    Logger.debug("Handling notification", method: method)

    case method do
      "notifications/initialized" ->
        Logger.info("Client initialized")
        :ok

      "notifications/cancelled" ->
        params = Map.get(notification, "params", %{})
        request_id = Map.get(params, "requestId")
        reason = Map.get(params, "reason")
        ConduitMcp.Cancellation.cancel(request_id, reason)
        :ok

      _ ->
        Logger.warning("Unknown notification", method: method)
        :ok
    end
  end

  defp handle_initialize(id, params, server_module, conn) do
    client_version = Map.get(params, "protocolVersion")
    client_info = Map.get(params, "clientInfo", %{})
    _capabilities = Map.get(params, "capabilities", %{})

    Logger.info("Initializing connection with client", client_info: client_info)
    Logger.debug("Protocol version", version: client_version)

    negotiated_version = Protocol.negotiate_version(client_version)

    if is_nil(negotiated_version) do
      Logger.warning(
        "Client requested unsupported protocol version: #{client_version}. " <>
          "Supported: #{inspect(Protocol.supported_versions())}"
      )

      Protocol.error_response(
        id,
        Protocol.invalid_request(),
        "Unsupported protocol version: #{client_version}. " <>
          "Supported versions: #{Enum.join(Protocol.supported_versions(), ", ")}"
      )
    else
      server_name =
        Map.get(conn.private, :server_name) || "conduit-mcp"

      server_version =
        Map.get(conn.private, :server_version) ||
          Application.spec(:conduit_mcp, :vsn) |> to_string()

      capabilities = build_capabilities(server_module)

      result = %{
        "protocolVersion" => negotiated_version,
        "serverInfo" => %{
          "name" => server_name,
          "version" => server_version
        },
        "capabilities" => capabilities
      }

      Protocol.success_response(id, result)
    end
  end

  defp dispatch_list(id, server_module, callback_name, conn, params) do
    dispatch_callback(
      id,
      fn -> call_list_callback(server_module, callback_name, conn, params) end,
      Atom.to_string(callback_name)
    )
  end

  defp handle_tool_call(id, params, server_module, conn) do
    tool_name = Map.get(params, "name")
    tool_params = Map.get(params, "arguments", %{})
    start_time = System.monotonic_time()

    result =
      with :ok <- check_tool_scope(conn, server_module, tool_name),
           {:ok, validated_params} <-
             ConduitMcp.Validation.validate_tool_params(server_module, tool_name, tool_params) do
        dispatch_callback(
          id,
          fn -> server_module.handle_call_tool(conn, tool_name, validated_params) end,
          "handle_call_tool"
        )
        |> maybe_add_meta(params)
      else
        {:error, :insufficient_scope, required_scope} ->
          Protocol.error_response(
            id,
            ConduitMcp.Errors.server_error(),
            "Insufficient scope. Required: #{required_scope}"
          )

        {:error, validation_errors} ->
          Protocol.error_response(
            id,
            ConduitMcp.Errors.invalid_params(),
            "Parameter validation failed",
            %{"errors" => ConduitMcp.Validation.format_validation_errors(validation_errors)}
          )
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :tool, :execute],
      %{duration: duration},
      %{
        tool_name: tool_name,
        server_module: server_module,
        status: if(match?(%{"error" => _}, result), do: :error, else: :ok)
      }
    )

    result
  end

  defp handle_resource_read(id, params, server_module, conn) do
    uri = Map.get(params, "uri")
    start_time = System.monotonic_time()

    result =
      dispatch_callback(
        id,
        fn -> server_module.handle_read_resource(conn, uri) end,
        "handle_read_resource"
      )
      |> ensure_resource_uri(uri)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :resource, :read],
      %{duration: duration},
      %{
        uri: uri,
        server_module: server_module,
        status: if(Map.has_key?(result, "error"), do: :error, else: :ok)
      }
    )

    result
  end

  defp handle_prompt_get(id, params, server_module, conn) do
    prompt_name = Map.get(params, "name")
    prompt_args = Map.get(params, "arguments", %{})
    start_time = System.monotonic_time()

    result =
      case ConduitMcp.Validation.validate_prompt_args(server_module, prompt_name, prompt_args) do
        {:ok, validated_args} ->
          dispatch_callback(
            id,
            fn -> server_module.handle_get_prompt(conn, prompt_name, validated_args) end,
            "handle_get_prompt"
          )

        {:error, validation_errors} ->
          Protocol.error_response(
            id,
            ConduitMcp.Errors.invalid_params(),
            "Argument validation failed",
            %{"errors" => ConduitMcp.Validation.format_validation_errors(validation_errors)}
          )
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :prompt, :get],
      %{duration: duration},
      %{
        prompt_name: prompt_name,
        server_module: server_module,
        status: if(Map.has_key?(result, "error"), do: :error, else: :ok)
      }
    )

    result
  end

  # Checks if the tool requires an OAuth scope and if the request has it.
  # Returns :ok if no scope required or scope is present.
  # Returns {:error, error_response} if scope is missing.
  defp check_tool_scope(conn, server_module, tool_name) do
    required_scope = get_required_scope(server_module, tool_name)
    verify_scope(conn, required_scope)
  end

  defp get_required_scope(server_module, tool_name) do
    if ServerMeta.has?(server_module, :scope_for_tool) do
      server_module.__scope_for_tool__(tool_name)
    else
      nil
    end
  end

  defp verify_scope(_conn, nil), do: :ok

  defp verify_scope(conn, required_scope) do
    token_scopes = Map.get(conn.assigns, :oauth_scopes, [])
    required = String.split(required_scope, " ", trim: true)

    if Enum.all?(required, &(&1 in token_scopes)) do
      :ok
    else
      {:error, :insufficient_scope, required_scope}
    end
  end

  defp handle_list_resource_templates(id, server_module, conn) do
    if ServerMeta.has?(server_module, :list_resource_templates) do
      dispatch_callback(
        id,
        fn -> server_module.handle_list_resource_templates(conn) end,
        "handle_list_resource_templates"
      )
    else
      Protocol.success_response(id, %{"resourceTemplates" => []})
    end
  end

  defp handle_completion(id, params, server_module, conn) do
    ref = Map.get(params, "ref", %{})
    argument = Map.get(params, "argument", %{})

    case validate_completion_ref(ref) do
      :ok ->
        if ServerMeta.has?(server_module, :complete) do
          dispatch_callback(
            id,
            fn -> server_module.handle_complete(conn, ref, argument) end,
            "handle_complete"
          )
        else
          Protocol.success_response(id, %{
            "completion" => %{"values" => [], "total" => 0, "hasMore" => false}
          })
        end

      {:error, message} ->
        Protocol.error_response(id, ConduitMcp.Errors.invalid_params(), message)
    end
  end

  defp validate_completion_ref(%{"type" => "ref/prompt", "name" => name}) when is_binary(name),
    do: :ok

  defp validate_completion_ref(%{"type" => "ref/resource", "uri" => uri}) when is_binary(uri),
    do: :ok

  defp validate_completion_ref(%{"type" => type}) when type in ["ref/prompt", "ref/resource"] do
    {:error, "Invalid completion ref: missing #{ref_required_field(type)}"}
  end

  defp validate_completion_ref(%{"type" => type}) do
    {:error, ~s(Invalid completion ref type "#{type}"; expected "ref/prompt" or "ref/resource")}
  end

  defp validate_completion_ref(_),
    do: {:error, "Invalid completion ref: missing type"}

  defp ref_required_field("ref/prompt"), do: "name"
  defp ref_required_field("ref/resource"), do: "uri"

  defp handle_logging(id, params, server_module, conn) do
    level = Map.get(params, "level")

    if ServerMeta.has?(server_module, :set_log_level) do
      dispatch_callback(
        id,
        fn -> server_module.handle_set_log_level(conn, level) end,
        "handle_set_log_level"
      )
    else
      Protocol.success_response(id, %{})
    end
  end

  defp handle_subscribe(id, params, server_module, conn) do
    uri = Map.get(params, "uri")

    if ServerMeta.has?(server_module, :subscribe) do
      dispatch_callback(
        id,
        fn -> server_module.handle_subscribe_resource(conn, uri) end,
        "handle_subscribe_resource"
      )
    else
      Protocol.error_response(
        id,
        Protocol.method_not_found(),
        "Resource subscriptions not supported"
      )
    end
  end

  defp handle_unsubscribe(id, params, server_module, conn) do
    uri = Map.get(params, "uri")

    if ServerMeta.has?(server_module, :unsubscribe) do
      dispatch_callback(
        id,
        fn -> server_module.handle_unsubscribe_resource(conn, uri) end,
        "handle_unsubscribe_resource"
      )
    else
      Protocol.error_response(
        id,
        Protocol.method_not_found(),
        "Resource subscriptions not supported"
      )
    end
  end

  # The `tasks/*` routes are owner-scoped: the caller's principal is extracted
  # from `conn` (via `ConduitMcp.Tasks.owner/1`) and passed to the owner-aware
  # facade arities so a client can't read or cancel another principal's task.
  # When there is no principal (unauthenticated, or the 2-arg
  # `handle_request/2` path) scoping is a no-op — see `ConduitMcp.Tasks`.
  defp handle_tasks_get(id, params, conn) do
    case Map.get(params, "taskId") do
      nil ->
        Protocol.error_response(id, Protocol.invalid_params(), "Missing taskId")

      task_id ->
        case ConduitMcp.Tasks.get(task_id, ConduitMcp.Tasks.owner(conn)) do
          {:ok, task} -> Protocol.success_response(id, %{"task" => task})
          {:error, :not_found} -> task_not_found(id, task_id)
        end
    end
  end

  defp handle_tasks_cancel(id, params, conn) do
    case Map.get(params, "taskId") do
      nil ->
        Protocol.error_response(id, Protocol.invalid_params(), "Missing taskId")

      task_id ->
        case ConduitMcp.Tasks.cancel(task_id, ConduitMcp.Tasks.owner(conn)) do
          {:ok, task} -> Protocol.success_response(id, %{"task" => task})
          {:error, :not_found} -> task_not_found(id, task_id)
        end
    end
  end

  defp handle_tasks_result(id, params, conn) do
    case Map.get(params, "taskId") do
      nil ->
        Protocol.error_response(id, Protocol.invalid_params(), "Missing taskId")

      task_id ->
        case ConduitMcp.Tasks.get(task_id, ConduitMcp.Tasks.owner(conn)) do
          {:ok, task} ->
            case Map.get(task, "status") do
              "completed" ->
                Protocol.success_response(id, Map.get(task, "result", %{}))

              "failed" ->
                Protocol.success_response(id, %{"error" => Map.get(task, "error")})

              other ->
                Protocol.error_response(
                  id,
                  ConduitMcp.Errors.task_not_ready(),
                  "Task not finished (status: #{other})"
                )
            end

          {:error, :not_found} ->
            task_not_found(id, task_id)
        end
    end
  end

  defp handle_tasks_list(id, params, conn) do
    opts = if status = Map.get(params, "status"), do: [status: status], else: []
    tasks = ConduitMcp.Tasks.list(opts, ConduitMcp.Tasks.owner(conn))
    Protocol.success_response(id, %{"tasks" => tasks})
  end

  defp task_not_found(id, task_id) do
    Protocol.error_response(
      id,
      ConduitMcp.Errors.resource_not_found(),
      "Task not found: #{task_id}"
    )
  end

  defp dispatch_callback(id, callback_fn, callback_name) do
    case callback_fn.() do
      {:ok, result} when is_map(result) ->
        Protocol.success_response(id, result)

      {:error, error} ->
        Protocol.error_response(
          id,
          error["code"] || ConduitMcp.Errors.server_error(),
          error["message"] || "#{callback_name} failed"
        )

      other ->
        Logger.error("Unexpected result from #{callback_name}: #{inspect(other)}")
        Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
    end
  end

  # Adds the request's _meta to the response result when present.
  #
  # Only success responses carry a "result" key. Error responses
  # (%{"error" => ...}) have no "result", so we must not try to write into
  # ["result", "_meta"] there — doing so raises "could not put/update key on a
  # nil value", which the caller would mask as a generic "Internal server
  # error". Clients commonly send a _meta (e.g. a progressToken) on every
  # tools/call, so this path is hit whenever a tool returns an error.
  defp maybe_add_meta(response, params) do
    case Map.get(params, "_meta") do
      meta when is_map(meta) and is_map_key(response, "result") ->
        put_in(response, ["result", "_meta"], meta)

      _ ->
        response
    end
  end

  # Calls a list callback, preferring the arity-2 variant (with params for pagination).
  # Falls back to arity-1 if arity-2 is not implemented.
  defp call_list_callback(server_module, callback_name, conn, params) do
    meta_key =
      case callback_name do
        :handle_list_tools -> :list_tools_2
        :handle_list_resources -> :list_resources_2
        :handle_list_prompts -> :list_prompts_2
      end

    if ServerMeta.has?(server_module, meta_key) do
      apply(server_module, callback_name, [conn, params])
    else
      apply(server_module, callback_name, [conn])
    end
  end

  # Ensures each item in a resource read response includes the "uri" field.
  # The MCP spec requires "uri" in every content item but resource handlers
  # often omit it since they don't know the request URI.
  defp ensure_resource_uri(%{"result" => %{"contents" => contents}} = response, uri)
       when is_list(contents) do
    updated =
      Enum.map(contents, fn item ->
        Map.put_new(item, "uri", uri)
      end)

    put_in(response, ["result", "contents"], updated)
  end

  defp ensure_resource_uri(response, _uri), do: response

  defp build_capabilities(server_module) do
    base =
      if ServerMeta.has?(server_module, :capabilities) do
        server_module.__capabilities__()
      else
        %{
          "tools" => %{"listChanged" => false},
          "resources" => %{"listChanged" => false},
          "prompts" => %{"listChanged" => false}
        }
      end

    base
    |> maybe_put_subscribe(server_module)
    |> maybe_put_completions(server_module)
    |> maybe_put_logging(server_module)
  end

  defp maybe_put_subscribe(caps, server_module) do
    if ServerMeta.has?(server_module, :subscribe) and Map.has_key?(caps, "resources") do
      Map.update!(caps, "resources", &Map.put(&1, "subscribe", true))
    else
      caps
    end
  end

  defp maybe_put_completions(caps, server_module) do
    if ServerMeta.has?(server_module, :complete) do
      Map.put(caps, "completions", %{})
    else
      caps
    end
  end

  defp maybe_put_logging(caps, server_module) do
    if ServerMeta.has?(server_module, :set_log_level) do
      Map.put(caps, "logging", %{})
    else
      caps
    end
  end
end

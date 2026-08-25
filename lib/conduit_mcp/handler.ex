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

  Unknown methods return `-32601 Method not found`. Unknown notifications are
  logged and dropped (per JSON-RPC notification semantics) — but a *known*
  notification that is malformed is answered with an error whose `id` is
  `null`, rather than dropped. See `handle_request/3`.

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

  Returns a response map for a request, and `:ok` for a notification that was
  handled or ignored.

  The one exception: a `notifications/cancelled` carrying a `requestId` that is
  not a string or an integer returns an **error map with `"id" => nil`**. A
  notification has no id to correlate, so JSON-RPC says drop it — but silently
  dropping it meant `to_string(%{})` raised out of the un-rescued notification
  path and the transport answered 500. Reporting the client's own malformed
  request back to it is the lesser deviation. A transport that pattern-matches
  `:ok` for every notification must handle the map too; both of ours do, via
  `ConduitMcp.Transport.Shared.dispatch_post/2`.
  """
  # `Plug.Conn.t() | map()`, not `Plug.Conn.t()`: the default is a bare
  # `%Plug.Conn{}`, whose `:owner` is `nil` where `t()` declares `pid()`. Real
  # callers pass an adapter-built conn; the default exists for direct calls.
  @spec handle_request(map(), module(), Plug.Conn.t() | map()) :: map() | :ok
  def handle_request(request, server_module, conn \\ %Plug.Conn{}) do
    start_time = System.monotonic_time()

    result =
      cond do
        Protocol.valid_request?(request) ->
          handle_method(request, server_module, conn)

        Protocol.valid_notification?(request) ->
          handle_notification(request, server_module, conn)

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

    Logger.debug("Handling method", method: ConduitMcp.Reflect.text(method))

    try do
      do_handle_method(method, id, params, server_module, conn)
    after
      ConduitMcp.Cancellation.clear(id, ConduitMcp.Cancellation.scope(conn))
    end
  end

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
  Every method this handler routes, mapped to its internal name.

  Published as `ConduitMcp.Protocol.methods/0`.
  """
  @spec methods() :: %{optional(String.t()) => atom()}
  def methods, do: Map.merge(@request_methods, @notification_methods)

  defp do_handle_method(method, id, params, server_module, conn) do
    case Map.get(@request_methods, method) do
      nil ->
        Protocol.error_response(
          id,
          Protocol.method_not_found(),
          "Method not found: #{ConduitMcp.Reflect.text(method)}"
        )

      route ->
        route(route, id, params, server_module, conn)
    end
  rescue
    error ->
      Logger.error("Error handling method",
        error: Exception.message(error),
        method: ConduitMcp.Reflect.text(method),
        request_id: id
      )

      Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
  end

  defp route(:initialize, id, params, server_module, conn),
    do: handle_initialize(id, params, server_module, conn)

  defp route(:ping, id, _params, _server_module, _conn),
    do: Protocol.success_response(id, %{})

  defp route(:list_tools, id, params, server_module, conn),
    do: dispatch_list(id, server_module, :handle_list_tools, conn, params)

  defp route(:call_tool, id, params, server_module, conn),
    do: handle_tool_call(id, params, server_module, conn)

  defp route(:list_resources, id, params, server_module, conn),
    do: dispatch_list(id, server_module, :handle_list_resources, conn, params)

  defp route(:list_resource_templates, id, _params, server_module, conn),
    do: handle_list_resource_templates(id, server_module, conn)

  defp route(:read_resource, id, params, server_module, conn),
    do: handle_resource_read(id, params, server_module, conn)

  defp route(:subscribe_resource, id, params, server_module, conn),
    do: handle_subscribe(id, params, server_module, conn)

  defp route(:unsubscribe_resource, id, params, server_module, conn),
    do: handle_unsubscribe(id, params, server_module, conn)

  defp route(:list_prompts, id, params, server_module, conn),
    do: dispatch_list(id, server_module, :handle_list_prompts, conn, params)

  defp route(:get_prompt, id, params, server_module, conn),
    do: handle_prompt_get(id, params, server_module, conn)

  defp route(:complete, id, params, server_module, conn),
    do: handle_completion(id, params, server_module, conn)

  defp route(:set_log_level, id, params, server_module, conn),
    do: handle_logging(id, params, server_module, conn)

  defp route(:get_task, id, params, _server_module, conn),
    do: handle_tasks_get(id, params, conn)

  defp route(:cancel_task, id, params, _server_module, conn),
    do: handle_tasks_cancel(id, params, conn)

  defp route(:task_result, id, params, _server_module, conn),
    do: handle_tasks_result(id, params, conn)

  defp route(:list_tasks, id, params, _server_module, conn),
    do: handle_tasks_list(id, params, conn)

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
  # JSON-RPC error whose id is null. Returning :ok here (and letting the
  # interpolation raise on a non-scalar requestId) turned a client mistake
  # into a 500.
  defp handle_cancelled(notification, conn) do
    params = Map.get(notification, "params", %{})
    request_id = Map.get(params, "requestId")
    reason = Map.get(params, "reason")

    case ConduitMcp.Cancellation.cancel(
           request_id,
           reason,
           ConduitMcp.Cancellation.scope(conn)
         ) do
      :ok ->
        :ok

      {:error, :invalid_request_id} ->
        Protocol.error_response(
          nil,
          Protocol.invalid_params(),
          "notifications/cancelled requires a string or integer requestId"
        )

      {:error, :cancellation_limit_reached} ->
        Logger.warning("cancellation table at capacity; dropping notifications/cancelled")

        Protocol.error_response(
          nil,
          Protocol.internal_error(),
          "Too many outstanding cancellations; try again shortly."
        )
    end
  end

  defp handle_initialize(id, params, server_module, conn) do
    case Map.get(params, "protocolVersion") do
      version when is_binary(version) ->
        negotiate_and_initialize(id, version, params, server_module, conn)

      other ->
        # `protocolVersion: {}` used to make the interpolation below raise, and
        # the surrounding rescue turned a client mistake into a misleading
        # "Internal server error".
        Protocol.error_response(
          id,
          Protocol.invalid_params(),
          "protocolVersion must be a string, got: #{ConduitMcp.Reflect.text(other, 40)}"
        )
    end
  end

  defp negotiate_and_initialize(id, client_version, params, server_module, conn) do
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

      Protocol.error_response(
        id,
        Protocol.invalid_request(),
        "Unsupported protocol version: #{safe_version}. " <>
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
        {:error, :tool_not_found} ->
          unknown_target_error(id, "tool", tool_name)

        {:error, :insufficient_scope, required_scope} ->
          insufficient_scope_error(id, required_scope)

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
      case verify_scope(conn, required_scope(server_module, :scope_for_resource, uri)) do
        :ok ->
          dispatch_callback(
            id,
            fn -> server_module.handle_read_resource(conn, uri) end,
            "handle_read_resource"
          )
          |> ensure_resource_uri(uri)

        {:error, :insufficient_scope, required} ->
          insufficient_scope_error(id, required)
      end

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
      with :ok <-
             verify_scope(conn, required_scope(server_module, :scope_for_prompt, prompt_name)),
           {:ok, validated_args} <-
             ConduitMcp.Validation.validate_prompt_args(server_module, prompt_name, prompt_args) do
        dispatch_callback(
          id,
          fn -> server_module.handle_get_prompt(conn, prompt_name, validated_args) end,
          "handle_get_prompt"
        )
      else
        {:error, :prompt_not_found} ->
          unknown_target_error(id, "prompt", prompt_name)

        {:error, :insufficient_scope, required} ->
          insufficient_scope_error(id, required)

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

  # One source of "you asked for something that doesn't exist" for tools and
  # prompts, so the three authoring modes cannot disagree. `-32602` is what the
  # MCP specification prescribes ("Unknown tool: invalid_tool_name"); the name
  # is echoed through `ConduitMcp.Reflect` because it is client input.
  defp unknown_target_error(id, kind, name) do
    Protocol.error_response(
      id,
      ConduitMcp.Errors.invalid_params(),
      "Unknown #{kind}: #{ConduitMcp.Reflect.text(name)}"
    )
  end

  # Every scoped surface — tools, resources and prompts — is authorized the
  # same way: look up the declared scope, then check it against the principal's
  # granted scopes. An unauthenticated request has no scopes, so a scoped
  # surface fails closed.
  defp check_tool_scope(conn, server_module, tool_name) do
    verify_scope(conn, required_scope(server_module, :scope_for_tool, tool_name))
  end

  defp required_scope(server_module, capability, key) do
    if ServerMeta.has?(server_module, capability) do
      apply_scope_lookup(server_module, capability, key)
    else
      nil
    end
  end

  defp apply_scope_lookup(server_module, :scope_for_tool, key),
    do: server_module.__scope_for_tool__(key)

  defp apply_scope_lookup(server_module, :scope_for_prompt, key),
    do: server_module.__scope_for_prompt__(key)

  defp apply_scope_lookup(server_module, :scope_for_resource, key),
    do: server_module.__scope_for_resource__(key)

  defp insufficient_scope_error(id, required_scope) do
    Protocol.error_response(
      id,
      ConduitMcp.Errors.server_error(),
      "Insufficient scope. Required: #{required_scope}"
    )
  end

  defp verify_scope(_conn, nil), do: :ok

  defp verify_scope(conn, required_scope) do
    token_scopes = ConduitMcp.Principal.scopes(conn)
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

    with :ok <- validate_completion_ref(ref),
         :ok <- verify_scope(conn, completion_scope(server_module, ref)) do
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
    else
      {:error, :insufficient_scope, required} ->
        insufficient_scope_error(id, required)

      {:error, message} ->
        Protocol.error_response(id, ConduitMcp.Errors.invalid_params(), message)
    end
  end

  # Completions are declared inside the same `resource`/`prompt` block as
  # `scope`, so enumerating them is reading part of that surface. Without this,
  # a caller lacking `vault:read` could still enumerate a scoped resource's
  # argument values.
  defp completion_scope(server_module, %{"type" => "ref/resource", "uri" => uri}),
    do: required_scope(server_module, :scope_for_resource, uri)

  defp completion_scope(server_module, %{"type" => "ref/prompt", "name" => name}),
    do: required_scope(server_module, :scope_for_prompt, name)

  defp completion_scope(_server_module, _ref), do: nil

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
    subscription(id, params, server_module, conn, :subscribe)
  end

  defp handle_unsubscribe(id, params, server_module, conn) do
    subscription(id, params, server_module, conn, :unsubscribe)
  end

  # Subscribing to a resource delivers its change notifications, so it is
  # gated on the same scope as reading it. Without this, a caller lacking
  # `vault:read` could subscribe to a scoped `vault://` resource.
  defp subscription(id, params, server_module, conn, kind) do
    uri = Map.get(params, "uri")

    case verify_scope(conn, required_scope(server_module, :scope_for_resource, uri)) do
      :ok ->
        dispatch_subscription(id, server_module, conn, kind, uri)

      {:error, :insufficient_scope, required} ->
        insufficient_scope_error(id, required)
    end
  end

  defp dispatch_subscription(id, server_module, conn, :subscribe, uri) do
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

  defp dispatch_subscription(id, server_module, conn, :unsubscribe, uri) do
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

  # `tasks/list` used to serialize the whole table into one response with no
  # client-visible bound at all. The client may now ask for a limit; the
  # server clamps it either way.
  @default_tasks_list_limit 100

  defp handle_tasks_list(id, params, conn) do
    case tasks_list_opts(params) do
      {:ok, opts} ->
        tasks = ConduitMcp.Tasks.list(opts, ConduitMcp.Tasks.owner(conn))
        Protocol.success_response(id, %{"tasks" => tasks})

      {:error, message} ->
        Protocol.error_response(id, Protocol.invalid_params(), message)
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

  defp task_not_found(id, task_id) do
    Protocol.error_response(
      id,
      ConduitMcp.Errors.resource_not_found(),
      "Task not found: #{ConduitMcp.Reflect.text(task_id)}"
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

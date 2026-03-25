defmodule ConduitMcp.Handler do
  @moduledoc """
  Handles MCP protocol requests and routes them to the appropriate server callbacks.
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
        status: if(is_map(result) && Map.has_key?(result, "error"), do: :error, else: :ok)
      }
    )

    result
  end

  defp handle_method(request, server_module, conn) do
    method = Map.get(request, "method")
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    Logger.debug("Handling method: #{method}")

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

      _ ->
        Protocol.error_response(id, Protocol.method_not_found(), "Method not found: #{method}")
    end
  rescue
    error ->
      Logger.error("Error handling method: #{inspect(error)}")

      Protocol.error_response(
        Map.get(request, "id"),
        Protocol.internal_error(),
        "Internal server error: #{inspect(error)}"
      )
  end

  defp handle_notification(notification, _server_module) do
    method = Map.get(notification, "method")
    Logger.debug("Handling notification: #{method}")

    case method do
      "notifications/initialized" ->
        Logger.info("Client initialized")
        :ok

      _ ->
        Logger.warning("Unknown notification: #{method}")
        :ok
    end
  end

  defp handle_initialize(id, params, server_module, conn) do
    client_version = Map.get(params, "protocolVersion")
    client_info = Map.get(params, "clientInfo", %{})
    _capabilities = Map.get(params, "capabilities", %{})

    Logger.info("Initializing connection with client: #{inspect(client_info)}")
    Logger.debug("Protocol version: #{client_version}")

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
        {:error, %{"error" => _} = scope_error} ->
          scope_error

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
        status: if(is_map(result) and Map.has_key?(result, "error"), do: :error, else: :ok)
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
      {:error,
       Protocol.error_response(
         nil,
         ConduitMcp.Errors.server_error(),
         "Insufficient scope. Required: #{required_scope}"
       )}
    end
  end

  defp handle_completion(id, params, server_module, conn) do
    ref = Map.get(params, "ref", %{})
    argument = Map.get(params, "argument", %{})

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
  end

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

  # Adds _meta field from request params to the response result if present.
  defp maybe_add_meta(response, params) do
    case Map.get(params, "_meta") do
      nil -> response
      meta when is_map(meta) -> put_in(response, ["result", "_meta"], meta)
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
    if ServerMeta.has?(server_module, :capabilities) do
      server_module.__capabilities__()
    else
      # DSL and manual mode servers always define all 6 callbacks,
      # so we advertise all capabilities by default.
      %{
        "tools" => %{"listChanged" => false},
        "resources" => %{"listChanged" => false},
        "prompts" => %{"listChanged" => false}
      }
    end
  end
end

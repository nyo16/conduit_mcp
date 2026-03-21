defmodule ConduitMcp.Handler do
  @moduledoc """
  Handles MCP protocol requests and routes them to the appropriate server callbacks.
  """

  require Logger
  alias ConduitMcp.Protocol

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
        list_result = call_list_callback(server_module, :handle_list_tools, conn, params)

        case list_result do
          {:ok, result} when is_map(result) ->
            Protocol.success_response(id, result)

          {:error, error} ->
            Protocol.error_response(
              id,
              error["code"] || -32000,
              error["message"] || "Failed to list tools"
            )

          other ->
            Logger.error("Unexpected result from handle_list_tools: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "tools/call" ->
        tool_name = Map.get(params, "name")
        tool_params = Map.get(params, "arguments", %{})

        start_time = System.monotonic_time()

        result =
          case ConduitMcp.Validation.validate_tool_params(server_module, tool_name, tool_params) do
            {:ok, validated_params} ->
              case server_module.handle_call_tool(conn, tool_name, validated_params) do
                {:ok, tool_result} when is_map(tool_result) ->
                  Protocol.success_response(id, tool_result)
                  |> maybe_add_meta(params)

                {:error, error} ->
                  Protocol.error_response(
                    id,
                    error["code"] || -32000,
                    error["message"] || "Tool execution failed"
                  )

                other ->
                  Logger.error("Unexpected result from handle_call_tool: #{inspect(other)}")
                  Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
              end

            {:error, validation_errors} ->
              Protocol.error_response(
                id,
                -32602,
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
            status: if(Map.has_key?(result, "error"), do: :error, else: :ok)
          }
        )

        result

      "resources/list" ->
        list_result = call_list_callback(server_module, :handle_list_resources, conn, params)

        case list_result do
          {:ok, result} when is_map(result) ->
            Protocol.success_response(id, result)

          {:error, error} ->
            Protocol.error_response(
              id,
              error["code"] || -32000,
              error["message"] || "Failed to list resources"
            )

          other ->
            Logger.error("Unexpected result from handle_list_resources: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "resources/read" ->
        uri = Map.get(params, "uri")

        start_time = System.monotonic_time()

        result =
          case server_module.handle_read_resource(conn, uri) do
            {:ok, resource_result} when is_map(resource_result) ->
              Protocol.success_response(id, resource_result)

            {:error, error} ->
              Protocol.error_response(
                id,
                error["code"] || -32000,
                error["message"] || "Resource read failed"
              )

            other ->
              Logger.error("Unexpected result from handle_read_resource: #{inspect(other)}")
              Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
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

      "prompts/list" ->
        list_result = call_list_callback(server_module, :handle_list_prompts, conn, params)

        case list_result do
          {:ok, result} when is_map(result) ->
            Protocol.success_response(id, result)

          {:error, error} ->
            Protocol.error_response(
              id,
              error["code"] || -32000,
              error["message"] || "Failed to list prompts"
            )

          other ->
            Logger.error("Unexpected result from handle_list_prompts: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "prompts/get" ->
        prompt_name = Map.get(params, "name")
        prompt_args = Map.get(params, "arguments", %{})

        start_time = System.monotonic_time()

        result =
          case ConduitMcp.Validation.validate_prompt_args(server_module, prompt_name, prompt_args) do
            {:ok, validated_args} ->
              case server_module.handle_get_prompt(conn, prompt_name, validated_args) do
                {:ok, prompt_result} when is_map(prompt_result) ->
                  Protocol.success_response(id, prompt_result)

                {:error, error} ->
                  Protocol.error_response(
                    id,
                    error["code"] || -32000,
                    error["message"] || "Prompt get failed"
                  )

                other ->
                  Logger.error("Unexpected result from handle_get_prompt: #{inspect(other)}")
                  Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
              end

            {:error, validation_errors} ->
              Protocol.error_response(
                id,
                -32602,
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

  defp handle_completion(id, params, server_module, conn) do
    ref = Map.get(params, "ref", %{})
    argument = Map.get(params, "argument", %{})

    if function_exported?(server_module, :handle_complete, 3) do
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

    if function_exported?(server_module, :handle_set_log_level, 2) do
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

    if function_exported?(server_module, :handle_subscribe_resource, 2) do
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

    if function_exported?(server_module, :handle_unsubscribe_resource, 2) do
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
          error["code"] || -32000,
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
    if function_exported?(server_module, callback_name, 2) do
      apply(server_module, callback_name, [conn, params])
    else
      apply(server_module, callback_name, [conn])
    end
  end

  defp build_capabilities(server_module) do
    capabilities = %{}

    capabilities =
      if function_exported?(server_module, :handle_list_tools, 1) or
           function_exported?(server_module, :handle_call_tool, 3) do
        Map.put(capabilities, "tools", %{"listChanged" => false})
      else
        capabilities
      end

    capabilities =
      if function_exported?(server_module, :handle_list_resources, 1) or
           function_exported?(server_module, :handle_read_resource, 2) do
        Map.put(capabilities, "resources", %{"listChanged" => false})
      else
        capabilities
      end

    if function_exported?(server_module, :handle_list_prompts, 1) or
         function_exported?(server_module, :handle_get_prompt, 3) do
      Map.put(capabilities, "prompts", %{"listChanged" => false})
    else
      capabilities
    end
  end
end

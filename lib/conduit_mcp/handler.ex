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
        handle_initialize(id, params)

      "ping" ->
        Protocol.success_response(id, %{})

      "tools/list" ->
        case server_module.handle_list_tools(conn) do
          {:ok, result} when is_map(result) ->
            Protocol.success_response(id, result)

          {:error, error} ->
            Protocol.error_response(id, error["code"] || -32000, error["message"] || "Failed to list tools")

          other ->
            Logger.error("Unexpected result from handle_list_tools: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "tools/call" ->
        tool_name = Map.get(params, "name")
        tool_params = Map.get(params, "arguments", %{})

        start_time = System.monotonic_time()

        result =
          case server_module.handle_call_tool(conn, tool_name, tool_params) do
            {:ok, tool_result} when is_map(tool_result) ->
              Protocol.success_response(id, tool_result)

            {:error, error} ->
              Protocol.error_response(id, error["code"] || -32000, error["message"] || "Tool execution failed")

            other ->
              Logger.error("Unexpected result from handle_call_tool: #{inspect(other)}")
              Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
          end

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:conduit_mcp, :tool, :execute],
          %{duration: duration},
          %{tool_name: tool_name, server_module: server_module, status: if(Map.has_key?(result, "error"), do: :error, else: :ok)}
        )

        result

      "resources/list" ->
        case server_module.handle_list_resources(conn) do
          {:ok, result} when is_map(result) ->
            Protocol.success_response(id, result)

          {:error, error} ->
            Protocol.error_response(id, error["code"] || -32000, error["message"] || "Failed to list resources")

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
              Protocol.error_response(id, error["code"] || -32000, error["message"] || "Resource read failed")

            other ->
              Logger.error("Unexpected result from handle_read_resource: #{inspect(other)}")
              Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
          end

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:conduit_mcp, :resource, :read],
          %{duration: duration},
          %{uri: uri, server_module: server_module, status: if(Map.has_key?(result, "error"), do: :error, else: :ok)}
        )

        result

      "prompts/list" ->
        case server_module.handle_list_prompts(conn) do
          {:ok, result} when is_map(result) ->
            Protocol.success_response(id, result)

          {:error, error} ->
            Protocol.error_response(id, error["code"] || -32000, error["message"] || "Failed to list prompts")

          other ->
            Logger.error("Unexpected result from handle_list_prompts: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "prompts/get" ->
        prompt_name = Map.get(params, "name")
        prompt_args = Map.get(params, "arguments", %{})

        start_time = System.monotonic_time()

        result =
          case server_module.handle_get_prompt(conn, prompt_name, prompt_args) do
            {:ok, prompt_result} when is_map(prompt_result) ->
              Protocol.success_response(id, prompt_result)

            {:error, error} ->
              Protocol.error_response(id, error["code"] || -32000, error["message"] || "Prompt get failed")

            other ->
              Logger.error("Unexpected result from handle_get_prompt: #{inspect(other)}")
              Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
          end

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:conduit_mcp, :prompt, :get],
          %{duration: duration},
          %{prompt_name: prompt_name, server_module: server_module, status: if(Map.has_key?(result, "error"), do: :error, else: :ok)}
        )

        result

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

  defp handle_initialize(id, params) do
    protocol_version = Map.get(params, "protocolVersion")
    client_info = Map.get(params, "clientInfo", %{})
    _capabilities = Map.get(params, "capabilities", %{})

    Logger.info("Initializing connection with client: #{inspect(client_info)}")
    Logger.debug("Protocol version: #{protocol_version}")

    result = %{
      "protocolVersion" => Protocol.protocol_version(),
      "serverInfo" => %{
        "name" => "conduit-mcp",
        "version" => "0.4.7"
      },
      "capabilities" => %{
        "tools" => %{},
        "resources" => %{},
        "prompts" => %{}
      }
    }

    Protocol.success_response(id, result)
  end
end

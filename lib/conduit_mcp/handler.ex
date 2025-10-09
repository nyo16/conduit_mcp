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
  def handle_request(request, server_module) do
    start_time = System.monotonic_time()

    result =
      cond do
        Protocol.valid_request?(request) ->
          handle_method(request, server_module)

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

  defp handle_method(request, server_module) do
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
        case GenServer.call(server_module, {:list_tools}) do
          result when is_map(result) ->
            Protocol.success_response(id, result)

          other ->
            Logger.error("Unexpected result from handle_list_tools: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "tools/call" ->
        tool_name = Map.get(params, "name")
        tool_params = Map.get(params, "arguments", %{})

        start_time = System.monotonic_time()

        result =
          case GenServer.call(server_module, {:call_tool, tool_name, tool_params}) do
            {:error, error} ->
              Protocol.error_response(id, error[:code] || -32000, error[:message] || "Tool execution failed")

            result when is_map(result) ->
              Protocol.success_response(id, result)

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
        case GenServer.call(server_module, {:list_resources}) do
          result when is_map(result) ->
            Protocol.success_response(id, result)

          other ->
            Logger.error("Unexpected result from handle_list_resources: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "resources/read" ->
        uri = Map.get(params, "uri")

        case GenServer.call(server_module, {:read_resource, uri}) do
          {:error, error} ->
            Protocol.error_response(id, error[:code] || -32000, error[:message] || "Resource read failed")

          result when is_map(result) ->
            Protocol.success_response(id, result)

          other ->
            Logger.error("Unexpected result from handle_read_resource: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "prompts/list" ->
        case GenServer.call(server_module, {:list_prompts}) do
          result when is_map(result) ->
            Protocol.success_response(id, result)

          other ->
            Logger.error("Unexpected result from handle_list_prompts: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

      "prompts/get" ->
        prompt_name = Map.get(params, "name")
        prompt_args = Map.get(params, "arguments", %{})

        case GenServer.call(server_module, {:get_prompt, prompt_name, prompt_args}) do
          {:error, error} ->
            Protocol.error_response(id, error[:code] || -32000, error[:message] || "Prompt get failed")

          result when is_map(result) ->
            Protocol.success_response(id, result)

          other ->
            Logger.error("Unexpected result from handle_get_prompt: #{inspect(other)}")
            Protocol.error_response(id, Protocol.internal_error(), "Internal server error")
        end

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
        "version" => "0.2.0"
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

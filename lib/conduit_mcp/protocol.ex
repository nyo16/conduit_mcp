defmodule ConduitMcp.Protocol do
  @moduledoc """
  Core MCP (Model Context Protocol) definitions and message handling.
  Based on specification version 2025-06-18.
  """

  @protocol_version "2025-06-18"

  @type json_rpc_id :: String.t() | integer()
  @type method :: String.t()

  @type request :: %{
          jsonrpc: String.t(),
          id: json_rpc_id(),
          method: method(),
          params: map() | nil
        }

  @type response :: success_response() | error_response()

  @type success_response :: %{
          jsonrpc: String.t(),
          id: json_rpc_id(),
          result: any()
        }

  @type error_response :: %{
          jsonrpc: String.t(),
          id: json_rpc_id(),
          error: error_object()
        }

  @type notification :: %{
          jsonrpc: String.t(),
          method: method(),
          params: map() | nil
        }

  @type error_object :: %{
          code: integer(),
          message: String.t(),
          data: any() | nil
        }

  # JSON-RPC 2.0 Error Codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  def protocol_version, do: @protocol_version

  # Error code constants
  def parse_error, do: @parse_error
  def invalid_request, do: @invalid_request
  def method_not_found, do: @method_not_found
  def invalid_params, do: @invalid_params
  def internal_error, do: @internal_error

  @doc """
  Core MCP methods as defined in the specification.
  """
  def methods do
    %{
      # Lifecycle
      "initialize" => :initialize,
      "notifications/initialized" => :initialized,
      "ping" => :ping,

      # Tools
      "tools/list" => :list_tools,
      "tools/call" => :call_tool,

      # Resources
      "resources/list" => :list_resources,
      "resources/read" => :read_resource,
      "resources/subscribe" => :subscribe_resource,
      "resources/unsubscribe" => :unsubscribe_resource,

      # Prompts
      "prompts/list" => :list_prompts,
      "prompts/get" => :get_prompt,

      # Logging
      "logging/setLevel" => :set_log_level
    }
  end

  @doc """
  Validates if a message is a valid JSON-RPC 2.0 request.
  """
  def valid_request?(message) do
    is_map(message) and
      Map.get(message, "jsonrpc") == "2.0" and
      Map.has_key?(message, "id") and
      Map.has_key?(message, "method") and
      is_binary(Map.get(message, "method"))
  end

  @doc """
  Validates if a message is a valid JSON-RPC 2.0 notification.
  """
  def valid_notification?(message) do
    is_map(message) and
      Map.get(message, "jsonrpc") == "2.0" and
      not Map.has_key?(message, "id") and
      Map.has_key?(message, "method") and
      is_binary(Map.get(message, "method"))
  end

  @doc """
  Creates a success response.
  """
  def success_response(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  @doc """
  Creates an error response.
  """
  def error_response(id, code, message, data \\ nil) do
    error = %{
      "code" => code,
      "message" => message
    }

    error =
      if data do
        Map.put(error, "data", data)
      else
        error
      end

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    }
  end

  @doc """
  Creates a notification message.
  """
  def notification(method, params \\ nil) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => method
    }

    if params do
      Map.put(message, "params", params)
    else
      message
    end
  end
end

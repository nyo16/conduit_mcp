defmodule ConduitMcp.Protocol do
  @moduledoc """
  JSON-RPC 2.0 message construction and MCP protocol version negotiation.

  ConduitMCP targets MCP spec **2025-11-25** as the primary version and
  also accepts clients on **2025-06-18** for backward compatibility.
  `protocol_version/0` returns the preferred version; `negotiate_version/1`
  resolves a client's requested version to one the server supports.

  ## Building responses

  Helpers `success_response/2`, `error_response/3,4`, and `notification/2`
  produce the right wire shape — string-keyed maps with `"jsonrpc"`,
  `"id"`, and either `"result"` or `"error"`. `validate_request/1`
  performs lightweight shape checking on incoming messages.

  ## Error codes

  Standard JSON-RPC 2.0 codes and MCP-specific codes are exposed as
  delegating functions to `ConduitMcp.Errors`:

  - `parse_error/0`         → -32700
  - `invalid_request/0`     → -32600
  - `method_not_found/0`    → -32601
  - `invalid_params/0`      → -32602
  - `internal_error/0`      → -32603
  - `server_error/0`        → -32000 (generic server-defined)
  - `resource_not_found/0`  → -32002
  - `task_not_ready/0`      → -32004 (`tasks/result` before completion)
  - `request_cancelled/0`   → -32800 (`notifications/cancelled`)

  Use these instead of hardcoded integers so error code constants stay
  in one place.

  ## Examples

      iex> ConduitMcp.Protocol.success_response(1, %{"value" => 42})
      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"value" => 42}}

      iex> ConduitMcp.Protocol.error_response(1, -32601, "no such method")
      %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => "no such method"}}
  """

  @protocol_version "2025-11-25"
  @supported_versions ["2025-11-25", "2025-06-18"]

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

  def protocol_version, do: @protocol_version
  def supported_versions, do: @supported_versions

  @doc """
  Returns the best matching protocol version for the given client version.
  Returns `nil` if no compatible version is found.
  """
  def negotiate_version(client_version) do
    if client_version in @supported_versions do
      client_version
    else
      nil
    end
  end

  # Error code constants — delegate to ConduitMcp.Errors
  defdelegate parse_error, to: ConduitMcp.Errors
  defdelegate invalid_request, to: ConduitMcp.Errors
  defdelegate method_not_found, to: ConduitMcp.Errors
  defdelegate invalid_params, to: ConduitMcp.Errors
  defdelegate internal_error, to: ConduitMcp.Errors
  # The moduledoc above advertised `server_error/0` while this block omitted
  # it, so `ConduitMcp.Protocol.server_error()` raised UndefinedFunctionError.
  defdelegate server_error, to: ConduitMcp.Errors
  defdelegate resource_not_found, to: ConduitMcp.Errors
  defdelegate task_not_ready, to: ConduitMcp.Errors
  defdelegate request_cancelled, to: ConduitMcp.Errors

  @doc """
  Every MCP method the library routes, mapped to its internal name.

  Derived from `ConduitMcp.Handler`'s routing table rather than being a second
  hand-maintained copy: the previous list was missing six routed methods
  (`resources/templates/list`, all four `tasks/*`, and
  `notifications/cancelled`).
  """
  @spec methods() :: %{optional(String.t()) => atom()}
  defdelegate methods, to: ConduitMcp.Handler

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

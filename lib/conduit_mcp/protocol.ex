defmodule ConduitMcp.Protocol do
  @moduledoc """
  JSON-RPC 2.0 message construction and MCP protocol versions.

  ConduitMCP is dual-era. It speaks MCP **2026-07-28** (the *modern* era:
  version and capabilities travel in every request's `_meta`, no handshake)
  and **2025-11-25** / **2025-06-18** (the *legacy* era, negotiated by
  `initialize`). `supported_versions/0` lists all three, newest first — the
  list `server/discover` advertises. `modern_versions/0` and
  `legacy_versions/0` split it by era; `negotiate_version/1` resolves an
  `initialize` request and only ever picks a legacy version.
  `protocol_version/0` is the preferred legacy version.

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
  - `task_not_ready/0`      → -32004 (legacy `tasks/result` before completion)
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
  @modern_versions ["2026-07-28"]
  @legacy_versions ["2025-11-25", "2025-06-18"]
  @supported_versions @modern_versions ++ @legacy_versions

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

  @doc "The preferred legacy protocol version, `#{@protocol_version}`."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc "Every supported protocol version, newest first: #{inspect(@supported_versions)}."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc "The modern-era (per-request `_meta`) versions: #{inspect(@modern_versions)}."
  @spec modern_versions() :: [String.t()]
  def modern_versions, do: @modern_versions

  @doc "The legacy-era (`initialize`-negotiated) versions: #{inspect(@legacy_versions)}."
  @spec legacy_versions() :: [String.t()]
  def legacy_versions, do: @legacy_versions

  @doc """
  Resolves the version an `initialize` request asks for: the version itself
  when it is a legacy version, otherwise `nil`. A modern version is never
  negotiated by `initialize`; modern clients send it per request instead.
  """
  @spec negotiate_version(term()) :: String.t() | nil
  def negotiate_version(client_version) do
    if client_version in @legacy_versions do
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
  Validates if a message is a JSON-RPC 2.0 response: an `id`, no `method`, and
  exactly one of `result` and `error`.
  """
  @spec valid_response?(term()) :: boolean()
  def valid_response?(message) do
    is_map(message) and
      Map.get(message, "jsonrpc") == "2.0" and
      Map.has_key?(message, "id") and
      not Map.has_key?(message, "method") and
      Map.has_key?(message, "result") != Map.has_key?(message, "error")
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

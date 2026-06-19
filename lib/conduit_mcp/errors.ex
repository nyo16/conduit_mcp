defmodule ConduitMcp.Errors do
  @moduledoc """
  Standard error codes for MCP and JSON-RPC 2.0 responses.

  These constants can be used with the `error/2` response helper or when
  building error maps manually. All codes follow the JSON-RPC 2.0 specification
  and MCP protocol extensions.

  ## Usage

  With response helpers (DSL and Endpoint modes):

      import ConduitMcp.Errors

      error("User not found", method_not_found())
      error("Bad input", invalid_params())

  Building error maps manually:

      alias ConduitMcp.Errors

      {:error, %{"code" => Errors.invalid_params(), "message" => "Missing required field"}}

  ## JSON-RPC 2.0 Error Codes

  | Code | Constant | Meaning |
  |------|----------|---------|
  | `-32700` | `parse_error/0` | Invalid JSON received by the server |
  | `-32600` | `invalid_request/0` | The JSON sent is not a valid Request object |
  | `-32601` | `method_not_found/0` | The method does not exist or is not available |
  | `-32602` | `invalid_params/0` | Invalid method parameters |
  | `-32603` | `internal_error/0` | Internal JSON-RPC error |

  ## MCP Error Codes

  | Code | Constant | Meaning |
  |------|----------|---------|
  | `-32000` | `server_error/0` | Generic tool/server error (default for `error/1`) |
  | `-32002` | `resource_not_found/0` | The requested resource URI was not found |
  | `-32004` | `task_not_ready/0` | A `tasks/result` was requested before the task finished |
  | `-32800` | `request_cancelled/0` | The request was cancelled (`notifications/cancelled`) |
  """

  # JSON-RPC 2.0 standard error codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # MCP-specific error codes
  @server_error -32000
  @resource_not_found -32002
  @task_not_ready -32004
  @request_cancelled -32800

  @doc "Parse error — invalid JSON received (`-32700`)"
  def parse_error, do: @parse_error

  @doc "Invalid request — not a valid JSON-RPC 2.0 request (`-32600`)"
  def invalid_request, do: @invalid_request

  @doc "Method not found — tool, prompt, or resource does not exist (`-32601`)"
  def method_not_found, do: @method_not_found

  @doc "Invalid params — parameter validation failed (`-32602`)"
  def invalid_params, do: @invalid_params

  @doc "Internal error — unexpected server-side failure (`-32603`)"
  def internal_error, do: @internal_error

  @doc "Server error — generic tool/server error, default for `error/1` (`-32000`)"
  def server_error, do: @server_error

  @doc "Resource not found — the requested URI did not match any resource (`-32002`)"
  def resource_not_found, do: @resource_not_found

  @doc "Task not ready — `tasks/result` requested before the task finished (`-32004`)"
  def task_not_ready, do: @task_not_ready

  @doc "Request cancelled — client sent `notifications/cancelled` for this request (`-32800`)"
  def request_cancelled, do: @request_cancelled
end

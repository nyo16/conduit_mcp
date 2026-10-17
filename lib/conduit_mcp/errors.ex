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
  | `-32004` | `task_not_ready/0` | Legacy era only: a `tasks/result` was requested before the task finished |
  | `-32020` | `header_mismatch/0` | Modern era: an HTTP header disagrees with the request body, or a required header is missing or malformed (HTTP 400) |
  | `-32021` | `missing_required_client_capability/0` | Modern era: the request needs a client capability the request did not declare; `data.requiredCapabilities` names it (HTTP 400) |
  | `-32022` | `unsupported_protocol_version/0` | Modern era: the `_meta` protocol version is not implemented; `data` carries `supported` and `requested` (HTTP 400) |
  | `-31004` | `modern_task_not_ready/0` | Modern era replacement for `-32004` |
  | `-32800` | `request_cancelled/0` | The request was cancelled (`notifications/cancelled`) |

  ## Resource not found is era-dependent

  There is no `resource_not_found/0`: MCP `2025-11-25` and earlier answer a
  missing resource with `-32002`, while `2026-07-28` forbids emitting `-32002`
  and uses `-32602` instead. A `handle_read_resource/2` callback keeps
  returning `ConduitMcp.Protocol.Legacy.resource_not_found/0` (`-32002`);
  `ConduitMcp.Protocol.Modern` rewrites that code to `-32602` on the modern
  path.

  ## Why `-31004`

  The `2026-07-28` error-code policy says new implementations SHOULD NOT use
  the grandfathered `-32000..-32019` sub-range, reserves `-32020..-32099` for
  codes the specification defines, and asks that application-defined codes be
  allocated outside the JSON-RPC range `-32768..-32000`. Neither the core
  specification nor the tasks extension (SEP-2663) defines a "task not ready"
  code, so the modern code is the legacy `-32004` moved just outside that
  range.
  """

  # JSON-RPC 2.0 standard error codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # MCP-specific error codes
  @server_error -32000
  @task_not_ready -32004
  @request_cancelled -32800

  # MCP 2026-07-28 error codes
  @header_mismatch -32020
  @missing_required_client_capability -32021
  @unsupported_protocol_version -32022
  @modern_task_not_ready -31004

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

  @doc "Task not ready — legacy `tasks/result` requested before the task finished (`-32004`)"
  def task_not_ready, do: @task_not_ready

  @doc "Request cancelled — client sent `notifications/cancelled` for this request (`-32800`)"
  def request_cancelled, do: @request_cancelled

  @doc """
  Header mismatch — an MCP HTTP header disagrees with the request body, or a
  required header is missing or malformed (`-32020`, HTTP 400).
  """
  def header_mismatch, do: @header_mismatch

  @doc """
  Missing required client capability — the request needs a capability the
  client did not declare in its per-request `_meta` (`-32021`, HTTP 400).
  """
  def missing_required_client_capability, do: @missing_required_client_capability

  @doc """
  Unsupported protocol version — the request's `_meta` protocol version is
  not one this server implements (`-32022`, HTTP 400).
  """
  def unsupported_protocol_version, do: @unsupported_protocol_version

  @doc """
  Task not ready on the modern path (`-31004`), outside the JSON-RPC reserved
  range; see "Why `-31004`" in the moduledoc.
  """
  def modern_task_not_ready, do: @modern_task_not_ready
end

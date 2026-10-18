defmodule ConduitMcp.Handler.Tools do
  @moduledoc false

  # `tools/list` and `tools/call`. Returns neutral `ConduitMcp.Handler.result/0`
  # values; the era's response shaper turns them into protocol messages.

  alias ConduitMcp.Ctx
  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Handler.MRTR
  alias ConduitMcp.Handler.Pipeline

  @doc """
  `tools/list`.
  """
  @spec list(map(), module(), Plug.Conn.t()) :: Handler.result()
  def list(params, server_module, conn),
    do: Common.dispatch_list(params, server_module, conn, :handle_list_tools)

  @doc """
  `tools/call`: scope check, parameter validation, dispatch (through
  `ConduitMcp.Handler.MRTR.dispatch/6`), then the
  `[:conduit_mcp, :tool, :execute]` event.
  """
  @spec call(map(), module(), Plug.Conn.t()) :: Handler.result()
  def call(params, server_module, conn) do
    tool_name = Map.get(params, "name")
    tool_params = Map.get(params, "arguments", %{})
    start_time = System.monotonic_time()

    result =
      with :ok <-
             Common.verify_scope(
               conn,
               Common.required_scope(server_module, :scope_for_tool, tool_name)
             ),
           {:ok, validated_params} <-
             ConduitMcp.Validation.validate_tool_params(server_module, tool_name, tool_params) do
        MRTR.dispatch(
          conn,
          "tools/call",
          params,
          server_module,
          &server_module.handle_call_tool(&1, tool_name, validated_params),
          "handle_call_tool"
        )
        |> maybe_add_meta(params, conn)
      else
        {:error, :tool_not_found} ->
          Common.unknown_target_error("tool", tool_name)

        {:error, :insufficient_scope, required_scope} ->
          Common.insufficient_scope_error(required_scope)

        {:error, validation_errors} ->
          {:error, Errors.invalid_params(), "Parameter validation failed",
           %{"errors" => ConduitMcp.Validation.format_validation_errors(validation_errors)}}
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :tool, :execute],
      %{duration: duration},
      %{
        tool_name: Pipeline.telemetry_text(tool_name),
        server_module: server_module,
        status: Common.status(result)
      }
    )

    result
  end

  # `maybe_add_meta/3`: the result `_meta` rule.
  #
  # The tool's own `_meta` (MCP Apps UI metadata, its own keys) is never
  # overwritten.
  #
  #   * Modern era: the request's `_meta` is not echoed at all - it carries the
  #     era's request-scoped keys (protocol version, client info, `logLevel`)
  #     and the client's `progressToken`, none of which belong in the result.
  #     The result gets the tool's `_meta` plus
  #     `io.modelcontextprotocol/serverInfo` (`ConduitMcp.Protocol.Modern`).
  #   * Legacy era: the request's `_meta` is merged in under the tool's keys.
  #     The echo dates from the 2025-11-25 upgrade (6b6892b) and legacy
  #     clients/tests observe it (`progressToken` round-trips), so it stays.
  #
  # Only a successful result carries one. Clients commonly send a _meta (e.g. a
  # progressToken) on every tools/call, so an error result must pass through
  # untouched: writing into it once raised "could not put/update key on a nil
  # value", which the request-path rescue masked as a generic "Internal server
  # error" whenever a tool returned an error.
  defp maybe_add_meta({:ok, result} = ok, params, conn) do
    case {Ctx.from_conn(conn), Map.get(params, "_meta")} do
      {%Ctx{era: :modern}, _meta} ->
        ok

      {_legacy, meta} when is_map(meta) ->
        own = Map.get(result, "_meta")
        {:ok, Map.put(result, "_meta", Map.merge(meta, if(is_map(own), do: own, else: %{})))}

      _ ->
        ok
    end
  end

  defp maybe_add_meta(
         {:input_required, _input_requests, _request_state} = result,
         _params,
         _conn
       ),
       do: result

  defp maybe_add_meta({:task, _task} = result, _params, _conn), do: result

  defp maybe_add_meta({:error, _code, _message, _data} = error, _params, _conn), do: error
end

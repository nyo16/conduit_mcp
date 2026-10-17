defmodule ConduitMcp.Handler.Tools do
  @moduledoc false

  # `tools/list` and `tools/call`. Returns neutral `ConduitMcp.Handler.result/0`
  # values; the era's response shaper turns them into protocol messages.

  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Handler.Pipeline

  @doc """
  `tools/list`.
  """
  @spec list(map(), module(), Plug.Conn.t()) :: Handler.result()
  def list(params, server_module, conn),
    do: Common.dispatch_list(params, server_module, conn, :handle_list_tools)

  @doc """
  `tools/call`: scope check, parameter validation, dispatch, then the
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
        Common.dispatch_callback(
          fn -> server_module.handle_call_tool(conn, tool_name, validated_params) end,
          "handle_call_tool"
        )
        |> maybe_add_meta(params)
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

  # Adds the request's _meta to the tool's result when present.
  #
  # Only a successful result carries one. Clients commonly send a _meta (e.g. a
  # progressToken) on every tools/call, so an error result must pass through
  # untouched: writing into it once raised "could not put/update key on a nil
  # value", which the request-path rescue masked as a generic "Internal server
  # error" whenever a tool returned an error.
  defp maybe_add_meta({:ok, result}, params) do
    case Map.get(params, "_meta") do
      meta when is_map(meta) -> {:ok, Map.put(result, "_meta", meta)}
      _ -> {:ok, result}
    end
  end

  defp maybe_add_meta({:error, _code, _message, _data} = error, _params), do: error
end

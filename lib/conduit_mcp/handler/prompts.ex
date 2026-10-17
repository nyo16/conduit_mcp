defmodule ConduitMcp.Handler.Prompts do
  @moduledoc false

  # `prompts/list` and `prompts/get`. Returns neutral
  # `ConduitMcp.Handler.result/0` values.

  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Handler.MRTR
  alias ConduitMcp.Handler.Pipeline

  @doc """
  `prompts/list`.
  """
  @spec list(map(), module(), Plug.Conn.t()) :: Handler.result()
  def list(params, server_module, conn),
    do: Common.dispatch_list(params, server_module, conn, :handle_list_prompts)

  @doc """
  `prompts/get`: scope check, argument validation, dispatch (through
  `ConduitMcp.Handler.MRTR.dispatch/6`), then the
  `[:conduit_mcp, :prompt, :get]` event.
  """
  @spec get(map(), module(), Plug.Conn.t()) :: Handler.result()
  def get(params, server_module, conn) do
    prompt_name = Map.get(params, "name")
    prompt_args = Map.get(params, "arguments", %{})
    start_time = System.monotonic_time()

    result =
      with :ok <-
             Common.verify_scope(
               conn,
               Common.required_scope(server_module, :scope_for_prompt, prompt_name)
             ),
           {:ok, validated_args} <-
             ConduitMcp.Validation.validate_prompt_args(server_module, prompt_name, prompt_args) do
        MRTR.dispatch(
          conn,
          "prompts/get",
          params,
          server_module,
          &server_module.handle_get_prompt(&1, prompt_name, validated_args),
          "handle_get_prompt"
        )
      else
        {:error, :prompt_not_found} ->
          Common.unknown_target_error("prompt", prompt_name)

        {:error, :insufficient_scope, required} ->
          Common.insufficient_scope_error(required)

        {:error, validation_errors} ->
          {:error, Errors.invalid_params(), "Argument validation failed",
           %{"errors" => ConduitMcp.Validation.format_validation_errors(validation_errors)}}
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :prompt, :get],
      %{duration: duration},
      %{
        prompt_name: Pipeline.telemetry_text(prompt_name),
        server_module: server_module,
        status: Common.status(result)
      }
    )

    result
  end
end

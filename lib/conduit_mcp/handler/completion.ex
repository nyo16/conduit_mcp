defmodule ConduitMcp.Handler.Completion do
  @moduledoc false

  # `completion/complete`. Returns neutral `ConduitMcp.Handler.result/0` values.

  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.ServerMeta

  @doc """
  `completion/complete`: validates the ref, checks the scope of the surface it
  names, then dispatches to `handle_complete/3`. A server without that
  callback answers with an empty completion.
  """
  @spec complete(map(), module(), Plug.Conn.t()) :: Handler.result()
  def complete(params, server_module, conn) do
    ref = Map.get(params, "ref", %{})
    argument = Map.get(params, "argument", %{})

    with :ok <- validate_completion_ref(ref),
         :ok <- Common.verify_scope(conn, completion_scope(server_module, ref)) do
      if ServerMeta.has?(server_module, :complete) do
        Common.dispatch_callback(
          fn -> server_module.handle_complete(conn, ref, argument) end,
          "handle_complete"
        )
      else
        {:ok, %{"completion" => %{"values" => [], "total" => 0, "hasMore" => false}}}
      end
    else
      {:error, :insufficient_scope, required} ->
        Common.insufficient_scope_error(required)

      {:error, message} ->
        {:error, Errors.invalid_params(), message, nil}
    end
  end

  # Completions are declared inside the same `resource`/`prompt` block as
  # `scope`, so enumerating them is reading part of that surface. Without this,
  # a caller lacking `vault:read` could still enumerate a scoped resource's
  # argument values.
  defp completion_scope(server_module, %{"type" => "ref/resource", "uri" => uri}),
    do: Common.required_scope(server_module, :scope_for_resource, uri)

  defp completion_scope(server_module, %{"type" => "ref/prompt", "name" => name}),
    do: Common.required_scope(server_module, :scope_for_prompt, name)

  defp completion_scope(_server_module, _ref), do: nil

  defp validate_completion_ref(%{"type" => "ref/prompt", "name" => name}) when is_binary(name),
    do: :ok

  defp validate_completion_ref(%{"type" => "ref/resource", "uri" => uri}) when is_binary(uri),
    do: :ok

  # `ref/resource`'s uri is gated for the same reason
  # `ConduitMcp.Handler.Resources.authorize/3` gates it: `completion_scope/2`
  # hands it to the templated scope lookup.
  defp validate_completion_ref(%{"type" => type} = ref)
       when type in ["ref/prompt", "ref/resource"] do
    field = ref_required_field(type)

    case Map.fetch(ref, field) do
      {:ok, value} ->
        {:error,
         "Invalid completion ref: #{field} must be a string, got: " <>
           ConduitMcp.Reflect.text(value, 40)}

      :error ->
        {:error, "Invalid completion ref: missing #{field}"}
    end
  end

  defp validate_completion_ref(%{"type" => type}) do
    {:error,
     ~s(Invalid completion ref type "#{ConduitMcp.Reflect.text(type, 40)}"; ) <>
       ~s(expected "ref/prompt" or "ref/resource")}
  end

  defp validate_completion_ref(_),
    do: {:error, "Invalid completion ref: missing type"}

  defp ref_required_field("ref/prompt"), do: "name"
  defp ref_required_field("ref/resource"), do: "uri"
end

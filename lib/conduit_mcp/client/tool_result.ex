defmodule ConduitMcp.Client.ToolResult do
  @moduledoc """
  The outcome of a `tools/call` that the server completed.

  A tool that fails reports it in-band: `is_error: true` with the failure in
  `content`. That is still `{:ok, %ToolResult{is_error: true}}`;
  `{:error, %ConduitMcp.Client.Error{}}` is reserved for protocol, transport
  and policy failures.

    * `content` - the `content` blocks, string-keyed, as sent.
    * `structured` - `structuredContent`, or `nil`.
    * `is_error` - `true` when the server sent `isError: true` (or, for a
      synthetic result, when a post-call hook failed and the result was
      withheld; see `ConduitMcp.Client.Hooks`).
    * `meta` - the result's `_meta`, or `%{}`.
    * `extra` - every other wire key (minus `resultType`), never atomized.
    * `provenance` - `nil`, or, for a result shaped for a model
      (`ConduitMcp.Client.Pipeline`, `shape: :llm`), `%{server_id: id,
      truncated: boolean, flags: [atom]}`.
  """

  alias ConduitMcp.Client.Wire

  @known_keys ["content", "structuredContent", "isError", "_meta", "resultType"]

  defstruct content: [], structured: nil, is_error: false, meta: %{}, extra: %{}, provenance: nil

  @type t :: %__MODULE__{
          content: [map()],
          structured: term(),
          is_error: boolean(),
          meta: map(),
          extra: map(),
          provenance: %{server_id: String.t(), truncated: boolean(), flags: [atom()]} | nil
        }

  @doc """
  Builds a result from a wire `CallToolResult` map.

  `content` must be a list when present (a missing `content` reads as `[]`)
  and `isError` a boolean or `null` when present (`null` reads as `false`);
  otherwise the result is a `:protocol` error with reason
  `:invalid_tool_result`. `resultType` is not checked here: an MRTR interim
  result never reaches this function.

      iex> {:ok, result} =
      ...>   ConduitMcp.Client.ToolResult.from_wire(%{
      ...>     "content" => [%{"type" => "text", "text" => "boom"}],
      ...>     "isError" => true
      ...>   })
      iex> result.is_error
      true
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(%{} = map) when not is_struct(map) do
    content = Map.get(map, "content", [])
    is_error = Map.get(map, "isError") || false

    if is_list(content) and is_boolean(is_error) do
      {:ok,
       %__MODULE__{
         content: content,
         structured: Map.get(map, "structuredContent"),
         is_error: is_error,
         meta: Wire.meta(map),
         extra: Map.drop(map, @known_keys)
       }}
    else
      Wire.invalid(:invalid_tool_result, map)
    end
  end

  def from_wire(other), do: Wire.invalid(:invalid_tool_result, other)
end

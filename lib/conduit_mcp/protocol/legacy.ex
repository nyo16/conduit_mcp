defmodule ConduitMcp.Protocol.Legacy do
  @moduledoc """
  Shapes a neutral handler result (`t:ConduitMcp.Handler.result/0`) into the
  JSON-RPC 2.0 response map of the legacy (`initialize`-negotiated) protocol
  era.

  `{:ok, result}` becomes a success response; `{:error, code, message, data}`
  becomes an error response, with a `"data"` member only when `data` is not
  `nil`. Codes pass through unchanged.

  ## Resource not found

  The legacy era answers an unknown resource with `-32002`
  (`resource_not_found/0`). That is also the code a `handle_read_resource/2`
  callback returns in every authoring mode: the modern shaper,
  `ConduitMcp.Protocol.Modern`, rewrites it to `-32602`, which is what
  `2026-07-28` prescribes.
  """

  alias ConduitMcp.Protocol

  @resource_not_found -32002

  @doc """
  The legacy-era "resource not found" code, `-32002`.

  Return it from `handle_read_resource/2` for an unknown URI; the modern era
  sees `-32602` instead (see the moduledoc).
  """
  @spec resource_not_found() :: integer()
  def resource_not_found, do: @resource_not_found

  @doc """
  Builds the JSON-RPC response for request `id` from a neutral `result`.

  ## Examples

      iex> ConduitMcp.Protocol.Legacy.to_response(1, {:ok, %{}})
      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

      iex> ConduitMcp.Protocol.Legacy.to_response(1, {:error, -32601, "Nope", nil})
      %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => "Nope"}}
  """
  @spec to_response(Protocol.json_rpc_id() | nil, ConduitMcp.Handler.result()) :: map()
  def to_response(id, {:ok, result}), do: Protocol.success_response(id, result)

  def to_response(id, {:error, code, message, nil}),
    do: Protocol.error_response(id, code, message)

  def to_response(id, {:error, code, message, data}),
    do: Protocol.error_response(id, code, message, data)
end

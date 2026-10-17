defmodule ConduitMcp.Protocol.Legacy do
  @moduledoc """
  Shapes a neutral handler result (`t:ConduitMcp.Handler.result/0`) into the
  JSON-RPC 2.0 response map of the legacy (`initialize`-negotiated) protocol
  era.

  `{:ok, result}` becomes a success response; `{:error, code, message, data}`
  becomes an error response, with a `"data"` member only when `data` is not
  `nil`.
  """

  alias ConduitMcp.Protocol

  @doc """
  Builds the JSON-RPC response for request `id` from a neutral `result`.

  ## Examples

      iex> ConduitMcp.Protocol.Legacy.to_response(1, {:ok, %{}})
      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

      iex> ConduitMcp.Protocol.Legacy.to_response(1, {:error, -32601, "Nope", nil})
      %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => "Nope"}}
  """
  @spec to_response(Protocol.json_rpc_id() | nil, ConduitMcp.Handler.result()) ::
          Protocol.response()
  def to_response(id, {:ok, result}), do: Protocol.success_response(id, result)

  def to_response(id, {:error, code, message, nil}),
    do: Protocol.error_response(id, code, message)

  def to_response(id, {:error, code, message, data}),
    do: Protocol.error_response(id, code, message, data)
end

defmodule ConduitMcp.Client.Resource do
  @moduledoc """
  A resource listed by a server (`resources/list`).

  `raw` keeps the string-keyed wire map untouched (including `icons` and any
  future keys); the other fields are conveniences lifted from it. `uri` is
  the server's string, never parsed or normalized here.
  """

  alias ConduitMcp.Client.Wire

  @enforce_keys [:server_id, :uri, :name, :raw]
  defstruct [
    :server_id,
    :uri,
    :name,
    :title,
    :description,
    :mime_type,
    :size,
    :annotations,
    :raw,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          server_id: String.t(),
          uri: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          size: non_neg_integer() | nil,
          annotations: map() | nil,
          meta: map(),
          raw: map()
        }

  @doc """
  Builds a `Resource` from a wire `Resource` map listed by `server_id`.

  `uri` and `name` must be strings; otherwise the result is a `:protocol`
  error with reason `:invalid_resource`.

      iex> {:ok, res} =
      ...>   ConduitMcp.Client.Resource.from_wire("docs", %{"uri" => "file:///a.md", "name" => "a"})
      iex> res.uri
      "file:///a.md"
  """
  @spec from_wire(String.t(), term()) :: {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(server_id, %{"uri" => uri, "name" => name} = raw)
      when is_binary(server_id) and is_binary(uri) and is_binary(name) do
    {:ok,
     %__MODULE__{
       server_id: server_id,
       uri: uri,
       name: name,
       title: Wire.string(raw, "title"),
       description: Wire.string(raw, "description"),
       mime_type: Wire.string(raw, "mimeType"),
       size: size(raw),
       annotations: Wire.object(raw, "annotations"),
       meta: Wire.meta(raw),
       raw: raw
     }}
  end

  def from_wire(_server_id, other), do: Wire.invalid(:invalid_resource, other)

  defp size(%{"size" => size}) when is_integer(size) and size >= 0, do: size
  defp size(_raw), do: nil
end

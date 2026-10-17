defmodule ConduitMcp.Client.ServerInfo do
  @moduledoc """
  A server's self-reported `Implementation` (`serverInfo`).

  Legacy servers return it in the `initialize` result; modern servers put it
  in `_meta["io.modelcontextprotocol/serverInfo"]` of their results. The spec
  says it is self-reported and SHOULD NOT drive behaviour or security, so it
  is display data only: hub naming and policy never read it.

  `raw` keeps the whole string-keyed wire map, including keys this struct
  does not lift into fields (such as `icons`).
  """

  alias ConduitMcp.Client.Wire

  @enforce_keys [:name, :raw]
  defstruct [:name, :version, :title, :description, :website_url, :raw]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          website_url: String.t() | nil,
          raw: map()
        }

  @doc """
  Builds a `ServerInfo` from a wire `Implementation` map.

  `name` must be a string. `version` is required by the schema, but some
  servers omit it, so a missing or non-string `version` reads as `nil`.

      iex> {:ok, info} = ConduitMcp.Client.ServerInfo.from_wire(%{"name" => "srv", "version" => "1.0"})
      iex> {info.name, info.version}
      {"srv", "1.0"}
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, ConduitMcp.Client.Error.t()}
  def from_wire(%{"name" => name} = map) when is_binary(name) do
    {:ok,
     %__MODULE__{
       name: name,
       version: Wire.string(map, "version"),
       title: Wire.string(map, "title"),
       description: Wire.string(map, "description"),
       website_url: Wire.string(map, "websiteUrl"),
       raw: map
     }}
  end

  def from_wire(other), do: Wire.invalid(:invalid_server_info, other)
end

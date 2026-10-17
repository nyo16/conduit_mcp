defmodule ConduitMcp.Client.Fingerprint do
  @moduledoc """
  The digest a tool's approvals are pinned to.

  A fingerprint is the lower-case hex SHA-256 of the canonical JSON (object
  keys sorted recursively by their bytes, no insignificant whitespace) of
  exactly these fields of the server's wire definition:

  `name`, `title`, `description`, `inputSchema`, `outputSchema`,
  `annotations`, `execution`, `_meta`

  A field that is absent, or present with a JSON `null`, is left out of the
  digest (never encoded as `null`), so a server flipping between the two does
  not look like a new definition. Every other key (`icons`, future fields) is
  ignored. Values are hashed exactly as sent: reordering object keys anywhere
  gives the same fingerprint, while any change to a value, including
  whitespace inside the description, gives a different one.

  `ConduitMcp.Client.Policy` compares it against the fingerprint recorded at
  approval (`pin_tools`), so a server that rewrites a tool after approval (a
  "rug pull") falls back to asking.

      iex> a = ConduitMcp.Client.Fingerprint.compute(%{"name" => "read", "inputSchema" => %{"type" => "object", "required" => []}})
      iex> b = ConduitMcp.Client.Fingerprint.compute(%{"inputSchema" => %{"required" => [], "type" => "object"}, "name" => "read"})
      iex> a == b
      true
  """

  alias ConduitMcp.Client.{Canonical, Tool}

  @fields ~w(name title description inputSchema outputSchema annotations execution _meta)

  @typedoc "A lower-case hex SHA-256 digest (64 characters)."
  @type t :: String.t()

  @doc """
  The fingerprint of a `ConduitMcp.Client.Tool` (computed over its `raw` wire
  map) or of a string-keyed wire `Tool` map.

  Raises when a hashed field holds a value the stdlib `JSON` encoder cannot
  encode (wire maps decoded from JSON never do).
  """
  @spec compute(Tool.t() | map()) :: t()
  def compute(%Tool{raw: raw}), do: compute(raw)

  def compute(definition) when is_map(definition) and not is_struct(definition) do
    definition
    |> Map.take(@fields)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Canonical.sha256()
  end

  @doc "The wire fields a fingerprint covers, in no particular order."
  @spec fields() :: [String.t()]
  def fields, do: @fields
end

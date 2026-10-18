defmodule ConduitMcp.Client.Canonical do
  @moduledoc false
  # Canonical JSON for digests: object keys are stringified and sorted
  # recursively by their bytes, with no insignificant whitespace, so two
  # terms that differ only in key order or key type (atom vs string) encode
  # identically. Scalars go through the stdlib `JSON` encoder, so a value
  # `JSON` cannot encode (or a `ConduitMcp.Client.Secret`) raises.

  @doc "Canonical JSON encoding of `term`, as a binary."
  @spec encode(term()) :: binary()
  def encode(term), do: term |> encode_iodata() |> IO.iodata_to_binary()

  @doc "Lower-case hex SHA-256 of `encode/1`."
  @spec sha256(term()) :: String.t()
  def sha256(term) do
    :crypto.hash(:sha256, encode_iodata(term)) |> Base.encode16(case: :lower)
  end

  defp encode_iodata(map) when is_map(map) and not is_struct(map) do
    members =
      map
      |> Enum.map(fn {key, value} -> {key_to_string(key), value} end)
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ?:, encode_iodata(value)] end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp encode_iodata(list) when is_list(list),
    do: [?[, list |> Enum.map(&encode_iodata/1) |> Enum.intersperse(?,), ?]]

  defp encode_iodata(scalar), do: JSON.encode!(scalar)

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_integer(key), do: Integer.to_string(key)
end

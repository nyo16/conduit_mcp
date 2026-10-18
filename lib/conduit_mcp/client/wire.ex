defmodule ConduitMcp.Client.Wire do
  @moduledoc false
  # Lenient field readers for the client's `from_wire/1` struct builders.
  # Required fields are checked by the callers; optional convenience fields
  # read as `nil` when absent or of the wrong type (the untouched value stays
  # in the struct's `raw` map). Keys are never atomized.

  alias ConduitMcp.Client.Error

  @spec string(map(), String.t()) :: String.t() | nil
  def string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  @spec object(map(), String.t()) :: map() | nil
  def object(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  @spec list(map(), String.t()) :: list() | nil
  def list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  @spec meta(map()) :: map()
  def meta(map), do: object(map, "_meta") || %{}

  @spec invalid(atom(), term()) :: {:error, Error.t()}
  def invalid(what, data), do: {:error, Error.new(:protocol, what, data)}
end

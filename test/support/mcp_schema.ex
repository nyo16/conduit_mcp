defmodule ConduitMcp.Test.McpSchema do
  @moduledoc """
  Golden-test helper over the MCP JSON Schemas vendored in
  `test/fixtures/mcp_schema/<version>/schema.json` (provenance in
  `test/fixtures/mcp_schema/PROVENANCE.md`).

  A definition is addressed by its `$defs` name, e.g. `"CallToolResult"`:

      assert :ok = McpSchema.validate("2026-07-28", "DiscoverResult", result)

  Each `{version, name}` pair is compiled once with JSV and cached in
  `:persistent_term`, so golden assertions stay cheap inside loops.
  """

  @fixtures Path.expand("../fixtures/mcp_schema", __DIR__)

  @doc "Every vendored schema version."
  @spec versions() :: [String.t()]
  def versions do
    @fixtures
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@fixtures, &1)))
    |> Enum.sort()
  end

  @doc "The raw `$defs` entry for `name` in `version`'s schema."
  @spec definition(String.t(), String.t()) :: map()
  def definition(version, name) do
    case Map.fetch(Map.fetch!(schema(version), "$defs"), name) do
      {:ok, definition} -> definition
      :error -> raise ArgumentError, "no $defs entry #{inspect(name)} in MCP schema #{version}"
    end
  end

  @doc """
  Validates `data` against `version`'s `name` definition.

  Returns `:ok` or `{:error, errors}` where `errors` is JSV's normalized error
  map, which reads well in an assertion failure.
  """
  @spec validate(String.t(), String.t(), term()) :: :ok | {:error, map()}
  def validate(version, name, data) do
    case JSV.validate(data, root(version, name)) do
      {:ok, _cast} -> :ok
      {:error, error} -> {:error, JSV.normalize_error(error)}
    end
  end

  defp root(version, name) do
    key = {__MODULE__, :root, version, name}

    case :persistent_term.get(key, nil) do
      nil ->
        # Ensures `name` exists before building, for a readable error.
        _ = definition(version, name)

        root =
          version
          |> schema()
          |> Map.put("$ref", "#/$defs/#{name}")
          |> JSV.build!()

        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  defp schema(version) do
    key = {__MODULE__, :schema, version}

    case :persistent_term.get(key, nil) do
      nil ->
        path = Path.join([@fixtures, version, "schema.json"])

        unless File.regular?(path) do
          raise ArgumentError, "no vendored MCP schema for #{inspect(version)} at #{path}"
        end

        schema = path |> File.read!() |> JSON.decode!()
        :persistent_term.put(key, schema)
        schema

      schema ->
        schema
    end
  end
end

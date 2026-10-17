if Code.ensure_loaded?(JSV) do
  defmodule ConduitMcp.Client.SchemaValidator.JSV do
    @moduledoc """
    The default `ConduitMcp.Client.SchemaValidator`, built on
    [JSV](https://hex.pm/packages/jsv) (JSON Schema 2020-12 and draft 7).

    Only compiled when the optional `{:jsv, "~> 0.26"}` dependency is
    present; `ConduitMcp.OptionalDeps.jsv!/0` checks for it when a client's
    options ask for validation.

    Server schemas are untrusted, so they are built with JSV's default
    resolvers only (embedded meta-schemas and the schema's own documents:
    never the network), with no atom-creating casts, with build warnings
    silenced, and with JSV's `jsv-cast` / `x-jsv-cast` extension keywords
    removed; data is validated with casting off. JSV runs `pattern` and
    `patternProperties` under a backtracking budget linear in the subject
    size, so a catastrophic pattern such as `(a+)+$` fails the value instead
    of hanging the caller. Schemas reach `build/2` only after
    `ConduitMcp.Client.SchemaValidator.check_bounds/1`.
    """

    @behaviour ConduitMcp.Client.SchemaValidator

    @cast_keys ["jsv-cast", "x-jsv-cast"]

    @impl true
    def build(schema, _opts) do
      case JSV.build(strip_casts(schema), atoms: false, warnings: :silence) do
        {:ok, root} -> {:ok, root}
        {:error, _error} -> {:error, :build_failed}
      end
    end

    @impl true
    def validate(root, data) do
      case JSV.validate(data, root, cast: false) do
        {:ok, _data} -> :ok
        {:error, error} -> {:error, JSV.normalize_error(error)}
      end
    end

    defp strip_casts(map) when is_map(map) do
      for {key, value} <- map, key not in @cast_keys, into: %{}, do: {key, strip_casts(value)}
    end

    defp strip_casts(list) when is_list(list), do: Enum.map(list, &strip_casts/1)
    defp strip_casts(other), do: other
  end
end

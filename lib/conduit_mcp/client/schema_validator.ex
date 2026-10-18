defmodule ConduitMcp.Client.SchemaValidator do
  @moduledoc """
  JSON Schema validation of tool arguments and `structuredContent`, behind a
  behaviour so the validator can be swapped.

  Validation is opt-in, per client:

      {ConduitMcp.Client,
       name: :docs,
       transport: {...},
       validate: [arguments: true, structured_content: true]}

    * `arguments: true` - a call's final arguments (after pre-hooks) are
      validated against the tool's `inputSchema` before policy runs; an
      invalid call is never sent (`{:error, %Error{kind: :protocol, reason:
      :invalid_arguments}}`, the validator's errors in `data`).
    * `structured_content: true` - a successful result's `structuredContent`
      is validated against the tool's `outputSchema`, when it has one;
      a mismatch (or a missing `structuredContent`) is `{:error,
      %Error{kind: :protocol, reason: :invalid_structured_content}}`.

  The default validator is `ConduitMcp.Client.SchemaValidator.JSV`, which
  needs the optional `:jsv` dependency (JSON Schema 2020-12 and draft 7).
  Asking for validation without it raises
  `ConduitMcp.OptionalDependencyError` when the client's options are
  validated, never per request. Another validator is set with
  `validate: [validator: MyValidator]`.

  ## Bounds (HK-6)

  Tool schemas come from the server, so a schema is checked before any
  validator sees it. A schema is refused when:

    * it is not an object or a boolean (`:invalid_schema`);
    * it nests JSON objects and arrays more than 64 deep, or subschemas more
      than 32 deep (`:too_deep`);
    * it has more than 1 000 subschemas (`:too_many_subschemas`);
    * its JSON encoding is over 256 KiB (`:too_large`);
    * a `$ref` or `$dynamicRef` is anything but a local `#...` pointer
      (`:remote_ref`): references are never dereferenced over the network
      or the file system.

  A tool whose schema is refused (or fails to build) is left out of the
  client's tool lists while that validation is on, and a call to it fails
  with `{:error, %Error{kind: :protocol, reason: {:unsafe_schema, :input |
  :output, reason}}}` before anything is sent.

  ## Caching

  Built schemas are kept in the client's governance table (written by its
  owner process, read directly by callers), keyed by the tool's
  `ConduitMcp.Client.Fingerprint` and the validator. A changed definition has
  a new fingerprint, so a refresh that changes a tool never reuses the old
  schema; the cache is cleared when it holds more than 4 096 entries.
  Refusals are cached the same way.
  """

  @typedoc "A validator's built schema; opaque to the client."
  @type compiled :: term()

  @doc """
  Builds `schema` (a bounds-checked, string-keyed JSON Schema object or a
  boolean) for repeated validation. `opts` is reserved and currently `[]`.
  """
  @callback build(schema :: map() | boolean(), opts :: keyword()) ::
              {:ok, compiled()} | {:error, term()}

  @doc """
  Validates `data` (JSON-shaped: string keys) against a built schema.
  Errors are returned to the caller in the `data` of the client error.
  """
  @callback validate(compiled(), data :: term()) :: :ok | {:error, term()}

  @max_json_depth 64
  @max_depth 32
  @max_subschemas 1_000
  @max_bytes 262_144

  @single ~w(items additionalProperties not if then else contains propertyNames
             unevaluatedItems unevaluatedProperties additionalItems contentSchema)
  @mapped ~w(properties patternProperties $defs definitions dependentSchemas)
  @listed ~w(allOf anyOf oneOf prefixItems)

  @typedoc "Why a schema was refused before building."
  @type bounds_error ::
          :invalid_schema | :too_deep | :too_many_subschemas | :too_large | :remote_ref

  @doc """
  Checks a server-supplied schema against the bounds in the moduledoc.
  Returns `:ok` or `{:error, reason}`; never raises.

      iex> ConduitMcp.Client.SchemaValidator.check_bounds(%{"type" => "object"})
      :ok

      iex> ConduitMcp.Client.SchemaValidator.check_bounds(%{"$ref" => "http://169.254.169.254/"})
      {:error, :remote_ref}
  """
  @spec check_bounds(term()) :: :ok | {:error, bounds_error()}
  def check_bounds(schema) when is_boolean(schema), do: :ok

  def check_bounds(schema) when is_map(schema) and not is_struct(schema) do
    with :ok <- json_depth(schema, 1),
         {:ok, _count} <- walk(schema, 1, 0) do
      size(schema)
    end
  end

  def check_bounds(_schema), do: {:error, :invalid_schema}

  # Plain JSON nesting, so non-schema values (`default`, `enum`, `const`)
  # cannot hide a deep structure either. Stops at the first level too deep.
  defp json_depth(_term, depth) when depth > @max_json_depth, do: {:error, :too_deep}

  defp json_depth(map, depth) when is_map(map),
    do: all_ok(Map.values(map), &json_depth(&1, depth + 1))

  defp json_depth(list, depth) when is_list(list), do: all_ok(list, &json_depth(&1, depth + 1))
  defp json_depth(_scalar, _depth), do: :ok

  defp all_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp walk(_schema, depth, _count) when depth > @max_depth, do: {:error, :too_deep}

  defp walk(_schema, _depth, count) when count >= @max_subschemas,
    do: {:error, :too_many_subschemas}

  defp walk(schema, _depth, count) when is_boolean(schema), do: {:ok, count + 1}

  defp walk(schema, depth, count) when is_map(schema) do
    with :ok <- local_ref(schema, "$ref"),
         :ok <- local_ref(schema, "$dynamicRef") do
      schema
      |> subschemas()
      |> Enum.reduce_while({:ok, count + 1}, fn sub, {:ok, count} ->
        case walk(sub, depth + 1, count) do
          {:ok, count} -> {:cont, {:ok, count}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp walk(_schema, _depth, _count), do: {:error, :invalid_schema}

  defp local_ref(schema, key) do
    case Map.fetch(schema, key) do
      :error -> :ok
      {:ok, "#" <> _pointer} -> :ok
      {:ok, ref} when is_binary(ref) -> {:error, :remote_ref}
      {:ok, _other} -> {:error, :invalid_schema}
    end
  end

  defp subschemas(schema) do
    Enum.flat_map(schema, fn
      {key, value} when key in @single and (is_map(value) or is_boolean(value)) ->
        [value]

      {"items", value} when is_list(value) ->
        value

      {key, value} when key in @listed and is_list(value) ->
        value

      {key, value} when key in @mapped and is_map(value) ->
        Map.values(value)

      {"dependencies", value} when is_map(value) ->
        for {_key, dep} <- value, is_map(dep) or is_boolean(dep), do: dep

      _other ->
        []
    end)
  end

  defp size(schema) do
    if byte_size(JSON.encode!(schema)) <= @max_bytes, do: :ok, else: {:error, :too_large}
  rescue
    _error -> {:error, :invalid_schema}
  end
end

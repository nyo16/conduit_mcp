defmodule ConduitMcp.Client.Adapters.OpenAI.Strict do
  @moduledoc false
  # The strict-mode schema rewrite behind `ConduitMcp.Client.Adapters.OpenAI.strict_schema/1`
  # and the matching argument clean-up behind `strip_nulls/2`. The rules and
  # their source are in the OpenAI adapter's moduledoc.
  #
  # Three passes over the input:
  #   * `transform/1` rewrites the schema (closes objects, requires every
  #     property, widens optional ones to accept null, drops keywords that
  #     are safe to drop) and throws on constructs it cannot express;
  #   * `check_limits/1` enforces the documented size limits on the output;
  #   * `null_paths/1` walks the *original* schema along instance paths
  #     (following local `$ref`s) and lists where a `null` can only have come
  #     from the rewrite.
  #
  # Paths are built reversed (prepend) and reversed once when reported, so a
  # deep schema costs linear, not quadratic, work. Schema input is untrusted:
  # nesting and `$ref` expansion are bounded.

  @supported_types ["string", "number", "integer", "boolean", "object", "array", "null"]
  @supported_formats ~w(date-time time date duration email hostname ipv4 ipv6 uuid)

  # Keywords that change what an instance may look like and cannot be
  # dropped without changing the tool's contract.
  @unsupported ~w(allOf not oneOf if then else dependentRequired dependentSchemas
                  dependencies patternProperties unevaluatedProperties unevaluatedItems
                  propertyNames prefixItems contains minContains maxContains
                  $dynamicRef $recursiveRef)

  @common_keys ~w(type description title enum const $ref)
  @string_keys ~w(pattern minLength maxLength)
  @number_keys ~w(multipleOf maximum exclusiveMaximum minimum exclusiveMinimum)
  @array_keys ~w(minItems maxItems)
  @kept_keys @common_keys ++ @string_keys ++ @number_keys ++ @array_keys

  @max_properties 5000
  @max_depth 10
  @max_chars 120_000
  @max_enum_values 1000
  @large_enum_threshold 250
  @max_large_enum_chars 15_000

  # Work bounds for untrusted input (not OpenAI limits).
  @max_schema_nesting 64
  @max_null_visits 100_000

  @type schema_path :: [String.t() | non_neg_integer()]
  @type null_path :: [String.t() | :items]
  @type error :: {:unsupported, schema_path(), String.t() | atom()}

  @doc "The documented strict-mode limits."
  @spec limits() :: %{atom() => pos_integer()}
  def limits do
    %{
      max_properties: @max_properties,
      max_depth: @max_depth,
      max_chars: @max_chars,
      max_enum_values: @max_enum_values,
      large_enum_threshold: @large_enum_threshold,
      max_large_enum_chars: @max_large_enum_chars
    }
  end

  @doc "Keywords that make a schema non-convertible."
  @spec unsupported_keywords() :: [String.t()]
  def unsupported_keywords, do: @unsupported

  @doc "Formats strict mode accepts; any other `format` is dropped."
  @spec supported_formats() :: [String.t()]
  def supported_formats, do: @supported_formats

  @doc "Keywords kept on a converted schema node (besides the structural ones)."
  @spec kept_keywords() :: [String.t()]
  def kept_keywords, do: @kept_keys ++ ["format"]

  @spec convert(term()) :: {:ok, map(), [null_path()]} | {:error, error()}
  def convert(schema) do
    strict = transform(schema)
    check_limits(strict)
    {:ok, strict, null_paths(schema)}
  catch
    {:unsupported, _path, _keyword} = error -> {:error, error}
  end

  ## Transform

  defp transform(%{"type" => "object"} = root) do
    if Map.has_key?(root, "anyOf"), do: unsupported([], "anyOf")

    defs =
      for key <- ["$defs", "definitions"], is_map_key(root, key), into: %{} do
        {key, transform_defs(root[key], key)}
      end

    root
    |> Map.drop(["$defs", "definitions"])
    |> node([], 0, true)
    |> Map.merge(defs)
  end

  defp transform(%{"anyOf" => _}), do: unsupported([], "anyOf")
  defp transform(_root), do: unsupported([], "type")

  defp transform_defs(defs, key) when is_map(defs),
    do: Map.new(defs, fn {name, schema} -> {name, node(schema, [name, key], 0, false)} end)

  defp transform_defs(_defs, key), do: unsupported([key], "type")

  defp node(_schema, rpath, nesting, _root?) when nesting > @max_schema_nesting,
    do: unsupported(rpath, :max_depth)

  defp node(schema, rpath, nesting, root?) when is_map(schema) do
    reject_unsupported(schema, rpath)

    if Map.has_key?(schema, "$defs") or Map.has_key?(schema, "definitions"),
      do: unsupported(rpath, "$defs")

    types = types(schema, rpath)

    if types == [] and
         not Enum.any?(["enum", "const", "anyOf", "$ref"], &Map.has_key?(schema, &1)),
       do: unsupported(rpath, "type")

    schema
    |> Map.take(@kept_keys)
    |> keep_format(schema)
    |> check_enum(schema, rpath)
    |> check_ref(rpath)
    |> any_of(schema, rpath, nesting)
    |> object(schema, types, rpath, nesting, root?)
    |> array(schema, types, rpath, nesting)
  end

  defp node(_schema, rpath, _nesting, _root?), do: unsupported(rpath, "type")

  defp reject_unsupported(schema, rpath) do
    case Enum.find(@unsupported, &Map.has_key?(schema, &1)) do
      nil -> :ok
      keyword -> unsupported(rpath, keyword)
    end
  end

  defp types(%{"type" => type}, rpath) when is_binary(type), do: types(%{"type" => [type]}, rpath)

  defp types(%{"type" => types}, rpath) when is_list(types) and types != [] do
    if Enum.all?(types, &(&1 in @supported_types)) and Enum.uniq(types) == types,
      do: types,
      else: unsupported(rpath, "type")
  end

  defp types(%{"type" => _}, rpath), do: unsupported(rpath, "type")
  defp types(_schema, _rpath), do: []

  defp keep_format(out, %{"format" => format}) when format in @supported_formats,
    do: Map.put(out, "format", format)

  defp keep_format(out, _schema), do: out

  defp check_enum(out, %{"enum" => values}, _rpath) when is_list(values) and values != [], do: out
  defp check_enum(_out, %{"enum" => _}, rpath), do: unsupported(rpath, "enum")
  defp check_enum(out, _schema, _rpath), do: out

  defp check_ref(%{"$ref" => ref} = out, rpath) do
    if local_ref?(ref), do: out, else: unsupported(rpath, "$ref")
  end

  defp check_ref(out, _rpath), do: out

  defp any_of(out, %{"anyOf" => branches}, rpath, nesting)
       when is_list(branches) and branches != [] do
    walked =
      branches
      |> Enum.with_index()
      |> Enum.map(fn {branch, i} -> node(branch, [i, "anyOf" | rpath], nesting + 1, false) end)

    Map.put(out, "anyOf", walked)
  end

  defp any_of(_out, %{"anyOf" => _}, rpath, _nesting), do: unsupported(rpath, "anyOf")
  defp any_of(out, _schema, _rpath, _nesting), do: out

  defp object(out, schema, types, rpath, nesting, root?) do
    if "object" in types, do: close_object(out, schema, rpath, nesting, root?), else: out
  end

  defp close_object(out, schema, rpath, nesting, root?) do
    case schema do
      %{"additionalProperties" => false} -> :ok
      %{"additionalProperties" => _} -> unsupported(rpath, "additionalProperties")
      %{"properties" => _} -> :ok
      _ when root? -> :ok
      _ -> unsupported(rpath, "additionalProperties")
    end

    properties =
      case Map.get(schema, "properties", %{}) do
        props when is_map(props) -> props
        _ -> unsupported(rpath, "properties")
      end

    required =
      case Map.get(schema, "required", []) do
        list when is_list(list) -> list
        _ -> unsupported(rpath, "required")
      end

    strict_props =
      Map.new(properties, fn {name, sub} ->
        converted = node(sub, [name, "properties" | rpath], nesting + 1, false)

        if name in required or allows_null?(sub),
          do: {name, converted},
          else: {name, nullable(converted)}
      end)

    Map.merge(out, %{
      "properties" => strict_props,
      "required" => strict_props |> Map.keys() |> Enum.sort(),
      "additionalProperties" => false
    })
  end

  defp array(out, schema, types, rpath, nesting) do
    cond do
      "array" not in types ->
        out

      is_map(schema["items"]) ->
        Map.put(out, "items", node(schema["items"], ["items" | rpath], nesting + 1, false))

      true ->
        unsupported(rpath, "items")
    end
  end

  # Widens a converted schema so `null` validates.
  defp nullable(%{"type" => type} = schema) when is_binary(type),
    do: nullable(%{schema | "type" => [type]})

  defp nullable(%{"type" => types} = schema)
       when is_list(types) and not is_map_key(schema, "anyOf") and
              not is_map_key(schema, "const") and not is_map_key(schema, "$ref") do
    schema = %{schema | "type" => types ++ ["null"]}

    if Map.has_key?(schema, "enum"),
      do: Map.update!(schema, "enum", &(&1 ++ [nil])),
      else: schema
  end

  defp nullable(%{"enum" => values} = schema)
       when not is_map_key(schema, "type") and not is_map_key(schema, "anyOf") and
              not is_map_key(schema, "$ref") and not is_map_key(schema, "const"),
       do: %{schema | "enum" => values ++ [nil]}

  defp nullable(%{"anyOf" => branches} = schema) when map_size(schema) == 1,
    do: %{"anyOf" => branches ++ [%{"type" => "null"}]}

  defp nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  # Whether the original (pre-rewrite) schema already admits `null`, in
  # which case a `null` argument is the model's real answer and is kept.
  defp allows_null?(%{"type" => "null"}), do: true
  defp allows_null?(%{"type" => types}) when is_list(types), do: "null" in types
  defp allows_null?(%{"enum" => values}) when is_list(values), do: nil in values
  defp allows_null?(%{"const" => nil}), do: true

  defp allows_null?(%{"anyOf" => branches}) when is_list(branches),
    do: Enum.any?(branches, &allows_null?/1)

  defp allows_null?(_schema), do: false

  defp local_ref?("#"), do: true
  defp local_ref?("#/$defs/" <> name), do: name != "" and not String.contains?(name, "/")
  defp local_ref?("#/definitions/" <> name), do: name != "" and not String.contains?(name, "/")
  defp local_ref?(_ref), do: false

  ## Limits

  defp check_limits(strict) do
    stats = walk_stats(strict, [], 0, %{props: 0, chars: 0, enums: 0})

    cond do
      stats.props > @max_properties -> unsupported([], :max_properties)
      stats.chars > @max_chars -> unsupported([], :max_chars)
      stats.enums > @max_enum_values -> unsupported([], :max_enum_values)
      true -> :ok
    end
  end

  defp walk_stats(schema, rpath, depth, acc) when is_map(schema) do
    depth = if Map.has_key?(schema, "properties"), do: depth + 1, else: depth
    if depth > @max_depth, do: unsupported(rpath, :max_depth)

    acc = acc |> enum_stats(schema, rpath) |> const_stats(schema)

    acc =
      Enum.reduce(Map.get(schema, "properties", %{}), acc, fn {name, sub}, acc ->
        acc = %{acc | props: acc.props + 1, chars: acc.chars + String.length(name)}
        walk_stats(sub, [name, "properties" | rpath], depth, acc)
      end)

    acc =
      case schema do
        %{"items" => items} -> walk_stats(items, ["items" | rpath], depth, acc)
        _ -> acc
      end

    acc =
      schema
      |> Map.get("anyOf", [])
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {branch, i}, acc ->
        walk_stats(branch, [i, "anyOf" | rpath], depth, acc)
      end)

    for key <- ["$defs", "definitions"],
        defs = schema[key],
        is_map(defs),
        {name, sub} <- defs,
        reduce: acc do
      acc -> walk_stats(sub, [name, key], 0, %{acc | chars: acc.chars + String.length(name)})
    end
  end

  defp walk_stats(_schema, _rpath, _depth, acc), do: acc

  defp enum_stats(acc, %{"enum" => values}, rpath) when is_list(values) do
    strings = for value <- values, is_binary(value), do: String.length(value)
    total = Enum.sum(strings)

    if length(strings) > @large_enum_threshold and total > @max_large_enum_chars,
      do: unsupported(rpath, :max_enum_chars)

    %{acc | enums: acc.enums + length(values), chars: acc.chars + total}
  end

  defp enum_stats(acc, _schema, _rpath), do: acc

  defp const_stats(acc, %{"const" => value}) when is_binary(value),
    do: %{acc | chars: acc.chars + String.length(value)}

  defp const_stats(acc, _schema), do: acc

  ## Null paths

  defp null_paths(root) do
    %{strip: strip, keep: keep} =
      nulls(root, %{root: root, ipath: [], rpath: [], stack: []}, %{
        strip: MapSet.new(),
        keep: MapSet.new(),
        visits: 0
      })

    strip
    |> MapSet.difference(keep)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.sort()
  end

  # `ctx.ipath` is the reversed instance path; `ctx.rpath` the reversed
  # schema path (for errors); `ctx.stack` the `$ref`s being expanded. Every
  # visited node counts toward `@max_null_visits`, which bounds `$ref`
  # fan-out (a chain of definitions each referencing the next twice would
  # otherwise expand exponentially).
  defp nulls(_schema, ctx, %{visits: visits}) when visits > @max_null_visits,
    do: unsupported(ctx.rpath, "$ref")

  defp nulls(%{"$ref" => ref} = schema, ctx, acc) do
    acc = nulls_children(Map.delete(schema, "$ref"), ctx, %{acc | visits: acc.visits + 1})
    target = resolve!(ctx.root, ref, ctx.rpath)

    cond do
      ref not in ctx.stack ->
        nulls(target, %{ctx | stack: [ref | ctx.stack]}, acc)

      optional_reachable?(target, ctx.root, MapSet.new([ref])) ->
        unsupported(ctx.rpath, "$ref")

      true ->
        acc
    end
  end

  defp nulls(schema, ctx, acc) when is_map(schema),
    do: nulls_children(schema, ctx, %{acc | visits: acc.visits + 1})

  defp nulls(_schema, _ctx, acc), do: acc

  defp nulls_children(schema, ctx, acc) do
    acc
    |> nulls_properties(schema, ctx)
    |> nulls_items(schema, ctx)
    |> nulls_any_of(schema, ctx)
  end

  defp nulls_properties(acc, %{"properties" => props} = schema, ctx) when is_map(props) do
    required = if is_list(schema["required"]), do: schema["required"], else: []

    Enum.reduce(props, acc, fn {name, sub}, acc ->
      ipath = [name | ctx.ipath]

      acc =
        cond do
          allows_null?(sub) -> %{acc | keep: MapSet.put(acc.keep, ipath)}
          name in required -> acc
          true -> %{acc | strip: MapSet.put(acc.strip, ipath)}
        end

      nulls(sub, %{ctx | ipath: ipath, rpath: [name, "properties" | ctx.rpath]}, acc)
    end)
  end

  defp nulls_properties(acc, _schema, _ctx), do: acc

  defp nulls_items(acc, %{"items" => items}, ctx) when is_map(items),
    do: nulls(items, %{ctx | ipath: [:items | ctx.ipath], rpath: ["items" | ctx.rpath]}, acc)

  defp nulls_items(acc, _schema, _ctx), do: acc

  defp nulls_any_of(acc, %{"anyOf" => branches}, ctx) when is_list(branches) do
    branches
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {branch, i}, acc ->
      nulls(branch, %{ctx | rpath: [i, "anyOf" | ctx.rpath]}, acc)
    end)
  end

  defp nulls_any_of(acc, _schema, _ctx), do: acc

  # Whether any object reachable from `schema` has an optional property the
  # rewrite makes nullable. Used only for recursive `$ref`s, whose instance
  # paths are unbounded and so cannot be listed. Each `$ref` is explored at
  # most once (`seen` is threaded through), so this is linear in the schema.
  defp optional_reachable?(schema, root, seen),
    do: schema |> optional?(root, seen) |> elem(0)

  defp optional?(schema, root, seen) when is_map(schema) do
    required = if is_list(schema["required"]), do: schema["required"], else: []
    props = if is_map(schema["properties"]), do: schema["properties"], else: %{}

    if Enum.any?(props, fn {name, sub} -> name not in required and not allows_null?(sub) end) do
      {true, seen}
    else
      children =
        Map.values(props) ++
          [schema["items"]] ++ List.wrap(schema["anyOf"]) ++ [{:ref, schema["$ref"]}]

      Enum.reduce_while(children, {false, seen}, fn child, {false, seen} ->
        case optional?(child, root, seen) do
          {true, seen} -> {:halt, {true, seen}}
          {false, seen} -> {:cont, {false, seen}}
        end
      end)
    end
  end

  defp optional?({:ref, ref}, root, seen) when is_binary(ref) do
    if MapSet.member?(seen, ref),
      do: {false, seen},
      else: optional?(resolve!(root, ref, []), root, MapSet.put(seen, ref))
  end

  defp optional?(_schema, _root, seen), do: {false, seen}

  defp resolve!(root, "#", _rpath), do: root

  defp resolve!(root, "#/" <> pointer, rpath) do
    with [key, name] <- String.split(pointer, "/", parts: 2),
         %{^key => %{^name => schema}} <- root do
      schema
    else
      _ -> unsupported(rpath, "$ref")
    end
  end

  defp resolve!(_root, _ref, rpath), do: unsupported(rpath, "$ref")

  defp unsupported(rpath, keyword), do: throw({:unsupported, Enum.reverse(rpath), keyword})

  ## Null stripping

  @spec strip_nulls(term(), [null_path()]) :: term()
  def strip_nulls(args, []), do: args

  def strip_nulls(args, paths) do
    trie = Enum.reduce(paths, %{}, &insert(&2, &1))
    strip(args, trie)
  end

  defp insert(trie, [segment]) do
    Map.update(trie, segment, {true, %{}}, fn {_terminal, child} -> {true, child} end)
  end

  defp insert(trie, [segment | rest]) do
    {terminal, child} = Map.get(trie, segment, {false, %{}})
    Map.put(trie, segment, {terminal, insert(child, rest)})
  end

  defp strip(map, trie) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case Map.fetch(trie, key) do
        {:ok, {true, _child}} when is_nil(value) -> acc
        {:ok, {_terminal, child}} -> Map.put(acc, key, strip(value, child))
        :error -> Map.put(acc, key, value)
      end
    end)
  end

  defp strip(list, trie) when is_list(list) do
    case Map.fetch(trie, :items) do
      {:ok, {_terminal, child}} -> Enum.map(list, &strip(&1, child))
      :error -> list
    end
  end

  defp strip(value, _trie), do: value
end

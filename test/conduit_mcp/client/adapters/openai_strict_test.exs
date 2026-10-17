defmodule ConduitMcp.Client.Adapters.OpenAIStrictTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.Adapters.OpenAI

  # An independent reading of the strict-mode rules (structured-outputs
  # guide, "Supported schemas"), used to check `strict_schema/1`'s output.
  @types ~w(string number integer boolean object array null)
  @formats ~w(date-time time date duration email hostname ipv4 ipv6 uuid)
  @node_keys ~w(type description title enum const anyOf $ref properties required
                additionalProperties items pattern format minLength maxLength multipleOf
                maximum exclusiveMaximum minimum exclusiveMinimum minItems maxItems)

  defp strict_valid?(%{"type" => "object"} = root) do
    not Map.has_key?(root, "anyOf") and
      node_valid?(Map.drop(root, ["$defs", "definitions"])) and
      Enum.all?(["$defs", "definitions"], fn key ->
        root |> Map.get(key, %{}) |> Map.values() |> Enum.all?(&node_valid?/1)
      end) and
      limits_ok?(root)
  end

  defp strict_valid?(_root), do: false

  defp node_valid?(node) when is_map(node) do
    types = node |> Map.get("type", []) |> List.wrap()

    Enum.all?(Map.keys(node), &(&1 in @node_keys)) and
      Enum.all?(types, &(&1 in @types)) and
      (types != [] or Enum.any?(["enum", "const", "anyOf", "$ref"], &Map.has_key?(node, &1))) and
      (not Map.has_key?(node, "format") or node["format"] in @formats) and
      (not Map.has_key?(node, "$ref") or local_ref?(node["$ref"])) and
      object_valid?(node, types) and
      array_valid?(node, types) and
      node |> Map.get("anyOf", []) |> Enum.all?(&node_valid?/1)
  end

  defp node_valid?(_node), do: false

  defp object_valid?(node, types) do
    if "object" in types do
      props = node["properties"]

      is_map(props) and node["additionalProperties"] == false and
        Enum.sort(node["required"]) == Enum.sort(Map.keys(props)) and
        Enum.all?(Map.values(props), &node_valid?/1)
    else
      not Map.has_key?(node, "properties")
    end
  end

  defp array_valid?(node, types) do
    if "array" in types,
      do: is_map(node["items"]) and node_valid?(node["items"]),
      else: not Map.has_key?(node, "items")
  end

  defp local_ref?(ref), do: ref == "#" or String.starts_with?(ref, ["#/$defs/", "#/definitions/"])

  defp limits_ok?(root) do
    {props, depth} = count(root, 0)
    props <= 5000 and depth <= 10
  end

  defp count(node, depth) when is_map(node) do
    depth = if Map.has_key?(node, "properties"), do: depth + 1, else: depth

    children =
      Map.values(Map.get(node, "properties", %{})) ++
        List.wrap(node["items"]) ++ Map.get(node, "anyOf", [])

    Enum.reduce(children, {map_size(Map.get(node, "properties", %{})), depth}, fn child, {p, d} ->
      {cp, cd} = count(child, depth)
      {p + cp, max(d, cd)}
    end)
  end

  ## Generators

  defp leaf do
    member_of([
      %{"type" => "string"},
      %{"type" => "integer", "minimum" => 0},
      %{"type" => "number"},
      %{"type" => "boolean"},
      %{"type" => ["string", "null"]},
      %{"enum" => ["a", "b"]},
      %{"type" => "string", "enum" => ["x", "y"]},
      %{"const" => "fixed"},
      %{"type" => "string", "format" => "uri", "default" => "d"},
      %{"type" => "string", "format" => "email", "examples" => ["e"]},
      %{"$ref" => "#/$defs/name"},
      %{"type" => "array", "items" => %{"type" => "string"}, "uniqueItems" => true},
      # unsupported or unexpressible
      %{},
      %{"description" => "anything"},
      %{"oneOf" => [%{"type" => "string"}]},
      %{"type" => "string", "not" => %{"const" => "x"}},
      %{"type" => "object"},
      %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
      %{"type" => "array"},
      %{"$ref" => "https://example.com/schema.json"}
    ])
  end

  defp schema_tree do
    tree(leaf(), fn child ->
      one_of([
        object_of(child),
        map(child, &%{"type" => "array", "items" => &1}),
        map(list_of(child, min_length: 1, max_length: 3), &%{"anyOf" => &1})
      ])
    end)
  end

  defp object_of(child) do
    gen all(
          props <- map(list_of({member_of(~w(a b c d)), child}, max_length: 4), &Map.new/1),
          required <- list_of(member_of(~w(a b c d x)), max_length: 4),
          closed <- member_of([:missing, false, true])
        ) do
      base = %{"type" => "object", "properties" => props, "required" => Enum.uniq(required)}

      case closed do
        :missing -> base
        value -> Map.put(base, "additionalProperties", value)
      end
    end
  end

  defp root_schema do
    gen all(
          root <- object_of(schema_tree()),
          with_defs <- boolean()
        ) do
      if with_defs, do: Map.put(root, "$defs", %{"name" => %{"type" => "string"}}), else: root
    end
  end

  property "output is valid under the strict rules, or an explicit :unsupported at a real path" do
    check all(schema <- root_schema(), max_runs: 300) do
      case OpenAI.strict_schema(schema) do
        {:ok, strict, null_paths} ->
          assert strict_valid?(strict), "not strict-valid: #{inspect(strict)}"
          assert Enum.all?(null_paths, &is_list/1)

        {:error, {:unsupported, path, keyword}} ->
          assert is_binary(keyword) or is_atom(keyword)
          assert is_map(get_in_path(schema, path)), "#{inspect(path)} not in #{inspect(schema)}"
      end
    end
  end

  defp get_in_path(value, []), do: value
  defp get_in_path(map, [key | rest]) when is_map(map), do: get_in_path(Map.get(map, key), rest)
  defp get_in_path(list, [i | rest]) when is_list(list), do: get_in_path(Enum.at(list, i), rest)
  defp get_in_path(_value, _path), do: nil

  ## Null-strip round trip

  # A shape describes a convertible schema and lets us build instances.
  defp shape_tree do
    scalar =
      member_of([{:scalar, "string"}, {:scalar, "integer"}, {:scalar, "boolean"}, :nullable])

    tree(scalar, fn child ->
      one_of([
        map(list_of({member_of(~w(a b c d)), boolean(), child}, max_length: 4), fn props ->
          {:object, Enum.uniq_by(props, &elem(&1, 0))}
        end),
        map(child, &{:array, &1})
      ])
    end)
  end

  defp root_shape do
    map(list_of({member_of(~w(p q r s)), boolean(), shape_tree()}, max_length: 4), fn props ->
      {:object, Enum.uniq_by(props, &elem(&1, 0))}
    end)
  end

  defp to_schema({:scalar, type}), do: %{"type" => type}
  defp to_schema(:nullable), do: %{"type" => ["string", "null"]}
  defp to_schema({:array, item}), do: %{"type" => "array", "items" => to_schema(item)}

  defp to_schema({:object, props}) do
    %{
      "type" => "object",
      "properties" => Map.new(props, fn {name, _req, shape} -> {name, to_schema(shape)} end),
      "required" => for({name, true, _} <- props, do: name)
    }
  end

  # Generates {what a strict-mode model sends, what stripping must give}.
  # The expected value is the args the model meant, except that an omitted
  # optional property whose schema already allows null stays `null`: that
  # null is a valid value, so it is never stripped.
  defp instance({:scalar, "string"}), do: map(string(:alphanumeric, max_length: 3), &{&1, &1})
  defp instance({:scalar, "integer"}), do: map(integer(), &{&1, &1})
  defp instance({:scalar, "boolean"}), do: map(boolean(), &{&1, &1})

  defp instance(:nullable),
    do: map(one_of([constant(nil), string(:alphanumeric, max_length: 3)]), &{&1, &1})

  defp instance({:array, item}) do
    map(list_of(instance(item), max_length: 3), fn pairs ->
      {Enum.map(pairs, &elem(&1, 0)), Enum.map(pairs, &elem(&1, 1))}
    end)
  end

  defp instance({:object, props}) do
    props
    |> Enum.map(fn {name, required, shape} ->
      value = instance(shape)
      value = if required, do: value, else: one_of([constant({:omitted, shape}), value])
      map(value, &{name, &1})
    end)
    |> fixed_list()
    |> map(fn entries ->
      # Strict mode requires every property, so the model sends `null` for
      # one it would have left out.
      sent =
        Map.new(entries, fn
          {name, {:omitted, _shape}} -> {name, nil}
          {name, {sent, _expected}} -> {name, sent}
        end)

      expected =
        for {name, value} <- entries, reduce: %{} do
          acc ->
            case value do
              {:omitted, :nullable} -> Map.put(acc, name, nil)
              {:omitted, _shape} -> acc
              {_sent, expected} -> Map.put(acc, name, expected)
            end
        end

      {sent, expected}
    end)
  end

  property "null-strip round trip: stripping the model's nulls restores the intended args" do
    check all(
            shape <- root_shape(),
            {sent, expected} <- instance(shape),
            max_runs: 300
          ) do
      {:ok, strict, null_paths} = OpenAI.strict_schema(to_schema(shape))
      assert strict_valid?(strict)
      assert OpenAI.strip_nulls(sent, null_paths) == expected
    end
  end

  describe "strict_schema/1 cases" do
    test "nested objects, arrays, $defs, recursion without optional fields" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "items" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{"id" => %{"type" => "integer"}, "note" => %{"type" => "string"}},
              "required" => ["id"]
            }
          },
          "owner" => %{"$ref" => "#/$defs/person"},
          "tree" => %{"$ref" => "#/$defs/node"}
        },
        "required" => ["items", "tree"],
        "$defs" => %{
          "person" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
          "node" => %{
            "type" => "object",
            "properties" => %{
              "children" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/node"}}
            },
            "required" => ["children"]
          }
        }
      }

      assert {:ok, strict, paths} = OpenAI.strict_schema(schema)
      assert strict_valid?(strict)

      assert strict["properties"]["owner"] == %{
               "anyOf" => [%{"$ref" => "#/$defs/person"}, %{"type" => "null"}]
             }

      assert strict["$defs"]["person"]["properties"]["name"] == %{"type" => ["string", "null"]}

      assert paths == [
               ["items", :items, "note"],
               ["owner"],
               ["owner", "name"]
             ]
    end

    test "a recursive $ref with optional fields is unsupported" do
      schema = %{
        "type" => "object",
        "properties" => %{"tree" => %{"$ref" => "#/$defs/node"}},
        "required" => ["tree"],
        "$defs" => %{
          "node" => %{
            "type" => "object",
            "properties" => %{"child" => %{"$ref" => "#/$defs/node"}}
          }
        }
      }

      assert OpenAI.strict_schema(schema) ==
               {:error, {:unsupported, ["properties", "tree", "properties", "child"], "$ref"}}
    end

    test "optional enum, const and anyOf properties become nullable" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "unit" => %{"type" => "string", "enum" => ["C", "F"]},
          "bare" => %{"enum" => [1, 2]},
          "fixed" => %{"const" => "x"},
          "either" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]},
          "maybe" => %{"type" => ["integer", "null"]}
        }
      }

      assert {:ok, strict, paths} = OpenAI.strict_schema(schema)
      props = strict["properties"]
      assert props["unit"] == %{"type" => ["string", "null"], "enum" => ["C", "F", nil]}
      assert props["bare"] == %{"enum" => [1, 2, nil]}
      assert props["fixed"] == %{"anyOf" => [%{"const" => "x"}, %{"type" => "null"}]}

      assert props["either"] == %{
               "anyOf" => [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "null"}]
             }

      assert props["maybe"] == %{"type" => ["integer", "null"]}
      assert paths == [["bare"], ["either"], ["fixed"], ["unit"]]
    end

    test "root and open-map failures" do
      assert OpenAI.strict_schema(%{"type" => "string"}) == {:error, {:unsupported, [], "type"}}
      assert OpenAI.strict_schema(%{"anyOf" => []}) == {:error, {:unsupported, [], "anyOf"}}

      assert OpenAI.strict_schema(%{"type" => "object", "additionalProperties" => true}) ==
               {:error, {:unsupported, [], "additionalProperties"}}

      assert OpenAI.strict_schema(%{
               "type" => "object",
               "properties" => %{"m" => %{"type" => "object"}}
             }) == {:error, {:unsupported, ["properties", "m"], "additionalProperties"}}

      assert {:ok, %{"properties" => %{}, "required" => [], "additionalProperties" => false}, []} =
               OpenAI.strict_schema(%{"type" => "object"})
    end

    test "limits: properties, nesting, enum values, characters" do
      wide = %{
        "type" => "object",
        "properties" => Map.new(1..5001, &{"p#{&1}", %{"type" => "string"}})
      }

      assert OpenAI.strict_schema(wide) == {:error, {:unsupported, [], :max_properties}}

      deep =
        Enum.reduce(1..10, %{"type" => "string"}, fn _, inner ->
          %{"type" => "object", "properties" => %{"x" => inner}, "required" => ["x"]}
        end)

      assert {:ok, _, []} = OpenAI.strict_schema(deep)

      too_deep = %{"type" => "object", "properties" => %{"x" => deep}, "required" => ["x"]}
      assert {:error, {:unsupported, path, :max_depth}} = OpenAI.strict_schema(too_deep)
      assert length(path) == 20

      enums = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"enum" => Enum.to_list(1..600)},
          "b" => %{"enum" => Enum.to_list(1..401)}
        },
        "required" => ["a", "b"]
      }

      assert OpenAI.strict_schema(enums) == {:error, {:unsupported, [], :max_enum_values}}

      big_enum = %{
        "type" => "object",
        "properties" => %{
          "e" => %{"enum" => Enum.map(1..251, &String.duplicate("#{rem(&1, 10)}", 60))}
        },
        "required" => ["e"]
      }

      assert OpenAI.strict_schema(big_enum) ==
               {:error, {:unsupported, ["properties", "e"], :max_enum_chars}}

      long_names = %{
        "type" => "object",
        "properties" =>
          Map.new(1..121, &{String.duplicate("n", 995) <> "#{&1 + 100}", %{"type" => "string"}})
      }

      assert OpenAI.strict_schema(long_names) == {:error, {:unsupported, [], :max_chars}}
    end

    test "exponential $ref fan-out is bounded" do
      defs =
        Map.new(0..40, fn i ->
          next = %{"$ref" => "#/$defs/d#{i + 1}"}

          {"d#{i}",
           %{
             "type" => "object",
             "properties" => %{"l" => next, "r" => next},
             "required" => ["l", "r"]
           }}
        end)
        |> Map.put("d41", %{"type" => "string"})

      schema = %{
        "type" => "object",
        "properties" => %{"root" => %{"$ref" => "#/$defs/d0"}},
        "$defs" => defs
      }

      assert {:error, {:unsupported, _path, "$ref"}} = OpenAI.strict_schema(schema)
    end

    test "a pathologically nested schema is rejected without deep work" do
      nested =
        Enum.reduce(1..5000, %{"type" => "string"}, fn _, inner ->
          %{"type" => "array", "items" => inner}
        end)

      schema = %{"type" => "object", "properties" => %{"x" => nested}, "required" => ["x"]}
      assert {:error, {:unsupported, _path, :max_depth}} = OpenAI.strict_schema(schema)
    end
  end
end

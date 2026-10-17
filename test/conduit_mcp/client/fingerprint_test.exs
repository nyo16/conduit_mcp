defmodule ConduitMcp.Client.FingerprintTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.{Fingerprint, Tool}

  doctest ConduitMcp.Client.Fingerprint

  @definition %{
    "name" => "search",
    "title" => "Search",
    "description" => "Search the index.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{"q" => %{"type" => "string"}, "limit" => %{"type" => "integer"}},
      "required" => ["q"]
    },
    "outputSchema" => %{"type" => "object"},
    "annotations" => %{"readOnlyHint" => true},
    "execution" => %{"taskSupport" => "optional"},
    "_meta" => %{"vendor/x" => 1}
  }

  # Same definition, keys in a different order at every level, as a server
  # would send it.
  @reordered_json """
  {"_meta":{"vendor/x":1},"execution":{"taskSupport":"optional"},
   "annotations":{"readOnlyHint":true},"outputSchema":{"type":"object"},
   "inputSchema":{"required":["q"],"properties":{"limit":{"type":"integer"},
   "q":{"type":"string"}},"type":"object"},
   "description":"Search the index.","title":"Search","name":"search"}
  """

  test "is lower-case hex SHA-256" do
    assert Fingerprint.compute(@definition) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "key reorder gives the same fingerprint (PO-6)" do
    assert Fingerprint.compute(JSON.decode!(@reordered_json)) == Fingerprint.compute(@definition)
  end

  test "a whitespace change in the description gives a different fingerprint (PO-6)" do
    changed = %{@definition | "description" => "Search the  index."}
    refute Fingerprint.compute(changed) == Fingerprint.compute(@definition)

    trailing = %{@definition | "description" => "Search the index.\n"}
    refute Fingerprint.compute(trailing) == Fingerprint.compute(@definition)
  end

  test "every covered field changes the fingerprint" do
    base = Fingerprint.compute(@definition)

    for field <- Fingerprint.fields() do
      refute Fingerprint.compute(Map.put(@definition, field, "changed")) == base, field
      refute Fingerprint.compute(Map.delete(@definition, field)) == base, field
    end
  end

  test "keys outside the covered fields are ignored" do
    with_icons = Map.put(@definition, "icons", [%{"src" => "https://x/icon.png"}])
    assert Fingerprint.compute(with_icons) == Fingerprint.compute(@definition)
  end

  test "an absent field and a null field hash alike" do
    assert Fingerprint.compute(Map.put(@definition, "title", nil)) ==
             Fingerprint.compute(Map.delete(@definition, "title"))
  end

  test "a Tool hashes its raw wire definition" do
    {:ok, tool} = Tool.from_wire("srv", @definition)
    assert Fingerprint.compute(tool) == Fingerprint.compute(@definition)
  end

  test "a value type change is a different fingerprint" do
    refute Fingerprint.compute(%{"name" => "t", "_meta" => %{"n" => 1}}) ==
             Fingerprint.compute(%{"name" => "t", "_meta" => %{"n" => "1"}})
  end

  property "stable under random key permutation of nested objects" do
    check all(
            inner <- json_object(),
            seed <- {integer(1..1_000_000), integer(1..1_000_000), integer(1..1_000_000)}
          ) do
      definition = %{
        "name" => "t",
        "inputSchema" => inner,
        "annotations" => inner,
        "_meta" => %{"nested" => inner}
      }

      :rand.seed(:exsss, seed)
      decoded = definition |> shuffled_json() |> IO.iodata_to_binary() |> JSON.decode!()

      assert Fingerprint.compute(decoded) == Fingerprint.compute(definition)
    end
  end

  defp json_object do
    leaf = one_of([integer(), boolean(), string(:printable, max_length: 8), constant(nil)])

    tree =
      tree(leaf, fn child ->
        one_of([
          list_of(child, max_length: 4),
          map_of(string(:alphanumeric, min_length: 1, max_length: 6), child, max_length: 5)
        ])
      end)

    map_of(string(:alphanumeric, min_length: 1, max_length: 6), tree, max_length: 6)
  end

  # JSON text with object members in a random order at every level.
  defp shuffled_json(map) when is_map(map) do
    members =
      map
      |> Enum.shuffle()
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ?:, shuffled_json(value)] end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp shuffled_json(list) when is_list(list),
    do: [?[, list |> Enum.map(&shuffled_json/1) |> Enum.intersperse(?,), ?]]

  defp shuffled_json(scalar), do: JSON.encode!(scalar)
end

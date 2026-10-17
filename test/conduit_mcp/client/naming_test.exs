defmodule ConduitMcp.Client.NamingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.{Naming, Tool, ToolSet}

  doctest ConduitMcp.Client.Naming

  @exposed ~r/\A[A-Za-z0-9_-]{1,64}\z/

  defp tool(server_id, name) do
    {:ok, tool} =
      Tool.from_wire(server_id, %{"name" => name, "inputSchema" => %{"type" => "object"}})

    tool
  end

  defp tools(server_id, names), do: Enum.map(names, &tool(server_id, &1))

  defp hex8(server_id, name) do
    :crypto.hash(:sha256, server_id <> <<0>> <> name)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  describe "build/2" do
    test "namespaces tools in server order, then tool order" do
      {toolset, report} =
        Naming.build([
          {"github", tools("github", ["create_issue", "search"])},
          {"files", tools("files", ["read", "fs.write"])}
        ])

      assert ToolSet.names(toolset) ==
               ["github__create_issue", "github__search", "files__read", "files__fs_write"]

      assert report == %{rejected: [], collisions: []}

      assert {:ok, %Tool{server_id: "files", name: "fs.write"}} =
               ToolSet.resolve(toolset, "files__fs_write")

      assert ToolSet.exposed_name(toolset, "files", "fs.write") == {:ok, "files__fs_write"}
      assert ToolSet.size(toolset) == 4
    end

    test "resolution is a table lookup: an embedded `__` never reaches another server" do
      {toolset, _} =
        Naming.build([
          {"a", tools("a", ["b__c"])},
          {"b", tools("b", ["c"])}
        ])

      assert {:ok, %Tool{server_id: "a", name: "b__c"}} = ToolSet.resolve(toolset, "a__b__c")
      assert {:ok, %Tool{server_id: "b", name: "c"}} = ToolSet.resolve(toolset, "b__c")
      assert ToolSet.resolve(toolset, "a__c") == :error
      assert ToolSet.resolve(toolset, "c") == :error
      assert ToolSet.resolve(toolset, nil) == :error
    end

    test "PO-4: names outside the spec charset are rejected before mangling" do
      bad = [
        # Cyrillic "е" homoglyph
        "r\u0435ad",
        # zero-width space
        "read\u200B",
        # right-to-left override
        "\u202Eread",
        String.duplicate("a", 129),
        "",
        "read file"
      ]

      {toolset, report} = Naming.build([{"files", tools("files", ["ok" | bad])}])

      assert ToolSet.names(toolset) == ["files__ok"]
      assert report.rejected == Enum.map(bad, &{"files", &1, :invalid_name})
      assert report.collisions == []
    end

    test "a 128-character name is accepted (and truncated)" do
      name = String.duplicate("a", 128)
      {toolset, %{rejected: []}} = Naming.build([{"files", [tool("files", name)]}])
      assert ToolSet.names(toolset) == ["trunc_" <> hex8("files", name)]
    end

    test "HB-2: `a.b` and `a_b` collide, so both are excluded" do
      {toolset, report} = Naming.build([{"srv", tools("srv", ["a.b", "keep", "a_b"])}])

      assert ToolSet.names(toolset) == ["srv__keep"]
      assert report.collisions == [{"srv__a_b", [{"srv", "a.b"}, {"srv", "a_b"}]}]
      assert report.rejected == [{"srv", "a.b", :collision}, {"srv", "a_b", :collision}]
      assert ToolSet.resolve(toolset, "srv__a_b") == :error
    end

    test "a tool listed twice by one server is excluded entirely" do
      {toolset, report} = Naming.build([{"srv", tools("srv", ["dup", "dup"])}])
      assert ToolSet.size(toolset) == 0
      assert report.collisions == [{"srv__dup", [{"srv", "dup"}, {"srv", "dup"}]}]
    end

    test "over-length names become trunc_<8 hex of sha256(server_id <> 0 <> tool)>" do
      long = String.duplicate("x", 70)
      {toolset, _} = Naming.build([{"files", tools("files", [long, "short"])}])

      assert ToolSet.names(toolset) == ["trunc_" <> hex8("files", long), "files__short"]
      assert {:ok, %Tool{name: ^long}} = ToolSet.resolve(toolset, "trunc_" <> hex8("files", long))
    end

    test "the 64-byte boundary: 64 stays, 65 truncates" do
      fits = String.duplicate("y", 64 - byte_size("files__"))
      over = fits <> "y"
      {toolset, _} = Naming.build([{"files", tools("files", [fits, over])}])

      assert ToolSet.names(toolset) == ["files__" <> fits, "trunc_" <> hex8("files", over)]
    end

    test "HB-1: a truncation collision exposes neither tool" do
      long = String.duplicate("z", 80)
      {toolset, report} = Naming.build([{"srv", tools("srv", [long, "ok", long])}])

      assert ToolSet.names(toolset) == ["srv__ok"]
      trunc = "trunc_" <> hex8("srv", long)
      assert report.collisions == [{trunc, [{"srv", long}, {"srv", long}]}]
    end

    test "HB-1: a literal name equal to another tool's truncated name excludes both" do
      long = String.duplicate("q", 80)
      trunc = "trunc_" <> hex8("solo", long)

      {toolset, report} =
        Naming.build([{"solo", tools("solo", [long, trunc, "fine"])}], namespace: false)

      assert ToolSet.names(toolset) == ["fine"]
      assert [{^trunc, [{"solo", ^long}, {"solo", ^trunc}]}] = report.collisions
    end

    test "prefix counts toward the limit and is kept on truncated names" do
      fits = String.duplicate("p", 64 - byte_size("mcp_files__"))

      {toolset, _} =
        Naming.build([{"files", tools("files", [fits, fits <> "p"])}], prefix: "mcp_")

      assert ToolSet.names(toolset) ==
               ["mcp_files__" <> fits, "mcp_trunc_" <> hex8("files", fits <> "p")]
    end

    test "namespace: false exposes bare sanitized names for one server" do
      {toolset, _} =
        Naming.build([{"Any.Client", tools("Any.Client", ["fs.read", "list"])}], namespace: false)

      assert ToolSet.names(toolset) == ["fs_read", "list"]
      assert {:ok, %Tool{name: "fs.read"}} = ToolSet.resolve(toolset, "fs_read")
    end

    test "namespace: false refuses more than one server" do
      assert_raise ArgumentError, ~r/exactly one server/, fn ->
        Naming.build([{"a", []}, {"b", []}], namespace: false)
      end
    end

    test "bad prefixes raise" do
      assert_raise ArgumentError, ~r/:prefix must contain/, fn ->
        Naming.build([{"a", []}], prefix: "a.b")
      end

      assert_raise ArgumentError, ~r/at most 50 bytes/, fn ->
        Naming.build([{"a", []}], prefix: String.duplicate("p", 51))
      end
    end

    test "HB-1: duplicate server ids raise" do
      assert_raise ArgumentError, ~r/duplicate server_id "a"/, fn ->
        Naming.build([{"a", []}, {"b", []}, {"a", []}])
      end
    end

    test "a tool listed under a different server id raises" do
      assert_raise ArgumentError, ~r/listed under "b"/, fn ->
        Naming.build([{"b", [tool("a", "x")]}])
      end
    end
  end

  describe "validate_server_id/1 and validate_server_ids!/1" do
    test "accepts the documented format" do
      for id <- ["a", "github", "my_server2", String.duplicate("a", 32)],
          do: assert(Naming.validate_server_id(id) == :ok)
    end

    test "rejects everything else with a reason" do
      assert Naming.validate_server_id("") == {:error, :invalid_format}
      assert Naming.validate_server_id("Git") == {:error, :invalid_format}
      assert Naming.validate_server_id("1a") == {:error, :invalid_format}
      assert Naming.validate_server_id("a-b") == {:error, :invalid_format}
      assert Naming.validate_server_id(String.duplicate("a", 33)) == {:error, :invalid_format}
      assert Naming.validate_server_id("a__b") == {:error, :double_underscore}
      assert Naming.validate_server_id("a_") == {:error, :trailing_underscore}
      assert Naming.validate_server_id(:a) == {:error, :not_a_string}
    end

    test "PO-3: the colliding concatenation `a_` + `x` vs `a` + `_x` is refused at the id" do
      assert_raise ArgumentError, ~r/invalid server_id "a_": trailing_underscore/, fn ->
        Naming.validate_server_ids!(["a", "a_"])
      end
    end

    test "duplicates raise naming the id" do
      assert Naming.validate_server_ids!(["a", "b"]) == :ok

      assert_raise ArgumentError, ~r/duplicate server_id "b"/, fn ->
        Naming.validate_server_ids!(["a", "b", "b"])
      end
    end
  end

  describe "ToolSet.new/1" do
    test "raises on a duplicate exposed name" do
      assert_raise ArgumentError, ~r/duplicate exposed tool name/, fn ->
        ToolSet.new([{"x", tool("a", "x")}, {"x", tool("b", "x")}])
      end
    end
  end

  # Small alphabets so collisions, invalid names and truncation all happen.
  defp server_id_gen do
    gen all(
          first <- member_of(~c"abc"),
          rest <- string(~c"ab_1", max_length: 4),
          id = <<first>> <> rest,
          Naming.validate_server_id(id) == :ok
        ) do
      id
    end
  end

  defp tool_name_gen do
    one_of([
      string(~c"aAb._-1 é", max_length: 6),
      string(~c"ab._", min_length: 50, max_length: 130)
    ])
  end

  defp servers_gen do
    gen all(
          ids <- uniq_list_of(server_id_gen(), min_length: 1, max_length: 4),
          lists <- list_of(list_of(tool_name_gen(), max_length: 8), length: length(ids))
        ) do
      Enum.zip_with(ids, lists, fn id, names -> {id, tools(id, names)} end)
    end
  end

  property "HB-2: exposed names are valid, unique and resolve back to their tool" do
    check all(
            servers <- servers_gen(),
            prefix <- string(~c"ab_-", max_length: 6)
          ) do
      {toolset, report} = Naming.build(servers, prefix: prefix)
      entries = ToolSet.entries(toolset)

      for {name, tool} <- entries do
        assert Regex.match?(@exposed, name)
        assert String.starts_with?(name, prefix)
        assert ToolSet.resolve(toolset, name) == {:ok, tool}
        assert ToolSet.exposed_name(toolset, tool.server_id, tool.name) == {:ok, name}
      end

      # Injective: one exposed name per accepted tool.
      assert entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(entries)

      # Every input tool is either exposed or rejected, never both.
      input = for {_sid, tools} <- servers, tool <- tools, do: {tool.server_id, tool.name}
      accepted = for {_name, tool} <- entries, do: {tool.server_id, tool.name}
      rejected = for {sid, name, _reason} <- report.rejected, do: {sid, name}
      assert Enum.sort(accepted ++ rejected) == Enum.sort(input)

      # Colliders are never exposed; build order follows input order.
      for {_name, colliders} <- report.collisions,
          member <- colliders,
          do: refute(member in accepted)

      assert accepted == Enum.filter(input, &(&1 in accepted))
      assert Naming.build(servers, prefix: prefix) == {toolset, report}
    end
  end
end

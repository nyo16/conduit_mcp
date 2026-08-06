defmodule ConduitMcp.ObjectParamsTest do
  # Regression coverage for `:object` parameters in both DSL front ends.
  #
  # Every declaration form exercised here crashed at compile time (or was
  # rejected at runtime by the validator) before the object-params fix.
  # See `.claude/plans/object-params/plan.md` for the reproduction table.
  use ExUnit.Case, async: true

  alias ConduitMcp.Validation

  defmodule ObjectServer do
    use ConduitMcp.Server

    # Case A — blockless `:object` param, declared after a sibling param.
    tool "open_bag", "Object param with no block" do
      param(:label, :string, "Declared before the object", required: true)
      param(:bag, :object, "An open bag")

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    # Case B — block `:object` param surrounded by sibling params.
    tool "closed_bag", "Object param with nested fields" do
      param(:label, :string, "Declared before the object", required: true)

      param :bag, :object, "A bag with declared fields", required: true do
        field(:name, :string, "Name", required: true)
        field(:age, :integer, "Age")
      end

      param(:trailing, :string, "Declared after the object")

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    # Object nested inside an object (`field/5`), again with siblings.
    tool "deep_bag", "Object nested in an object" do
      param :bag, :object, "Outer", [] do
        field(:label, :string, "Label")

        field :inner, :object, "Inner", required: true do
          field(:city, :string, "City", required: true)
        end

        field(:trailing, :string, "Trailing")
      end

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    # Case D — `items :object` inside an `:array` param.
    tool "rows", "Array of objects" do
      param(:label, :string, "Declared before the array", required: true)

      param :rows, :array, "Rows", [] do
        items :object do
          field(:id, :integer, "Id", required: true)
          field(:label, :string, "Label")
        end
      end

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    # Blockless `:array` param — `items: nil` reaches `build_items_schema/1`.
    tool "loose_rows", "Array with no declared item type" do
      param(:rows, :array, "Rows")

      handle(fn _conn, params -> text(inspect(params)) end)
    end
  end

  # Case E — `Component.Schema` blockless `:object` field.
  defmodule OpenBagTool do
    use ConduitMcp.Component, type: :tool, description: "Component with an open object field"

    schema do
      field(:label, :string, "Label", required: true)
      field(:bag, :object, "An open bag")
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  defmodule NestedBagTool do
    use ConduitMcp.Component, type: :tool, description: "Component with a nested object field"

    schema do
      field(:label, :string, "Label", required: true)

      field :bag, :object, "A bag with declared fields", required: true do
        field(:name, :string, "Name", required: true)
        field(:age, :integer, "Age")
      end

      field(:trailing, :string, "Trailing")
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  describe "ConduitMcp.DSL object params — generated JSON Schema" do
    test "blockless object param emits an open object and keeps its siblings", %{tools: tools} do
      schema = tools["open_bag"]["inputSchema"]

      assert schema["properties"]["bag"] == %{
               "type" => "object",
               "description" => "An open bag",
               "properties" => %{},
               "additionalProperties" => true
             }

      # RC1: the object must not discard params declared before it.
      assert Enum.sort(Map.keys(schema["properties"])) == ["bag", "label"]
      assert schema["required"] == ["label"]
    end

    test "block object param nests declared fields and keeps its siblings", %{tools: tools} do
      schema = tools["closed_bag"]["inputSchema"]
      bag = schema["properties"]["bag"]

      assert Enum.sort(Map.keys(schema["properties"])) == ["bag", "label", "trailing"]
      assert schema["required"] == ["label", "bag"]

      assert bag["type"] == "object"
      assert bag["description"] == "A bag with declared fields"
      assert bag["required"] == ["name"]
      assert bag["properties"]["name"]["type"] == "string"
      assert bag["properties"]["age"]["type"] == "integer"
    end

    test "object nested in an object keeps every level's fields", %{tools: tools} do
      bag = tools["deep_bag"]["inputSchema"]["properties"]["bag"]

      assert Enum.sort(Map.keys(bag["properties"])) == ["inner", "label", "trailing"]
      assert bag["required"] == ["inner"]

      inner = bag["properties"]["inner"]
      assert inner["type"] == "object"
      assert inner["required"] == ["city"]
      assert inner["properties"]["city"]["type"] == "string"
    end

    test "items :object builds an object item schema and keeps its siblings", %{tools: tools} do
      schema = tools["rows"]["inputSchema"]
      rows = schema["properties"]["rows"]

      assert Enum.sort(Map.keys(schema["properties"])) == ["label", "rows"]

      assert rows["type"] == "array"
      assert rows["items"]["type"] == "object"
      assert rows["items"]["required"] == ["id"]
      assert Enum.sort(Map.keys(rows["items"]["properties"])) == ["id", "label"]
    end

    test "array param with no declared items emits an unconstrained item schema", %{tools: tools} do
      rows = tools["loose_rows"]["inputSchema"]["properties"]["rows"]

      assert rows["type"] == "array"
      assert rows["items"] == %{}
    end
  end

  describe "ConduitMcp.Component.Schema object fields — generated JSON Schema" do
    test "blockless object field emits an open object and keeps its siblings" do
      schema = OpenBagTool.__component_schema__()["inputSchema"]

      assert schema["properties"]["bag"] == %{
               "type" => "object",
               "description" => "An open bag",
               "properties" => %{},
               "additionalProperties" => true
             }

      assert Enum.sort(Map.keys(schema["properties"])) == ["bag", "label"]
      assert schema["required"] == ["label"]
    end

    test "block object field nests declared fields and keeps its siblings" do
      schema = NestedBagTool.__component_schema__()["inputSchema"]
      bag = schema["properties"]["bag"]

      assert Enum.sort(Map.keys(schema["properties"])) == ["bag", "label", "trailing"]
      assert schema["required"] == ["label", "bag"]

      assert bag["required"] == ["name"]
      assert bag["properties"]["name"]["type"] == "string"
      assert bag["properties"]["age"]["type"] == "integer"
    end
  end

  describe "runtime validation of object params" do
    # RC3: `convert_keys_to_atoms/1` recurses with `String.to_existing_atom`,
    # so a nested object arrives with *mixed* key types depending on whether
    # each key happens to be interned. Both must be accepted, or the bug is
    # merely non-deterministic instead of fixed.
    test "accepts a nested object mixing interning and non-interning keys" do
      params = %{
        "label" => "x",
        "bag" => %{"name" => "interns", "zzq_not_an_atom_9f3" => "does not intern"}
      }

      assert {:ok, validated} = Validation.validate_tool_params(ObjectServer, "open_bag", params)

      # The handler-facing contract is string keys, all the way down.
      assert validated["bag"] == %{
               "name" => "interns",
               "zzq_not_an_atom_9f3" => "does not intern"
             }
    end

    test "accepts a declared nested object" do
      params = %{"label" => "x", "bag" => %{"name" => "Alice", "age" => 30}}

      assert {:ok, validated} =
               Validation.validate_tool_params(ObjectServer, "closed_bag", params)

      assert validated["bag"] == %{"name" => "Alice", "age" => 30}
    end

    test "rejects a non-map value for an object param" do
      params = %{"label" => "x", "bag" => "not a map"}

      assert {:error, errors} =
               Validation.validate_tool_params(ObjectServer, "closed_bag", params)

      assert errors != []
    end

    test "rejects a missing required object param" do
      assert {:error, errors} =
               Validation.validate_tool_params(ObjectServer, "closed_bag", %{"label" => "x"})

      assert Enum.any?(errors, &(&1["parameter"] == "bag"))
    end

    test "accepts an array of objects" do
      params = %{"label" => "x", "rows" => [%{"id" => 1, "label" => "a"}]}

      assert {:ok, validated} = Validation.validate_tool_params(ObjectServer, "rows", params)
      assert validated["rows"] == [%{"id" => 1, "label" => "a"}]
    end
  end

  # --- Phase 2: 3-arg (and 2-arg) + block, in both DSLs ---

  defmodule ArityServer do
    use ConduitMcp.Server

    # Case C — 3-arg + block. `[do: ...]` is a keyword list, so this used to
    # bind to the blockless `param/4` clause and lose the block.
    tool "three_arg", "Object param declared with 3 args and a block" do
      param :bag, :object, "A bag" do
        field(:name, :string, "Name", required: true)
      end

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    # 2-arg + block — the description is optional.
    tool "two_arg", "Object param declared with 2 args and a block" do
      param :bag, :object do
        field(:name, :string, "Name", required: true)
      end

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    # The form the `field/4` moduledoc documents: a nested object field
    # declared with 3 args and a block.
    tool "nested_three_arg", "Nested object field declared with 3 args and a block" do
      param :user, :object, "User data", required: true do
        field(:name, :string, "Name", required: true)

        field :address, :object, "Address" do
          field(:city, :string, "City", required: true)
        end
      end

      handle(fn _conn, params -> text(inspect(params)) end)
    end

    tool "rows_three_arg", "Array param declared with 3 args and a block" do
      param :rows, :array, "Rows" do
        items :object do
          field(:id, :integer, "Id", required: true)
        end
      end

      handle(fn _conn, params -> text(inspect(params)) end)
    end
  end

  # Case F — `Component.Schema` 3-arg + block.
  defmodule ThreeArgBagTool do
    use ConduitMcp.Component, type: :tool, description: "3-arg object field with a block"

    schema do
      field :bag, :object, "A bag" do
        field(:name, :string, "Name", required: true)
      end
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  defmodule TwoArgBagTool do
    use ConduitMcp.Component, type: :tool, description: "2-arg object field with a block"

    schema do
      field :bag, :object do
        field(:name, :string, "Name", required: true)
      end
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  # An object nested inside an object must not wipe its parent's sibling
  # fields, and must land in the parent's nested list rather than the
  # top-level field list.
  defmodule DeepBagTool do
    use ConduitMcp.Component, type: :tool, description: "Object nested in an object"

    schema do
      field :bag, :object, "Outer" do
        field(:label, :string, "Label")

        field :inner, :object, "Inner", required: true do
          field(:city, :string, "City", required: true)
        end

        field(:trailing, :string, "Trailing")
      end

      field(:tail, :string, "Tail")
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  # Case G — `Component.Schema` array field with an `items` block.
  defmodule RowsTool do
    use ConduitMcp.Component, type: :tool, description: "Array of objects"

    schema do
      field(:label, :string, "Label", required: true)

      field :rows, :array, "Rows" do
        items :object do
          field(:id, :integer, "Id", required: true)
          field(:label, :string, "Label")
        end
      end

      field :tags, :array, "Tags" do
        items(:string)
      end

      field(:trailing, :string, "Trailing")
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  # The component path reaches the validator through an Endpoint, which is what
  # generates `__validation_schema_for_tool__/1`.
  defmodule ComponentEndpoint do
    use ConduitMcp.Endpoint, name: "object-params", version: "0.0.0"

    component(ConduitMcp.ObjectParamsTest.OpenBagTool)
    component(ConduitMcp.ObjectParamsTest.NestedBagTool)
    component(ConduitMcp.ObjectParamsTest.RowsTool)
  end

  setup_all do
    {:ok, %{"tools" => tools}} = ObjectServer.handle_list_tools(%Plug.Conn{})
    {:ok, %{"tools" => arity_tools}} = ArityServer.handle_list_tools(%Plug.Conn{})

    %{
      tools: Map.new(tools, &{&1["name"], &1}),
      arity_tools: Map.new(arity_tools, &{&1["name"], &1}),
      rows_schema: RowsTool.__component_schema__()["inputSchema"]
    }
  end

  describe "ConduitMcp.DSL 3-arg and 2-arg block forms" do
    test "param/3 with a block declares a nested object", %{arity_tools: tools} do
      bag = tools["three_arg"]["inputSchema"]["properties"]["bag"]

      assert bag["type"] == "object"
      assert bag["description"] == "A bag"
      assert bag["required"] == ["name"]
      assert bag["properties"]["name"]["type"] == "string"
    end

    test "param/2 with a block declares a nested object with no description", %{
      arity_tools: tools
    } do
      bag = tools["two_arg"]["inputSchema"]["properties"]["bag"]

      assert bag["type"] == "object"
      refute Map.has_key?(bag, "description")
      assert bag["required"] == ["name"]
    end

    test "field/3 with a block declares a nested object", %{arity_tools: tools} do
      user = tools["nested_three_arg"]["inputSchema"]["properties"]["user"]

      assert Enum.sort(Map.keys(user["properties"])) == ["address", "name"]
      assert user["required"] == ["name"]
      assert user["properties"]["address"]["properties"]["city"]["type"] == "string"
      assert user["properties"]["address"]["required"] == ["city"]
    end

    test "param/3 with a block declares array items", %{arity_tools: tools} do
      rows = tools["rows_three_arg"]["inputSchema"]["properties"]["rows"]

      assert rows["type"] == "array"
      assert rows["items"]["type"] == "object"
      assert rows["items"]["required"] == ["id"]
    end

    test "a block on a scalar param is a compile error naming the file and line" do
      assert_raise CompileError, ~r/only supported for :object and :array params/, fn ->
        Code.compile_string("""
        defmodule ConduitMcp.ObjectParamsTest.BadScalarParam do
          use ConduitMcp.Server

          tool "bad", "Bad" do
            param :x, :string, "Nope" do
              field(:y, :string, "Y")
            end

            handle(fn _conn, _params -> text("ok") end)
          end
        end
        """)
      end
    end

    test "a block on a scalar nested field is a compile error" do
      assert_raise CompileError, ~r/only supported for :object fields/, fn ->
        Code.compile_string("""
        defmodule ConduitMcp.ObjectParamsTest.BadScalarField do
          use ConduitMcp.Server

          tool "bad", "Bad" do
            param :bag, :object, "Bag" do
              field :x, :string, "Nope" do
                field(:y, :string, "Y")
              end
            end

            handle(fn _conn, _params -> text("ok") end)
          end
        end
        """)
      end
    end
  end

  describe "ConduitMcp.Component.Schema 3-arg and 2-arg block forms" do
    test "field/3 with a block declares a nested object" do
      bag = ThreeArgBagTool.__component_schema__()["inputSchema"]["properties"]["bag"]

      assert bag["type"] == "object"
      assert bag["description"] == "A bag"
      assert bag["required"] == ["name"]
    end

    test "field/2 with a block declares a nested object with no description" do
      bag = TwoArgBagTool.__component_schema__()["inputSchema"]["properties"]["bag"]

      assert bag["type"] == "object"
      refute Map.has_key?(bag, "description")
      assert bag["required"] == ["name"]
    end

    test "an object nested in an object keeps both levels and its siblings" do
      schema = DeepBagTool.__component_schema__()["inputSchema"]
      bag = schema["properties"]["bag"]

      # The inner object must not leak out into the top-level field list.
      assert Enum.sort(Map.keys(schema["properties"])) == ["bag", "tail"]

      assert Enum.sort(Map.keys(bag["properties"])) == ["inner", "label", "trailing"]
      assert bag["required"] == ["inner"]
      assert bag["properties"]["inner"]["required"] == ["city"]
      assert bag["properties"]["inner"]["properties"]["city"]["type"] == "string"
    end

    test "a block on a scalar field is a compile error" do
      assert_raise CompileError, ~r/only supported for :object and :array fields/, fn ->
        Code.compile_string("""
        defmodule ConduitMcp.ObjectParamsTest.BadComponentField do
          use ConduitMcp.Component, type: :tool, description: "Bad"

          schema do
            field :x, :string, "Nope" do
              field(:y, :string, "Y")
            end
          end

          @impl true
          def execute(_params, _conn), do: text("ok")
        end
        """)
      end
    end
  end

  describe "ConduitMcp.Component.Schema array items" do
    test "items :object builds an object item schema", %{rows_schema: schema} do
      rows = schema["properties"]["rows"]

      assert rows["type"] == "array"
      assert rows["items"]["type"] == "object"
      assert rows["items"]["required"] == ["id"]
      assert Enum.sort(Map.keys(rows["items"]["properties"])) == ["id", "label"]
    end

    test "items with a scalar type builds a scalar item schema", %{rows_schema: schema} do
      assert schema["properties"]["tags"] == %{
               "type" => "array",
               "description" => "Tags",
               "items" => %{"type" => "string"}
             }
    end

    test "an array block does not leak its item fields into the parent", %{rows_schema: schema} do
      assert Enum.sort(Map.keys(schema["properties"])) == [
               "label",
               "rows",
               "tags",
               "trailing"
             ]

      assert schema["required"] == ["label"]
    end

    test "a bare field inside an array block is a compile error" do
      assert_raise CompileError, ~r/declares its item type with `items`/, fn ->
        Code.compile_string("""
        defmodule ConduitMcp.ObjectParamsTest.BareFieldInArray do
          use ConduitMcp.Component, type: :tool, description: "Bad"

          schema do
            field :rows, :array, "Rows" do
              field(:id, :integer, "Id")
            end
          end

          @impl true
          def execute(_params, _conn), do: text("ok")
        end
        """)
      end
    end

    test "items outside an array block is a compile error" do
      assert_raise CompileError, ~r/items is only valid inside an :array field block/, fn ->
        Code.compile_string("""
        defmodule ConduitMcp.ObjectParamsTest.StrayItems do
          use ConduitMcp.Component, type: :tool, description: "Bad"

          schema do
            items(:string)
          end

          @impl true
          def execute(_params, _conn), do: text("ok")
        end
        """)
      end
    end
  end

  describe "runtime validation of component object fields" do
    test "accepts a declared nested object from the component DSL" do
      params = %{"label" => "x", "bag" => %{"name" => "Alice", "age" => 30}}

      assert {:ok, validated} =
               Validation.validate_tool_params(ComponentEndpoint, "nested_bag_tool", params)

      assert validated["bag"] == %{"name" => "Alice", "age" => 30}
    end

    test "accepts an open object with non-interning keys from the component DSL" do
      params = %{"label" => "x", "bag" => %{"zzq_not_an_atom_9f3" => "v"}}

      assert {:ok, validated} =
               Validation.validate_tool_params(ComponentEndpoint, "open_bag_tool", params)

      assert validated["bag"] == %{"zzq_not_an_atom_9f3" => "v"}
    end
  end
end

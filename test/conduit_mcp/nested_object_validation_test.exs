defmodule ConduitMcp.NestedObjectValidationTest do
  # Runtime enforcement of declared nested object fields (plan phases 4 and 5).
  # Before this, a declared object validated as "is a map" and nothing more
  # while the published JSON Schema advertised nested `required` fields.
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Validation

  defmodule NestedServer do
    use ConduitMcp.Server

    tool "strict", "Declared fields, strict by default" do
      param :bag, :object, "Bag", required: true do
        field(:name, :string, "Name", required: true)
        field(:age, :integer, "Age")
        field(:role, :string, "Role", enum: ["admin", "user"])
      end

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    tool "deep", "Object nested in an object" do
      param :bag, :object, "Bag" do
        field(:label, :string, "Label")

        field :inner, :object, "Inner", required: true do
          field(:city, :string, "City", required: true)
          field(:zip, :string, "Zip", min_length: 5)
        end
      end

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    tool "open", "Open bag — no declared fields" do
      param(:bag, :object, "Bag")

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    tool "permissive", "Declared fields plus pass-through" do
      param :bag, :object, "Bag", additional_properties: true do
        field(:name, :string, "Name", required: true)
        field(:count, :integer, "Count", default: 1)
      end

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    tool "empty_only", "Object that must carry no keys at all" do
      param(:bag, :object, "Bag", additional_properties: false)

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    tool "rows", "Array of objects" do
      param :rows, :array, "Rows" do
        items :object do
          field(:id, :integer, "Id", required: true)
        end
      end

      handle(fn _conn, params -> text(inspect(params["rows"])) end)
    end
  end

  defmodule NestedBagTool do
    use ConduitMcp.Component, type: :tool, description: "Component with a declared object field"

    schema do
      field :bag, :object, "Bag", required: true do
        field(:name, :string, "Name", required: true)
        field(:age, :integer, "Age")
      end
    end

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  defmodule ComponentEndpoint do
    use ConduitMcp.Endpoint, name: "nested-object", version: "0.0.0"

    component(ConduitMcp.NestedObjectValidationTest.NestedBagTool)
  end

  defp validate(tool, params), do: Validation.validate_tool_params(NestedServer, tool, params)

  defp parameters(errors), do: Enum.map(errors, & &1["parameter"])

  describe "declared nested fields — strict by default" do
    test "accepts a valid object" do
      assert {:ok, validated} =
               validate("strict", %{"bag" => %{"name" => "Alice", "age" => 30}})

      assert validated["bag"] == %{"name" => "Alice", "age" => 30}
    end

    test "rejects a missing nested required field, naming the full path" do
      assert {:error, errors} = validate("strict", %{"bag" => %{"age" => 30}})

      assert parameters(errors) == ["bag.name"]
      assert Enum.all?(errors, &(&1["message"] == "is required"))
    end

    test "rejects a nested field of the wrong type" do
      assert {:error, [error]} = validate("strict", %{"bag" => %{"name" => 1}})

      assert error["message"] =~ "expected string"
      assert error["message"] =~ "[:bag]"
    end

    test "rejects an undeclared nested key with a message an API consumer can act on" do
      assert {:error, errors} =
               validate("strict", %{"bag" => %{"name" => "Alice", "zzq_not_an_atom_9f3" => 1}})

      assert errors == [
               %{
                 "parameter" => "bag.zzq_not_an_atom_9f3",
                 "value" => 1,
                 "message" => "unknown field \"zzq_not_an_atom_9f3\" in object \"bag\""
               }
             ]
    end

    test "enforces custom constraints on nested fields" do
      assert {:error, errors} =
               validate("strict", %{"bag" => %{"name" => "Alice", "role" => "root"}})

      assert parameters(errors) == ["bag.role"]
      assert hd(errors)["message"] == ~s(must be one of ["admin", "user"])
    end

    test "rejects a non-map value for a declared object" do
      assert {:error, [error]} = validate("strict", %{"bag" => "not a map"})
      assert error["message"] =~ "expected map"
    end
  end

  describe "depth" do
    test "accepts a valid two-level object" do
      params = %{"bag" => %{"label" => "l", "inner" => %{"city" => "Berlin", "zip" => "10115"}}}

      assert {:ok, validated} = validate("deep", params)
      assert validated["bag"]["inner"] == %{"city" => "Berlin", "zip" => "10115"}
    end

    test "rejects a missing required field two levels down" do
      assert {:error, errors} = validate("deep", %{"bag" => %{"inner" => %{}}})

      assert parameters(errors) == ["bag.inner.city"]
    end

    test "rejects a missing required object two levels down" do
      assert {:error, errors} = validate("deep", %{"bag" => %{"label" => "l"}})

      assert parameters(errors) == ["bag.inner"]
    end

    test "enforces custom constraints two levels down" do
      params = %{"bag" => %{"inner" => %{"city" => "Berlin", "zip" => "1"}}}

      assert {:error, errors} = validate("deep", params)
      assert parameters(errors) == ["bag.inner.zip"]
    end

    test "rejects an undeclared key two levels down" do
      params = %{"bag" => %{"inner" => %{"city" => "Berlin", "nope" => 1}}}

      assert {:error, errors} = validate("deep", params)
      assert parameters(errors) == ["bag.inner.nope"]
      assert hd(errors)["message"] == ~s(unknown field "nope" in object "bag.inner")
    end
  end

  describe "open bag — no declared fields" do
    test "accepts any keys, interning or not" do
      params = %{"bag" => %{"name" => "interns", "zzq_not_an_atom_9f3" => %{"deep" => 1}}}

      assert {:ok, validated} = validate("open", params)
      assert validated["bag"] == params["bag"]
    end

    test "accepts an empty object" do
      assert {:ok, validated} = validate("open", %{"bag" => %{}})
      assert validated["bag"] == %{}
    end
  end

  describe "additional_properties: true" do
    test "validates declared fields and passes undeclared keys through" do
      params = %{"bag" => %{"name" => "Alice", "extra" => %{"nested" => true}}}

      assert {:ok, validated} = validate("permissive", params)

      assert validated["bag"] == %{
               "name" => "Alice",
               "count" => 1,
               "extra" => %{"nested" => true}
             }
    end

    test "still enforces a missing declared required field" do
      assert {:error, errors} = validate("permissive", %{"bag" => %{"extra" => 1}})
      assert parameters(errors) == ["bag.name"]
    end

    test "still enforces a declared field's type" do
      assert {:error, [error]} = validate("permissive", %{"bag" => %{"name" => 1}})
      assert error["message"] =~ "expected string"
    end
  end

  describe "additional_properties: false with no declared fields" do
    test "accepts an empty object" do
      assert {:ok, validated} = validate("empty_only", %{"bag" => %{}})
      assert validated["bag"] == %{}
    end

    test "rejects any key" do
      assert {:error, errors} = validate("empty_only", %{"bag" => %{"anything" => 1}})
      assert parameters(errors) == ["bag.anything"]
    end
  end

  describe "arrays of objects" do
    # NimbleOptions cannot attach a `keys:` schema to a list element type, so
    # item fields are published in the JSON Schema for clients but not enforced
    # server-side. Documented in `ConduitMcp.Validation.SchemaConverter`.
    test "accepts a list of objects and leaves the items untouched" do
      params = %{"rows" => [%{"id" => 1}, %{"whatever" => true}]}

      assert {:ok, validated} = validate("rows", params)
      assert validated["rows"] == params["rows"]
    end
  end

  describe "published JSON Schema agrees with the validator" do
    setup do
      {:ok, %{"tools" => tools}} = NestedServer.handle_list_tools(%Plug.Conn{})
      %{tools: Map.new(tools, &{&1["name"], &1["inputSchema"]["properties"]})}
    end

    test "declared fields with no opt advertise additionalProperties: false", %{tools: tools} do
      assert tools["strict"]["bag"]["additionalProperties"] == false
      assert tools["deep"]["bag"]["properties"]["inner"]["additionalProperties"] == false
    end

    test "an open bag advertises additionalProperties: true", %{tools: tools} do
      assert tools["open"]["bag"]["additionalProperties"] == true
    end

    test "additional_properties: true is advertised", %{tools: tools} do
      assert tools["permissive"]["bag"]["additionalProperties"] == true
      assert tools["permissive"]["bag"]["required"] == ["name"]
    end

    test "additional_properties: false with no fields advertises an empty object", %{tools: tools} do
      assert tools["empty_only"]["bag"] == %{
               "type" => "object",
               "description" => "Bag",
               "properties" => %{},
               "additionalProperties" => false
             }
    end
  end

  describe "handler-facing contract" do
    # Atomising nested keys is an internal detail of validation; handlers must
    # keep receiving string keys all the way down.
    test "the handler receives string keys at every depth" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "deep",
          "arguments" => %{
            "bag" => %{"label" => "l", "inner" => %{"city" => "Berlin", "zip" => "10115"}}
          }
        }
      }

      response = Handler.handle_request(request, NestedServer)

      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert text =~ ~s("label" => "l")
      assert text =~ ~s("inner" =>)
      assert text =~ ~s("city" => "Berlin")
      refute text =~ "label:"
      refute text =~ "city:"
    end

    test "a nested validation failure surfaces as a JSON-RPC error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "strict", "arguments" => %{"bag" => %{"age" => 1}}}
      }

      response = Handler.handle_request(request, NestedServer)

      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
    end
  end

  describe "component front end" do
    test "enforces declared nested fields" do
      assert {:error, errors} =
               Validation.validate_tool_params(
                 ComponentEndpoint,
                 "nested_bag_tool",
                 %{"bag" => %{"age" => 30}}
               )

      assert parameters(errors) == ["bag.name"]
    end

    test "rejects an undeclared nested key" do
      assert {:error, errors} =
               Validation.validate_tool_params(
                 ComponentEndpoint,
                 "nested_bag_tool",
                 %{"bag" => %{"name" => "Alice", "nope" => 1}}
               )

      assert parameters(errors) == ["bag.nope"]
    end

    test "accepts a valid object" do
      assert {:ok, validated} =
               Validation.validate_tool_params(
                 ComponentEndpoint,
                 "nested_bag_tool",
                 %{"bag" => %{"name" => "Alice", "age" => 30}}
               )

      assert validated["bag"] == %{"name" => "Alice", "age" => 30}
    end

    test "advertises additionalProperties: false" do
      schema = NestedBagTool.__component_schema__()["inputSchema"]

      assert schema["properties"]["bag"]["additionalProperties"] == false
    end
  end
end

defmodule ConduitMcp.NestedObjectValidationTest do
  # Runtime enforcement of declared nested object fields (plan phases 4 and 5).
  # Before this, a declared object validated as "is a map" and nothing more
  # while the published JSON Schema advertised nested `required` fields.
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Validation

  # Named rather than an inline capture: the DSL escapes handler/validator terms
  # into the compiled schema, and an anonymous function cannot be escaped.
  def big?(value), do: value > 18

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

    # `min:`/`max:`/`validator:` are checked by this library, not NimbleOptions,
    # and the checks are type-specific — so they must run on *coerced* input or
    # a string sails past them.
    tool "constrained", "Nested numeric and custom constraints" do
      param :bag, :object, "Bag" do
        field(:age, :integer, "Age", min: 18, max: 120)
        field(:big, :integer, "Big", validator: &ConduitMcp.NestedObjectValidationTest.big?/1)
      end

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    # Description omitted: Elixir folds the trailing keywords into the third
    # argument, so this must still be read as opts.
    tool "kw_opts", "Object declared with opts but no description" do
      param :bag, :object, required: true do
        field(:name, :string, "Name", required: true)
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

    # `additional_properties: true` on a *nested* object, so the pruning in
    # `normalize_object/3` and the remerge in `merge_object/4` are exercised at
    # depth, not only at the top level.
    tool "deep_permissive", "Pass-through on a nested object" do
      param :bag, :object, "Bag" do
        field :inner, :object, "Inner", required: true, additional_properties: true do
          field(:city, :string, "City", required: true)
          field(:zone, :integer, "Zone", default: 9)
        end
      end

      handle(fn _conn, params -> text(inspect(params["bag"])) end)
    end

    tool "coerce", "Type coercion at depth" do
      param(:age, :integer, "Top-level age")

      param :bag, :object, "Bag" do
        field(:age, :integer, "Nested age")
        field(:score, :number, "Nested score")
        field(:on, :boolean, "Nested flag")

        field :inner, :object, "Inner" do
          field(:count, :integer, "Deeper count")
        end
      end

      handle(fn _conn, params -> text(inspect(params)) end)
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

    test "rejects a nested field of the wrong type, naming the full path" do
      assert {:error, [error]} = validate("strict", %{"bag" => %{"name" => 1}})

      # Same dotted-path contract as every other nested error — a client author
      # should never have to special-case the failure kind to locate the field.
      assert error["parameter"] == "bag.name"
      assert error["message"] == "expected string, got: 1"
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

    # The declared key is atomised for NimbleOptions while the undeclared one is
    # not, so this is the one path that genuinely produces a *mixed*-key map —
    # and the only one where a non-interning key proves anything.
    test "mixes atomised declared keys with untouched undeclared keys" do
      key = "zzq_not_an_atom_9f3"

      # Guard the guard: the test is only meaningful while this key has no atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

      assert {:ok, validated} =
               validate("permissive", %{"bag" => %{"name" => "Alice", key => "kept"}})

      assert validated["bag"] == %{"name" => "Alice", "count" => 1, key => "kept"}

      # The real invariant: validating client input must never mint an atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "passes undeclared keys through on a nested object and keeps nested defaults" do
      params = %{"bag" => %{"inner" => %{"city" => "Berlin", "extra" => %{"deep" => 1}}}}

      assert {:ok, validated} = validate("deep_permissive", params)

      assert validated["bag"]["inner"] == %{
               "city" => "Berlin",
               "zone" => 9,
               "extra" => %{"deep" => 1}
             }
    end

    test "still enforces declared fields on a nested pass-through object" do
      assert {:error, errors} =
               validate("deep_permissive", %{"bag" => %{"inner" => %{"extra" => 1}}})

      assert parameters(errors) == ["bag.inner.city"]
    end
  end

  describe "type coercion" do
    # Coercion has to follow validation: nested fields are type-checked, so a
    # nested `:integer` must accept the same `"30"` the top level accepts.
    test "coerces nested values at every depth" do
      params = %{
        "age" => "31",
        "bag" => %{
          "age" => "30",
          "score" => "85.5",
          "on" => "true",
          "inner" => %{"count" => "7"}
        }
      }

      assert {:ok, validated} = validate("coerce", params)

      assert validated["age"] == 31
      assert validated["bag"]["age"] == 30
      assert validated["bag"]["score"] == 85.5
      assert validated["bag"]["on"] == true
      assert validated["bag"]["inner"]["count"] == 7
    end

    test "leaves an uncoercible nested value for the type check to reject" do
      assert {:error, [error]} = validate("coerce", %{"bag" => %{"age" => "not a number"}})

      assert error["parameter"] == "bag.age"
      assert error["message"] =~ "expected integer"
    end
  end

  describe "undeclared top-level parameters" do
    # Left to NimbleOptions, this reported `parameter: nil` while every nested
    # error reported a dotted path, and a key that did not intern crashed
    # `NimbleOptions.validate/2` outright with an ArgumentError rather than
    # returning a validation error — so the same mistake surfaced two different
    # ways depending on whether the atom happened to exist.
    test "rejects an undeclared parameter whose name does not intern" do
      key = "zzq_not_a_param_7c1"
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

      assert {:error, [error]} =
               validate("strict", %{"bag" => %{"name" => "Alice"}, key => 1})

      assert error["parameter"] == key
      assert error["message"] == ~s(unknown parameter "#{key}")
      assert error["value"] == 1
    end

    test "rejects an undeclared parameter whose name does intern, identically" do
      # `:name` certainly exists as an atom — it is a declared *nested* field.
      assert {:error, [error]} =
               validate("strict", %{"bag" => %{"name" => "Alice"}, "name" => 1})

      assert error["parameter"] == "name"
      assert error["message"] == ~s(unknown parameter "name")
    end
  end

  describe "constraints are checked against coerced values" do
    # `check_min_value/3` ignores a binary and `check_custom_validator/3` would
    # hand the user's function a binary, while the clean schema handed to
    # NimbleOptions has already had `min:`/`max:`/`validator:` stripped. Run the
    # checks before coercion and all three fail *open* — a client sends "5" and
    # the handler receives 5 having passed `min: 18`.
    test "a numeric constraint cannot be bypassed by sending the number as a string" do
      assert {:error, [error]} = validate("constrained", %{"bag" => %{"age" => "5"}})

      assert error["parameter"] == "bag.age"
      assert error["message"] == "must be greater than or equal to 18"
      assert error["value"] == 5
    end

    test "an upper bound cannot be bypassed either" do
      assert {:error, [error]} = validate("constrained", %{"bag" => %{"age" => "999"}})
      assert error["message"] == "must be less than or equal to 120"
    end

    # `"5" > 18` is true in Erlang term order, so an uncoerced string silently
    # satisfied any comparison-based validator.
    test "a custom validator receives the coerced value" do
      assert {:error, [error]} = validate("constrained", %{"bag" => %{"big" => "5"}})

      assert error["parameter"] == "bag.big"
      assert error["message"] == "failed custom validation"
    end

    test "a value that satisfies the constraint after coercion is accepted" do
      assert {:ok, validated} =
               validate("constrained", %{"bag" => %{"age" => "30", "big" => "19"}})

      assert validated["bag"] == %{"age" => 30, "big" => 19}
    end
  end

  describe "opts in the description position" do
    # `param :bag, :object, required: true do ... end`. Elixir folds trailing
    # keywords into the third argument, so the opts used to be dropped — the
    # param became optional — and the keyword list landed in "description",
    # which is not JSON-encodable, breaking tools/list for the whole server.
    test "keywords are read as opts, not as a description" do
      {:ok, %{"tools" => tools}} = NestedServer.handle_list_tools(%Plug.Conn{})
      schema = Enum.find(tools, &(&1["name"] == "kw_opts"))["inputSchema"]

      assert schema["required"] == ["bag"]
      refute Map.has_key?(schema["properties"]["bag"], "description")
    end

    test "the resulting tool list is JSON-encodable" do
      {:ok, result} = NestedServer.handle_list_tools(%Plug.Conn{})

      assert is_binary(JSON.encode!(result))
    end

    test "the opts are actually enforced" do
      assert {:error, errors} = validate("kw_opts", %{})
      assert parameters(errors) == ["bag"]
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

  describe "error messages are not client-forgeable" do
    # NimbleOptions embeds the offending value in its message via `inspect/1`,
    # so a client-supplied string can contain anything the error parser looks
    # for. While `qualify_with_key_path/2` matched anywhere in the message and
    # took the *first* `(in options [...])`, this payload produced a wholly
    # fabricated `%{"parameter" => "admin.secrets.password", "message" => "is
    # required"}` and suppressed the real type error. The parsers are now
    # anchored: the reason is always the message prefix, the key path always the
    # suffix.
    test "a value mimicking a NimbleOptions error cannot forge a parameter name" do
      forged = "required :password option not found (in options [:admin, :secrets])"

      assert {:error, [error]} =
               validate("strict", %{"bag" => %{"name" => "Alice", "age" => forged}})

      assert error["parameter"] == "bag.age"
      refute error["message"] == "is required"

      # The real error survives, and the forged path is nowhere in the output.
      assert error["message"] =~ "expected integer"
      assert error["message"] =~ forged
    end

    test "a genuine nested required error still resolves its full key path" do
      assert {:error, errors} = validate("deep", %{"bag" => %{"inner" => %{}}})

      assert parameters(errors) == ["bag.inner.city"]
      assert hd(errors)["message"] == "is required"
    end

    # `declared_key/3` tolerates any key term, so the error builder must too.
    # Not reachable over JSON-RPC, where object keys are always strings, but
    # reachable through the public `validate_tool_params/3`.
    test "an unknown key that is not a string does not crash the error builder" do
      assert {:error, [error]} = validate("strict", %{"bag" => %{%{a: 1} => 2}})

      assert error["message"] =~ "unknown field"
      assert error["value"] == 2
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

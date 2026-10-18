defmodule ConduitMcp.Client.SchemaValidatorTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.SchemaValidator
  alias ConduitMcp.Client.SchemaValidator.JSV, as: Validator

  doctest SchemaValidator

  describe "check_bounds/1 (HK-6)" do
    test "accepts ordinary schemas and booleans" do
      assert :ok = SchemaValidator.check_bounds(true)

      assert :ok =
               SchemaValidator.check_bounds(%{
                 "type" => "object",
                 "$defs" => %{"p" => %{"type" => "string"}},
                 "properties" => %{
                   "a" => %{"$ref" => "#/$defs/p"},
                   "b" => %{"anyOf" => [true, false]}
                 }
               })
    end

    test "refuses any $ref that is not a local pointer" do
      for ref <- [
            "http://169.254.169.254/",
            "https://example.com/s.json",
            "other.json",
            "file:///etc/passwd"
          ] do
        assert {:error, :remote_ref} =
                 SchemaValidator.check_bounds(%{"properties" => %{"x" => %{"$ref" => ref}}})
      end

      assert {:error, :remote_ref} = SchemaValidator.check_bounds(%{"$dynamicRef" => "http://x/"})
      assert {:error, :invalid_schema} = SchemaValidator.check_bounds(%{"$ref" => 1})
    end

    test "refuses deep, wide, large and malformed schemas" do
      deep = Enum.reduce(1..10_000, %{"type" => "string"}, fn _, acc -> %{"items" => acc} end)
      assert {:error, :too_deep} = SchemaValidator.check_bounds(deep)

      deep_31 = Enum.reduce(1..31, %{}, fn _, acc -> %{"not" => acc} end)
      assert :ok = SchemaValidator.check_bounds(deep_31)
      assert {:error, :too_deep} = SchemaValidator.check_bounds(%{"not" => %{"not" => deep_31}})

      deep_default = Enum.reduce(1..100, 1, fn _, acc -> [acc] end)
      assert {:error, :too_deep} = SchemaValidator.check_bounds(%{"default" => deep_default})

      wide = %{"properties" => Map.new(1..1_000, &{"p#{&1}", %{"type" => "string"}})}
      assert {:error, :too_many_subschemas} = SchemaValidator.check_bounds(wide)

      large = %{"const" => String.duplicate("x", 300_000)}
      assert {:error, :too_large} = SchemaValidator.check_bounds(large)

      assert {:error, :invalid_schema} = SchemaValidator.check_bounds([])
      assert {:error, :invalid_schema} = SchemaValidator.check_bounds(%{"allOf" => [1]})
    end
  end

  describe "the JSV validator" do
    test "builds and validates" do
      {:ok, built} = Validator.build(%{"type" => "object", "required" => ["a"]}, [])
      assert :ok = Validator.validate(built, %{"a" => 1})
      assert {:error, %{valid: false}} = Validator.validate(built, %{})
    end

    test "a catastrophic pattern fails closed within budget" do
      {:ok, built} = Validator.build(%{"type" => "string", "pattern" => "(a+)+$"}, [])
      subject = String.duplicate("a", 10_000) <> "!"
      {micros, result} = :timer.tc(fn -> Validator.validate(built, subject) end)
      assert {:error, _} = result
      assert micros < 2_000_000
    end

    test "ignores JSV cast extensions and never resolves remote documents" do
      cast = %{"type" => "string", "x-jsv-cast" => ["Elixir.String", "to_atom"]}
      {:ok, built} = Validator.build(cast, [])
      assert :ok = Validator.validate(built, "x")

      assert {:error, :build_failed} =
               Validator.build(%{"$schema" => "http://127.0.0.1:1/meta", "type" => "string"}, [])
    end
  end
end

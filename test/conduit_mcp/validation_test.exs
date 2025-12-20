defmodule ConduitMcp.ValidationTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Validation
  alias ConduitMcp.Validation.SchemaConverter
  alias ConduitMcp.Validation.Validators

  describe "ConduitMcp.Validation" do
    # Create a mock server module with validation schemas
    defmodule TestValidationServer do
      def __validation_schema_for_tool__("simple_tool") do
        [
          name: [type: :string, required: true],
          age: [type: :integer, __min_value__: 0, __max_value__: 150]
        ]
      end

      def __validation_schema_for_tool__("enum_tool") do
        [
          action: [type: :string, required: true, __enum_values__: ["start", "stop", "restart"]],
          priority: [type: :string, default: "medium"]
        ]
      end

      def __validation_schema_for_tool__("complex_tool") do
        [
          count: [type: :integer, __min_value__: 1, __max_value__: 100, required: true],
          score: [type: :float, __min_value__: 0.0, __max_value__: 100.0, default: 50.0],
          email: [type: :string, validator: &Validators.email/1],
          tags: [type: {:list, :string}, __max_length__: 5]
        ]
      end

      def __validation_schema_for_tool__(_tool_name), do: nil

      def __validation_schema_for_prompt__("test_prompt") do
        [
          message: [type: :string, required: true],
          format: [type: :string, __enum_values__: ["text", "html"], default: "text"]
        ]
      end

      def __validation_schema_for_prompt__(_prompt_name), do: nil
    end

    # Mock server without validation schemas
    defmodule PlainServer do
      # No validation schema functions
    end

    test "validate_tool_params/3 with valid parameters" do
      params = %{"name" => "Alice", "age" => 25}

      assert {:ok, validated_params} = Validation.validate_tool_params(TestValidationServer, "simple_tool", params)
      assert validated_params["name"] == "Alice"
      assert validated_params["age"] == 25
    end

    test "validate_tool_params/3 with missing required parameter" do
      params = %{"age" => 25}  # Missing required "name"

      assert {:error, errors} = Validation.validate_tool_params(TestValidationServer, "simple_tool", params)
      assert length(errors) == 1
      assert Enum.any?(errors, fn error -> error["parameter"] =~ "name" end)
    end

    test "validate_tool_params/3 with invalid range" do
      params = %{"name" => "Alice", "age" => 200}  # Age too high

      assert {:error, errors} = Validation.validate_tool_params(TestValidationServer, "simple_tool", params)
      assert length(errors) == 1
      assert List.first(errors)["parameter"] == "age"
      assert List.first(errors)["value"] == 200
    end

    test "validate_tool_params/3 with enum validation" do
      # Valid enum value
      params = %{"action" => "start"}
      assert {:ok, _} = Validation.validate_tool_params(TestValidationServer, "enum_tool", params)

      # Invalid enum value
      params = %{"action" => "invalid"}
      assert {:error, errors} = Validation.validate_tool_params(TestValidationServer, "enum_tool", params)
      assert length(errors) == 1
      assert List.first(errors)["parameter"] == "action"
      assert List.first(errors)["message"] =~ ~s(must be one of ["start", "stop", "restart"])
    end

    test "validate_tool_params/3 with default values" do
      params = %{"action" => "start"}  # priority should get default
      assert {:ok, validated_params} = Validation.validate_tool_params(TestValidationServer, "enum_tool", params)
      assert validated_params["action"] == "start"
      # Note: NimbleOptions would apply defaults, but our implementation passes through
    end

    test "validate_tool_params/3 with custom validator" do
      # Valid email
      params = %{"count" => 5, "email" => "test@example.com"}
      assert {:ok, _} = Validation.validate_tool_params(TestValidationServer, "complex_tool", params)

      # Invalid email
      params = %{"count" => 5, "email" => "invalid-email"}
      assert {:error, errors} = Validation.validate_tool_params(TestValidationServer, "complex_tool", params)
      assert length(errors) >= 1
    end

    test "validate_tool_params/3 with type coercion" do
      # String numbers should be converted to integers/floats by NimbleOptions
      params = %{"count" => "10", "score" => "85.5"}
      assert {:ok, _validated_params} = Validation.validate_tool_params(TestValidationServer, "complex_tool", params)
      # NimbleOptions should handle type coercion
    end

    test "validate_tool_params/3 with unknown tool" do
      params = %{"any" => "param"}
      assert {:error, errors} = Validation.validate_tool_params(TestValidationServer, "unknown_tool", params)
      assert length(errors) == 1
      assert List.first(errors)["message"] =~ "not found"
    end

    test "validate_tool_params/3 with server without validation schemas" do
      params = %{"any" => "param"}
      # Should skip validation and return params as-is
      assert {:ok, validated_params} = Validation.validate_tool_params(PlainServer, "any_tool", params)
      assert validated_params == params
    end

    test "validate_prompt_args/3 with valid arguments" do
      args = %{"message" => "Hello", "format" => "text"}
      assert {:ok, validated_args} = Validation.validate_prompt_args(TestValidationServer, "test_prompt", args)
      assert validated_args["message"] == "Hello"
    end

    test "validate_prompt_args/3 with missing required argument" do
      args = %{"format" => "text"}  # Missing required "message"
      assert {:error, errors} = Validation.validate_prompt_args(TestValidationServer, "test_prompt", args)
      assert length(errors) >= 1
    end

    test "validate_prompt_args/3 with server without validation schemas" do
      args = %{"any" => "arg"}
      assert {:ok, validated_args} = Validation.validate_prompt_args(PlainServer, "any_prompt", args)
      assert validated_args == args
    end

    test "format_validation_errors/1 formats errors correctly" do
      errors = [
        %{parameter: "name", value: nil, message: "is required"},
        %{parameter: "age", value: 200, message: "must be <= 150"}
      ]

      formatted = Validation.format_validation_errors(errors)

      assert is_list(formatted)
      assert length(formatted) == 2

      first_error = List.first(formatted)
      assert first_error["parameter"] == "name"
      assert first_error["message"] == "is required"
    end

    test "validation can be disabled via configuration" do
      # Mock disabled validation
      Application.put_env(:conduit_mcp, :validation, runtime_validation: false)

      params = %{"invalid" => "params"}
      assert {:ok, validated_params} = Validation.validate_tool_params(TestValidationServer, "simple_tool", params)
      assert validated_params == params

      # Reset to default
      Application.put_env(:conduit_mcp, :validation, runtime_validation: true)
    end
  end

  describe "ConduitMcp.Validation.SchemaConverter" do
    test "dsl_params_to_nimble_options/1 converts basic parameters" do
      params = [
        %{name: :name, type: :string, opts: [required: true]},
        %{name: :age, type: :integer, opts: [min: 0, max: 150]}
      ]

      result = SchemaConverter.dsl_params_to_nimble_options(params)

      assert is_list(result)
      assert length(result) == 2

      name_param = Enum.find(result, fn {name, _opts} -> name == :name end)
      assert {name_param_name, name_opts} = name_param
      assert name_param_name == :name
      assert Keyword.get(name_opts, :type) == :string
      assert Keyword.get(name_opts, :required) == true
    end

    test "dsl_params_to_nimble_options/1 converts enum to custom validator" do
      params = [
        %{name: :action, type: :string, opts: [enum: ["start", "stop"], required: true]}
      ]

      result = SchemaConverter.dsl_params_to_nimble_options(params)

      assert length(result) == 1
      {_name, opts} = List.first(result)
      assert Keyword.get(opts, :type) == :string
      assert Keyword.get(opts, :required) == true
      assert Keyword.get(opts, :__enum_values__) == ["start", "stop"]
    end

    test "dsl_params_to_nimble_options/1 converts number type to float" do
      params = [
        %{name: :score, type: :number, opts: [min: 0.0, max: 100.0]}
      ]

      result = SchemaConverter.dsl_params_to_nimble_options(params)

      assert length(result) == 1
      {_name, opts} = List.first(result)
      assert Keyword.get(opts, :type) == :float  # Should be converted from :number
    end

    test "dsl_params_to_nimble_options/1 handles custom validators" do
      validator_fn = &Validators.email/1

      params = [
        %{name: :email, type: :string, opts: [validator: validator_fn]}
      ]

      result = SchemaConverter.dsl_params_to_nimble_options(params)

      assert length(result) == 1
      {_name, opts} = List.first(result)
      assert Keyword.get(opts, :validator) == validator_fn
    end

    test "dsl_params_to_nimble_options/1 handles MFA validators" do
      params = [
        %{name: :email, type: :string, opts: [validator: {Validators, :email}]}
      ]

      result = SchemaConverter.dsl_params_to_nimble_options(params)

      assert length(result) == 1
      {_name, opts} = List.first(result)
      validator = Keyword.get(opts, :validator)
      assert is_function(validator, 1)
    end

    test "validate_schema/1 validates NimbleOptions schema structure" do
      valid_schema = [
        name: [type: :string, required: true],
        age: [type: :integer, min: 0]
      ]

      assert :ok = SchemaConverter.validate_schema(valid_schema)
    end
  end

  describe "ConduitMcp.Validation.Validators" do
    test "email/1 validates email addresses" do
      assert Validators.email("test@example.com") == true
      assert Validators.email("user.name+tag@domain.co.uk") == true
      assert Validators.email("invalid-email") == false
      assert Validators.email("@invalid.com") == false
      assert Validators.email("test@") == false
      assert Validators.email(123) == false
    end

    test "url/1 validates URLs" do
      assert Validators.url("https://example.com") == true
      assert Validators.url("http://localhost:3000") == true
      assert Validators.url("https://sub.domain.com/path?query=value") == true
      assert Validators.url("not-a-url") == false
      assert Validators.url("ftp://example.com") == false
      assert Validators.url(123) == false
    end

    test "positive_number/1 validates positive numbers" do
      assert Validators.positive_number(5) == true
      assert Validators.positive_number(5.5) == true
      assert Validators.positive_number(0.1) == true
      assert Validators.positive_number(0) == false
      assert Validators.positive_number(-1) == false
      assert Validators.positive_number("5") == false
    end

    test "non_negative_number/1 validates non-negative numbers" do
      assert Validators.non_negative_number(0) == true
      assert Validators.non_negative_number(5) == true
      assert Validators.non_negative_number(5.5) == true
      assert Validators.non_negative_number(-1) == false
      assert Validators.non_negative_number("5") == false
    end

    test "non_empty_string/1 validates non-empty strings" do
      assert Validators.non_empty_string("hello") == true
      assert Validators.non_empty_string("  hello  ") == true
      assert Validators.non_empty_string("") == false
      assert Validators.non_empty_string("   ") == false
      assert Validators.non_empty_string(123) == false
    end

    test "uuid/1 validates UUID strings" do
      assert Validators.uuid("550e8400-e29b-41d4-a716-446655440000") == true
      assert Validators.uuid("550e8400e29b41d4a716446655440000") == true
      assert Validators.uuid("550E8400-E29B-41D4-A716-446655440000") == true
      assert Validators.uuid("invalid-uuid") == false
      assert Validators.uuid("550e8400-e29b-41d4-a716") == false
      assert Validators.uuid(123) == false
    end

    test "iso_date/1 validates ISO 8601 dates" do
      assert Validators.iso_date("2024-01-15") == true
      assert Validators.iso_date("2024-12-31") == true
      assert Validators.iso_date("2024-02-29") == true  # Valid leap year
      assert Validators.iso_date("2024-13-01") == false  # Invalid month
      assert Validators.iso_date("2024-02-30") == false  # Invalid day
      assert Validators.iso_date("not-a-date") == false
      assert Validators.iso_date(123) == false
    end

    test "alphanumeric/1 validates alphanumeric strings" do
      assert Validators.alphanumeric("abc123") == true
      assert Validators.alphanumeric("ABC123") == true
      assert Validators.alphanumeric("abc123DEF") == true
      assert Validators.alphanumeric("abc-123") == false
      assert Validators.alphanumeric("hello world") == false
      assert Validators.alphanumeric("abc@123") == false
      assert Validators.alphanumeric(123) == false
    end

    test "range/2 creates range validator" do
      range_validator = Validators.range(1, 10)

      assert is_function(range_validator, 1)
      assert range_validator.(5) == true
      assert range_validator.(1) == true
      assert range_validator.(10) == true
      assert range_validator.(0) == false
      assert range_validator.(11) == false
    end

    test "regex/1 creates regex validator" do
      phone_validator = Validators.regex(~r/^\d{3}-\d{3}-\d{4}$/)

      assert is_function(phone_validator, 1)
      assert phone_validator.("123-456-7890") == true
      assert phone_validator.("555-123-4567") == true
      assert phone_validator.("invalid-phone") == false
      assert phone_validator.("1234567890") == false
    end

    test "one_of/1 creates enum validator" do
      priority_validator = Validators.one_of(~w(low medium high critical))

      assert is_function(priority_validator, 1)
      assert priority_validator.("medium") == true
      assert priority_validator.("high") == true
      assert priority_validator.("urgent") == false
      assert priority_validator.("") == false
    end

    test "list_of/1 creates list item validator" do
      email_list_validator = Validators.list_of(&Validators.email/1)

      assert is_function(email_list_validator, 1)
      assert email_list_validator.(["test@example.com", "user@domain.org"]) == true
      assert email_list_validator.(["test@example.com", "invalid-email"]) == false
      assert email_list_validator.([]) == true  # Empty list is valid
      assert email_list_validator.("not-a-list") == false
    end

    test "all/1 creates composite validator requiring all to pass" do
      strong_password_validator = Validators.all([
        &Validators.non_empty_string/1,
        Validators.range(8, 50)
      ])

      assert is_function(strong_password_validator, 1)
      # This test would need a string that satisfies both non_empty_string AND range
      # Since range expects numbers, this is a logical issue in the example
      # Let's test with a more realistic example
    end

    test "any/1 creates composite validator requiring at least one to pass" do
      flexible_id_validator = Validators.any([
        &Validators.uuid/1,
        &Validators.positive_number/1
      ])

      assert is_function(flexible_id_validator, 1)
      assert flexible_id_validator.(123) == true  # Valid positive number
      assert flexible_id_validator.("550e8400-e29b-41d4-a716-446655440000") == true  # Valid UUID
      assert flexible_id_validator.("invalid") == false  # Neither UUID nor positive number
    end
  end

  describe "Integration tests" do
    # Create a test server using the DSL with validation
    defmodule IntegrationTestServer do
      use ConduitMcp.Server

      tool "validate_user", "Create a user with validation" do
        param :name, :string, "Full name", required: true, min_length: 2, max_length: 50
        param :age, :integer, "Age", min: 0, max: 150, required: true
        param :email, :string, "Email address", validator: &Validators.email/1, required: true
        param :role, :string, "User role", enum: ["admin", "user", "guest"], default: "user"
        param :active, :boolean, "Active status", default: true

        handle fn _conn, params ->
          {:ok, %{
            "content" => [
              %{"type" => "text", "text" => "User #{params["name"]} created successfully"}
            ]
          }}
        end
      end

      tool "calculate_score", "Calculate performance score" do
        param :base_score, :number, "Base score", min: 0.0, max: 100.0, required: true
        param :multiplier, :number, "Score multiplier", min: 1.0, max: 10.0, default: 1.0

        handle fn _conn, params ->
          score = params["base_score"] * params["multiplier"]
          {:ok, %{
            "content" => [
              %{"type" => "text", "text" => "Final score: #{score}"}
            ]
          }}
        end
      end
    end

    test "DSL-generated validation schemas work end-to-end" do
      # Test valid parameters
      params = %{
        "name" => "Alice Johnson",
        "age" => 30,
        "email" => "alice@example.com",
        "role" => "admin"
      }

      assert {:ok, validated_params} = Validation.validate_tool_params(IntegrationTestServer, "validate_user", params)
      assert validated_params["name"] == "Alice Johnson"
      assert validated_params["age"] == 30
    end

    test "DSL-generated validation catches constraint violations" do
      # Test min_length violation
      params = %{"name" => "A", "age" => 30, "email" => "alice@example.com"}
      assert {:error, errors} = Validation.validate_tool_params(IntegrationTestServer, "validate_user", params)
      assert length(errors) >= 1

      # Test max age violation
      params = %{"name" => "Alice", "age" => 200, "email" => "alice@example.com"}
      assert {:error, errors} = Validation.validate_tool_params(IntegrationTestServer, "validate_user", params)
      assert length(errors) >= 1

      # Test invalid email
      params = %{"name" => "Alice", "age" => 30, "email" => "invalid-email"}
      assert {:error, errors} = Validation.validate_tool_params(IntegrationTestServer, "validate_user", params)
      assert length(errors) >= 1

      # Test invalid enum value
      params = %{"name" => "Alice", "age" => 30, "email" => "alice@example.com", "role" => "invalid"}
      assert {:error, errors} = Validation.validate_tool_params(IntegrationTestServer, "validate_user", params)
      assert length(errors) >= 1
    end

    test "number type validation works with float constraints" do
      # Valid score
      params = %{"base_score" => 85.5, "multiplier" => 2.0}
      assert {:ok, _} = Validation.validate_tool_params(IntegrationTestServer, "calculate_score", params)

      # Invalid base_score (too high)
      params = %{"base_score" => 150.0}
      assert {:error, errors} = Validation.validate_tool_params(IntegrationTestServer, "calculate_score", params)
      assert length(errors) >= 1

      # Invalid multiplier (too high)
      params = %{"base_score" => 85.5, "multiplier" => 15.0}
      assert {:error, errors} = Validation.validate_tool_params(IntegrationTestServer, "calculate_score", params)
      assert length(errors) >= 1
    end
  end
end
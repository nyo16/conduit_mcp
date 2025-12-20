defmodule ConduitMcp.Validation.Validators do
  @moduledoc """
  Common validation functions for use with the ConduitMCP DSL.

  This module provides pre-built validator functions that can be used
  with the `validator:` option in DSL parameter definitions. All
  validator functions return `true` for valid values, `false` for
  invalid values, or can return `{:error, message}` for custom
  error messages.

  ## Usage Examples

      # Using built-in email validator
      param :email, :string, "Email address", validator: &ConduitMcp.Validation.Validators.email/1

      # Using URL validator
      param :website, :string, "Website URL", validator: &ConduitMcp.Validation.Validators.url/1

      # Using positive number validator
      param :count, :integer, "Item count", validator: &ConduitMcp.Validation.Validators.positive_number/1

  ## Custom Validators

  You can also create custom validators that follow the same pattern:

      defmodule MyApp.Validators do
        def custom_id(value) when is_binary(value) do
          String.match?(value, ~r/^[A-Z]{2}\d{6}$/)
        end

        def custom_id(_), do: false
      end

      # Usage in DSL
      param :id, :string, "Custom ID", validator: &MyApp.Validators.custom_id/1

  """

  @email_regex ~r/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
  @url_regex ~r/^https?:\/\/[^\s\/\$\.\?\#].[^\s]*$/

  @doc """
  Validates email addresses using a basic regex pattern.

  ## Examples

      iex> ConduitMcp.Validation.Validators.email("user@example.com")
      true

      iex> ConduitMcp.Validation.Validators.email("invalid-email")
      false

      iex> ConduitMcp.Validation.Validators.email(123)
      false

  """
  def email(value) when is_binary(value) do
    String.match?(value, @email_regex)
  end

  def email(_), do: false

  @doc """
  Validates HTTP and HTTPS URLs.

  ## Examples

      iex> ConduitMcp.Validation.Validators.url("https://example.com")
      true

      iex> ConduitMcp.Validation.Validators.url("http://localhost:3000")
      true

      iex> ConduitMcp.Validation.Validators.url("not-a-url")
      false

      iex> ConduitMcp.Validation.Validators.url("ftp://example.com")
      false

  """
  def url(value) when is_binary(value) do
    String.match?(value, @url_regex)
  end

  def url(_), do: false

  @doc """
  Validates that a number is positive (greater than 0).

  ## Examples

      iex> ConduitMcp.Validation.Validators.positive_number(5)
      true

      iex> ConduitMcp.Validation.Validators.positive_number(5.5)
      true

      iex> ConduitMcp.Validation.Validators.positive_number(0)
      false

      iex> ConduitMcp.Validation.Validators.positive_number(-1)
      false

  """
  def positive_number(value) when is_number(value) do
    value > 0
  end

  def positive_number(_), do: false

  @doc """
  Validates that a number is non-negative (greater than or equal to 0).

  ## Examples

      iex> ConduitMcp.Validation.Validators.non_negative_number(0)
      true

      iex> ConduitMcp.Validation.Validators.non_negative_number(5)
      true

      iex> ConduitMcp.Validation.Validators.non_negative_number(-1)
      false

  """
  def non_negative_number(value) when is_number(value) do
    value >= 0
  end

  def non_negative_number(_), do: false

  @doc """
  Validates that a string is non-empty (contains at least one character).

  ## Examples

      iex> ConduitMcp.Validation.Validators.non_empty_string("hello")
      true

      iex> ConduitMcp.Validation.Validators.non_empty_string("   ")
      false

      iex> ConduitMcp.Validation.Validators.non_empty_string("")
      false

  """
  def non_empty_string(value) when is_binary(value) do
    String.trim(value) != ""
  end

  def non_empty_string(_), do: false

  @doc """
  Validates UUID strings in various formats.

  Supports both hyphenated (8-4-4-4-12) and non-hyphenated formats.

  ## Examples

      iex> ConduitMcp.Validation.Validators.uuid("550e8400-e29b-41d4-a716-446655440000")
      true

      iex> ConduitMcp.Validation.Validators.uuid("550e8400e29b41d4a716446655440000")
      true

      iex> ConduitMcp.Validation.Validators.uuid("invalid-uuid")
      false

  """
  def uuid(value) when is_binary(value) do
    # Hyphenated UUID format
    hyphenated = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

    # Non-hyphenated UUID format
    non_hyphenated = ~r/^[0-9a-f]{32}$/i

    String.match?(value, hyphenated) or String.match?(value, non_hyphenated)
  end

  def uuid(_), do: false

  @doc """
  Validates ISO 8601 date strings.

  Supports basic YYYY-MM-DD format.

  ## Examples

      iex> ConduitMcp.Validation.Validators.iso_date("2024-01-15")
      true

      iex> ConduitMcp.Validation.Validators.iso_date("2024-13-01")
      false

      iex> ConduitMcp.Validation.Validators.iso_date("not-a-date")
      false

  """
  def iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> true
      {:error, _} -> false
    end
  end

  def iso_date(_), do: false

  @doc """
  Validates that a value is within a specific range (inclusive).

  Returns a validator function that checks if the value is between
  min and max (inclusive).

  ## Examples

      iex> validator = ConduitMcp.Validation.Validators.range(1, 10)
      iex> validator.(5)
      true

      iex> validator = ConduitMcp.Validation.Validators.range(1, 10)
      iex> validator.(15)
      false

  Usage in DSL:

      param :score, :integer, "Score", validator: ConduitMcp.Validation.Validators.range(0, 100)

  """
  def range(min, max) when is_number(min) and is_number(max) and min <= max do
    fn value when is_number(value) ->
      value >= min and value <= max
    end
  end

  @doc """
  Validates that a string matches a specific regex pattern.

  Returns a validator function that checks if the string matches
  the provided regex.

  ## Examples

      iex> phone_validator = ConduitMcp.Validation.Validators.regex(~r/^\d{3}-\d{3}-\d{4}$/)
      iex> phone_validator.("123-456-7890")
      true

      iex> phone_validator = ConduitMcp.Validation.Validators.regex(~r/^\d{3}-\d{3}-\d{4}$/)
      iex> phone_validator.("invalid-phone")
      false

  Usage in DSL:

      param :phone, :string, "Phone", validator: ConduitMcp.Validation.Validators.regex(~r/^\d{3}-\d{3}-\d{4}$/)

  """
  def regex(pattern) when is_struct(pattern, Regex) do
    fn value when is_binary(value) ->
      String.match?(value, pattern)
    end
  end

  @doc """
  Validates that a string contains only alphanumeric characters.

  ## Examples

      iex> ConduitMcp.Validation.Validators.alphanumeric("abc123")
      true

      iex> ConduitMcp.Validation.Validators.alphanumeric("abc-123")
      false

      iex> ConduitMcp.Validation.Validators.alphanumeric("hello world")
      false

  """
  def alphanumeric(value) when is_binary(value) do
    String.match?(value, ~r/^[a-zA-Z0-9]+$/)
  end

  def alphanumeric(_), do: false

  @doc """
  Validates that all items in a list pass a given validator.

  Returns a validator function that checks each item in a list
  against the provided validator function.

  ## Examples

      iex> email_list_validator = ConduitMcp.Validation.Validators.list_of(&ConduitMcp.Validation.Validators.email/1)
      iex> email_list_validator.(["user1@example.com", "user2@example.com"])
      true

      iex> email_list_validator = ConduitMcp.Validation.Validators.list_of(&ConduitMcp.Validation.Validators.email/1)
      iex> email_list_validator.(["valid@example.com", "invalid-email"])
      false

  Usage in DSL:

      param :emails, {:array, :string}, "Email list",
        validator: ConduitMcp.Validation.Validators.list_of(&ConduitMcp.Validation.Validators.email/1)

  """
  def list_of(item_validator) when is_function(item_validator, 1) do
    fn
      list when is_list(list) ->
        Enum.all?(list, item_validator)

      _ ->
        false
    end
  end

  @doc """
  Validates that a value is one of the specified allowed values.

  Returns a validator function that checks if the value is in
  the provided list of allowed values.

  ## Examples

      iex> priority_validator = ConduitMcp.Validation.Validators.one_of(["low", "medium", "high"])
      iex> priority_validator.("medium")
      true

      iex> priority_validator = ConduitMcp.Validation.Validators.one_of(["low", "medium", "high"])
      iex> priority_validator.("urgent")
      false

  Note: This is similar to the `enum:` option in DSL, but can be used
  when you need more complex validation logic.

  Usage in DSL:

      param :priority, :string, "Priority",
        validator: ConduitMcp.Validation.Validators.one_of(~w(low medium high critical))

  """
  def one_of(allowed_values) when is_list(allowed_values) do
    fn value ->
      value in allowed_values
    end
  end

  @doc """
  Creates a composite validator that requires all provided validators to pass.

  Returns a validator function that checks if all validators return true.

  ## Examples

      iex> strong_password = ConduitMcp.Validation.Validators.all([
      ...>   &ConduitMcp.Validation.Validators.non_empty_string/1,
      ...>   ConduitMcp.Validation.Validators.range(8, 50)
      ...> ])
      iex> strong_password.("password123")
      true

  Usage in DSL:

      param :password, :string, "Password",
        validator: ConduitMcp.Validation.Validators.all([
          &ConduitMcp.Validation.Validators.non_empty_string/1,
          ConduitMcp.Validation.Validators.range(8, 128)
        ])

  """
  def all(validators) when is_list(validators) do
    fn value ->
      Enum.all?(validators, fn validator -> validator.(value) end)
    end
  end

  @doc """
  Creates a composite validator that requires at least one provided validator to pass.

  Returns a validator function that checks if any validator returns true.

  ## Examples

      iex> flexible_id = ConduitMcp.Validation.Validators.any([
      ...>   &ConduitMcp.Validation.Validators.uuid/1,
      ...>   &ConduitMcp.Validation.Validators.positive_number/1
      ...> ])
      iex> flexible_id.(123)
      true

      iex> flexible_id = ConduitMcp.Validation.Validators.any([
      ...>   &ConduitMcp.Validation.Validators.uuid/1,
      ...>   &ConduitMcp.Validation.Validators.positive_number/1
      ...> ])
      iex> flexible_id.("550e8400-e29b-41d4-a716-446655440000")
      true

  Usage in DSL:

      param :id, :string, "ID",
        validator: ConduitMcp.Validation.Validators.any([
          &ConduitMcp.Validation.Validators.uuid/1,
          ConduitMcp.Validation.Validators.regex(~r/^[A-Z]{2}\d+$/)
        ])

  """
  def any(validators) when is_list(validators) do
    fn value ->
      Enum.any?(validators, fn validator -> validator.(value) end)
    end
  end
end
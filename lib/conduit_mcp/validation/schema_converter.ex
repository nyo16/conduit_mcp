defmodule ConduitMcp.Validation.SchemaConverter do
  @moduledoc """
  Converts DSL parameter definitions to NimbleOptions validation schemas.

  This module takes parameter definitions from the ConduitMCP DSL and
  converts them into NimbleOptions schemas for runtime validation.
  It handles type mapping, constraint extraction, and validation rule
  compilation.

  ## Type Mapping

  DSL types are mapped to NimbleOptions types as follows:

  - `:string` -> `:string`
  - `:integer` -> `:integer`
  - `:number` -> `:number` (float)
  - `:boolean` -> `:boolean`
  - `:object` -> `:map` (with nested validation)
  - `:array` -> `{:list, type}` where type is the item type
  - `{:array, item_type}` -> `{:list, converted_item_type}`

  ## Validation Options

  DSL options are converted to NimbleOptions validation rules:

  - `required: true` -> `required: true`
  - `enum: [...]` -> `in: [...]`
  - `default: value` -> `default: value`
  - `min: value` -> `min: value`
  - `max: value` -> `max: value`
  - `min_length: value` -> `min_length: value`
  - `max_length: value` -> `max_length: value`
  - `validator: function` -> `validator: function`

  """

  @doc """
  Converts a list of DSL parameter definitions to a NimbleOptions schema.

  ## Examples

      iex> params = [
      ...>   %{name: :name, type: :string, opts: [required: true]},
      ...>   %{name: :age, type: :integer, opts: [min: 0, max: 150]}
      ...> ]
      iex> ConduitMcp.Validation.SchemaConverter.dsl_params_to_nimble_options(params)
      [
        name: [type: :string, required: true],
        age: [type: :integer, min: 0, max: 150]
      ]

  """
  def dsl_params_to_nimble_options(params) when is_list(params) do
    Enum.map(params, &convert_param_to_nimble_option/1)
  end

  @doc """
  Compiles a complete tool definition to a NimbleOptions validation schema.

  Takes a tool definition with parameters and converts it to a schema
  that can be used for runtime validation.
  """
  def compile_validation_schema(%{params: params}) do
    dsl_params_to_nimble_options(params)
  end

  def compile_validation_schema(%{args: args}) do
    # For prompts - args have the same structure as params
    dsl_params_to_nimble_options(args)
  end

  # Private functions

  defp convert_param_to_nimble_option(%{name: name, type: type, opts: opts}) do
    base_opts = [type: convert_type(type)]
    validation_opts = extract_validation_opts(opts)

    {name, base_opts ++ validation_opts}
  end

  defp convert_type(:string), do: :string
  defp convert_type(:integer), do: :integer
  defp convert_type(:number), do: :float  # NimbleOptions uses :float, not :number
  defp convert_type(:boolean), do: :boolean
  defp convert_type(:object), do: :map
  defp convert_type(:array), do: {:list, :any}
  defp convert_type({:array, item_type}), do: {:list, convert_type(item_type)}
  defp convert_type(:null), do: :any
  defp convert_type(type) when is_atom(type), do: type
  defp convert_type(type), do: type

  defp extract_validation_opts(opts) do
    opts
    |> Enum.reduce([], &convert_validation_opt/2)
    |> Enum.reverse()
  end

  # Required option
  defp convert_validation_opt({:required, true}, acc) do
    [{:required, true} | acc]
  end

  defp convert_validation_opt({:required, false}, acc) do
    # Don't add required: false as it's the default
    acc
  end

  # Enum becomes a special marker that we'll handle at runtime
  defp convert_validation_opt({:enum, values}, acc) when is_list(values) do
    # Store enum values as a special option that we can validate at runtime
    [{:__enum_values__, values} | acc]
  end

  # Default value
  defp convert_validation_opt({:default, value}, acc) do
    [{:default, value} | acc]
  end

  # Numeric constraints - store as custom markers since NimbleOptions doesn't support them
  defp convert_validation_opt({:min, value}, acc) when is_number(value) do
    [{:__min_value__, value} | acc]
  end

  defp convert_validation_opt({:max, value}, acc) when is_number(value) do
    [{:__max_value__, value} | acc]
  end

  # String length constraints - store as custom markers
  defp convert_validation_opt({:min_length, value}, acc) when is_integer(value) and value >= 0 do
    [{:__min_length__, value} | acc]
  end

  defp convert_validation_opt({:max_length, value}, acc) when is_integer(value) and value >= 0 do
    [{:__max_length__, value} | acc]
  end

  # Custom validator function
  defp convert_validation_opt({:validator, validator}, acc) when is_function(validator, 1) do
    [{:validator, validator} | acc]
  end

  defp convert_validation_opt({:validator, {module, function}}, acc) when is_atom(module) and is_atom(function) do
    # Convert MFA tuple to function
    validator_fn = fn value -> apply(module, function, [value]) end
    [{:validator, validator_fn} | acc]
  end

  # Type coercion options
  defp convert_validation_opt({:type_coercion, true}, acc) do
    # NimbleOptions doesn't have explicit type coercion flag
    # We handle this in the validation module
    acc
  end

  # Nested object fields (for future nested object support)
  defp convert_validation_opt({:fields, fields}, acc) when is_list(fields) do
    # Convert nested fields to nested schema
    nested_schema = dsl_params_to_nimble_options(fields)
    [{:schema, nested_schema} | acc]
  end

  # Unknown options are ignored with a warning
  defp convert_validation_opt({key, _value}, acc) do
    require Logger
    Logger.warning("Unknown validation option ignored: #{inspect(key)}")
    acc
  end

  @doc """
  Validates a NimbleOptions schema definition.

  Checks if the generated schema is valid for NimbleOptions.
  Used during compile time to catch schema generation errors.
  """
  def validate_schema(schema) do
    try do
      # Remove custom constraint markers before validating with NimbleOptions
      clean_schema = remove_custom_constraint_markers(schema)

      # Test the schema with empty options to validate its structure
      NimbleOptions.validate([], clean_schema)
      :ok
    rescue
      error ->
        {:error, Exception.message(error)}
    catch
      :error, %ArgumentError{} = error ->
        {:error, Exception.message(error)}
    end
  end

  # Private helper to clean schema - same as in main validation module
  defp remove_custom_constraint_markers(schema) do
    custom_markers = [
      :__enum_values__, :__min_value__, :__max_value__, :__min_length__, :__max_length__,
      :validator, :min, :max, :min_length, :max_length, :enum
    ]

    Enum.map(schema, fn {param_name, param_opts} ->
      clean_opts = Enum.reduce(custom_markers, param_opts, fn marker, acc ->
        Keyword.delete(acc, marker)
      end)
      {param_name, clean_opts}
    end)
  end

  @doc """
  Enhanced error formatter for NimbleOptions validation errors.

  Takes a NimbleOptions.ValidationError and converts it to detailed
  error information suitable for MCP responses.
  """
  def format_detailed_errors(%NimbleOptions.ValidationError{} = error, original_params) do
    message = Exception.message(error)

    # Try to parse the error message to extract parameter information
    case parse_validation_error(message, original_params) do
      {:ok, detailed_errors} -> detailed_errors
      {:error, _} ->
        # Fallback to generic error
        [%{
          parameter: nil,
          value: nil,
          message: message
        }]
    end
  end

  # Private helper functions for error parsing

  defp parse_validation_error(message, original_params) do
    # This is a simplified parser - in a full implementation,
    # we'd parse NimbleOptions error messages more thoroughly
    cond do
      String.contains?(message, "required") ->
        parse_required_error(message, original_params)

      String.contains?(message, "invalid value") ->
        parse_invalid_value_error(message, original_params)

      String.contains?(message, "expected") ->
        parse_type_error(message, original_params)

      true ->
        {:error, :unparseable}
    end
  end

  defp parse_required_error(message, _original_params) do
    # Extract required field name from error message
    case Regex.run(~r/required option (\w+) not found/, message) do
      [_, field_name] ->
        {:ok, [%{
          parameter: field_name,
          value: nil,
          message: "is required"
        }]}

      nil ->
        {:error, :no_field_found}
    end
  end

  defp parse_invalid_value_error(message, original_params) do
    # Extract field and value information
    case Regex.run(~r/invalid value for (\w+):/, message) do
      [_, field_name] ->
        value = get_original_value(field_name, original_params)
        constraint_message = extract_constraint_message(message)

        {:ok, [%{
          parameter: field_name,
          value: value,
          message: constraint_message
        }]}

      nil ->
        {:error, :no_field_found}
    end
  end

  defp parse_type_error(message, original_params) do
    # Extract type mismatch information
    case Regex.run(~r/expected (\w+) for (\w+)/, message) do
      [_, expected_type, field_name] ->
        value = get_original_value(field_name, original_params)

        {:ok, [%{
          parameter: field_name,
          value: value,
          message: "must be of type #{expected_type}"
        }]}

      nil ->
        {:error, :no_type_info}
    end
  end

  defp get_original_value(field_name, original_params) when is_map(original_params) do
    Map.get(original_params, field_name) || Map.get(original_params, String.to_atom(field_name))
  end

  defp get_original_value(_field_name, _original_params), do: nil

  defp extract_constraint_message(message) do
    cond do
      String.contains?(message, "must be") ->
        # Extract "must be ..." part
        case Regex.run(~r/must be (.+)$/, message) do
          [_, constraint] -> constraint
          nil -> "invalid value"
        end

      String.contains?(message, "expected") ->
        "invalid value"

      true ->
        "validation failed"
    end
  end
end
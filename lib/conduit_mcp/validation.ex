defmodule ConduitMcp.Validation do
  @moduledoc """
  Runtime parameter validation using NimbleOptions.

  This module provides runtime parameter validation for MCP tools,
  prompts, and resources using NimbleOptions schemas. It works alongside
  the existing JSON Schema generation to provide both client-side
  validation (JSON Schema) and server-side validation (NimbleOptions).

  ## Features

  - Runtime parameter validation with detailed error messages
  - Type coercion (string "123" -> integer 123)
  - Advanced constraints (min/max, length limits)
  - Custom validator functions
  - Compile-time schema generation for performance

  ## Configuration

  Validation behavior can be configured in your application config:

      config :conduit_mcp, :validation,
        runtime_validation: true,           # Enable/disable validation
        strict_mode: true,                  # Fail on errors vs. log and continue
        type_coercion: true,                # Automatic type conversion
        log_validation_errors: false        # Log validation failures

  """

  require Logger
  alias ConduitMcp.Validation.SchemaConverter

  @doc """
  Validates tool parameters using the compiled NimbleOptions schema.

  Returns `{:ok, validated_params}` with potentially coerced types,
  or `{:error, validation_errors}` with detailed error information.

  ## Examples

      iex> ConduitMcp.Validation.validate_tool_params(MyServer, "greet", %{"name" => "Alice"})
      {:ok, %{"name" => "Alice"}}

      iex> ConduitMcp.Validation.validate_tool_params(MyServer, "calc", %{"age" => "-5"})
      {:error, [%{parameter: "age", value: -5, message: "must be greater than or equal to 0"}]}

  """
  def validate_tool_params(server_module, tool_name, params) when is_map(params) do
    if validation_enabled?() do
      case get_tool_validation_schema(server_module, tool_name) do
        {:ok, schema} ->
          # Add telemetry for validation attempts
          :telemetry.execute([:conduit_mcp, :validation, :started], %{}, %{
            tool: tool_name,
            server: server_module
          })

          result = validate_with_schema(schema, params, tool_name)

          # Add telemetry for validation results
          case result do
            {:ok, _} ->
              :telemetry.execute([:conduit_mcp, :validation, :success], %{}, %{
                tool: tool_name,
                server: server_module
              })
            {:error, errors} ->
              :telemetry.execute([:conduit_mcp, :validation, :failed], %{error_count: length(errors)}, %{
                tool: tool_name,
                server: server_module,
                errors: errors
              })
          end

          result

        {:error, :tool_not_found} ->
          error = [%{
            parameter: nil,
            value: nil,
            message: "Tool '#{tool_name}' not found"
          }]
          {:error, format_validation_errors(error)}

        {:error, :no_validation_schema} ->
          # Server doesn't have validation schemas - skip validation
          {:ok, params}
      end
    else
      # Validation disabled - pass through
      {:ok, params}
    end
  end

  def validate_tool_params(_server_module, _tool_name, params) do
    {:error, [%{
      parameter: nil,
      value: params,
      message: "Parameters must be a map"
    }]}
  end

  @doc """
  Validates prompt arguments using the compiled NimbleOptions schema.

  Similar to `validate_tool_params/3` but for prompt arguments.
  """
  def validate_prompt_args(server_module, prompt_name, args) when is_map(args) do
    if validation_enabled?() do
      case get_prompt_validation_schema(server_module, prompt_name) do
        {:ok, schema} ->
          validate_with_schema(schema, args, prompt_name)

        {:error, :prompt_not_found} ->
          {:error, [%{
            parameter: nil,
            value: nil,
            message: "Prompt '#{prompt_name}' not found"
          }]}

        {:error, :no_validation_schema} ->
          # Server doesn't have validation schemas - skip validation
          {:ok, args}
      end
    else
      {:ok, args}
    end
  end

  def validate_prompt_args(_server_module, _prompt_name, args) do
    {:error, [%{
      parameter: nil,
      value: args,
      message: "Arguments must be a map"
    }]}
  end

  @doc """
  Formats validation errors into a standardized format for JSON-RPC responses.

  Takes NimbleOptions validation errors and converts them to a format
  suitable for MCP error responses.

  ## Examples

      iex> errors = [%{parameter: "age", value: -5, message: "must be >= 0"}]
      iex> ConduitMcp.Validation.format_validation_errors(errors)
      [%{"parameter" => "age", "value" => -5, "message" => "must be >= 0"}]

  """
  def format_validation_errors(errors) when is_list(errors) do
    Enum.map(errors, &format_single_error/1)
  end

  # Private functions

  defp validation_enabled? do
    Application.get_env(:conduit_mcp, :validation, [])
    |> Keyword.get(:runtime_validation, true)
  end


  defp type_coercion_enabled? do
    Application.get_env(:conduit_mcp, :validation, [])
    |> Keyword.get(:type_coercion, true)
  end

  defp log_validation_errors? do
    Application.get_env(:conduit_mcp, :validation, [])
    |> Keyword.get(:log_validation_errors, false)
  end

  defp get_tool_validation_schema(server_module, tool_name) do
    if function_exported?(server_module, :__validation_schema_for_tool__, 1) do
      case server_module.__validation_schema_for_tool__(tool_name) do
        nil -> {:error, :tool_not_found}
        schema -> {:ok, schema}
      end
    else
      # Server doesn't use DSL or doesn't have validation schemas - skip validation
      {:error, :no_validation_schema}
    end
  end

  defp get_prompt_validation_schema(server_module, prompt_name) do
    if function_exported?(server_module, :__validation_schema_for_prompt__, 1) do
      case server_module.__validation_schema_for_prompt__(prompt_name) do
        nil -> {:error, :prompt_not_found}
        schema -> {:ok, schema}
      end
    else
      # Server doesn't use DSL or doesn't have validation schemas - skip validation
      {:error, :no_validation_schema}
    end
  end

  defp validate_with_schema(schema, params, context) do
    # Convert string keys to atoms for validation
    atom_params = convert_keys_to_atoms(params)

    # First, handle custom validations that NimbleOptions doesn't support directly
    case validate_custom_constraints(atom_params, schema) do
      {:error, errors} ->
        formatted_errors = format_validation_errors(errors)
        {:error, formatted_errors}

      {:ok, preprocessed_params} ->
        # Apply type coercion if enabled
        coerced_params = if type_coercion_enabled?() do
          apply_type_coercion(preprocessed_params, schema)
        else
          preprocessed_params
        end

        # Remove custom constraint markers and convert map to keyword list for NimbleOptions
        clean_schema = remove_custom_constraint_markers(schema)
        keyword_params = Map.to_list(coerced_params)

        case NimbleOptions.validate(keyword_params, clean_schema) do
          {:ok, validated_keyword_params} ->
            # Convert back to map and string keys for consistency
            validated_params = Map.new(validated_keyword_params)
            string_params = convert_keys_to_strings(validated_params)
            {:ok, string_params}

          {:error, %NimbleOptions.ValidationError{} = error} ->
            formatted_errors = format_nimble_options_error(error, params)

            if log_validation_errors?() do
              Logger.warning("Validation failed for #{context}: #{inspect(formatted_errors)}")
            end

            {:error, formatted_errors}
        end
    end
  end

  defp convert_keys_to_atoms(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      atom_key = if is_binary(key), do: String.to_atom(key), else: key
      {atom_key, convert_keys_to_atoms(value)}
    end
  end

  defp convert_keys_to_atoms(list) when is_list(list) do
    Enum.map(list, &convert_keys_to_atoms/1)
  end

  defp convert_keys_to_atoms(value), do: value

  defp convert_keys_to_strings(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      string_key = if is_atom(key), do: Atom.to_string(key), else: key
      {string_key, convert_keys_to_strings(value)}
    end
  end

  defp convert_keys_to_strings(list) when is_list(list) do
    Enum.map(list, &convert_keys_to_strings/1)
  end

  defp convert_keys_to_strings(value), do: value

  defp format_nimble_options_error(%NimbleOptions.ValidationError{} = error, original_params) do
    # Use the detailed error formatter from SchemaConverter
    raw_errors = SchemaConverter.format_detailed_errors(error, original_params)
    # Format to use string keys like custom constraint errors
    format_validation_errors(raw_errors)
  end

  defp format_single_error(%{parameter: param, value: value, message: message}) do
    %{
      "parameter" => param,
      "value" => value,
      "message" => message
    }
  end

  defp format_single_error(error) when is_map(error) do
    # Handle different error formats
    Map.new(error, fn {k, v} -> {to_string(k), v} end)
  end

  # Custom constraint validation functions

  defp validate_custom_constraints(params, schema) do
    with {:ok, params} <- validate_enum_constraints(params, schema),
         {:ok, params} <- validate_numeric_constraints(params, schema),
         {:ok, params} <- validate_string_length_constraints(params, schema),
         {:ok, params} <- validate_custom_validator_constraints(params, schema) do
      {:ok, params}
    end
  end

  defp validate_enum_constraints(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc_params} ->
      enum_values = Keyword.get(param_opts, :__enum_values__) || Keyword.get(param_opts, :enum)

      case enum_values do
        nil ->
          {:cont, {:ok, acc_params}}

        enum_values ->
          param_value = Map.get(acc_params, param_name)

          if param_value == nil or param_value in enum_values do
            {:cont, {:ok, acc_params}}
          else
            error = %{
              parameter: to_string(param_name),
              value: param_value,
              message: "must be one of #{inspect(enum_values)}"
            }
            {:halt, {:error, [error]}}
          end
      end
    end)
  end

  defp validate_numeric_constraints(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc_params} ->
      param_value = Map.get(acc_params, param_name)

      # Skip validation if parameter is nil
      if param_value == nil do
        {:cont, {:ok, acc_params}}
      else
        with {:ok, _} <- validate_min_value(param_name, param_value, param_opts),
             {:ok, _} <- validate_max_value(param_name, param_value, param_opts) do
          {:cont, {:ok, acc_params}}
        else
          {:error, error} -> {:halt, {:error, [error]}}
        end
      end
    end)
  end

  defp validate_min_value(param_name, value, opts) do
    min_val = Keyword.get(opts, :__min_value__) || Keyword.get(opts, :min)

    case min_val do
      nil -> {:ok, value}
      min_val when is_number(value) and value >= min_val -> {:ok, value}
      min_val when is_number(value) ->
        {:error, %{
          parameter: to_string(param_name),
          value: value,
          message: "must be greater than or equal to #{min_val}"
        }}
      _ -> {:ok, value}  # Not a number, skip min validation
    end
  end

  defp validate_max_value(param_name, value, opts) do
    max_val = Keyword.get(opts, :__max_value__) || Keyword.get(opts, :max)

    case max_val do
      nil -> {:ok, value}
      max_val when is_number(value) and value <= max_val -> {:ok, value}
      max_val when is_number(value) ->
        {:error, %{
          parameter: to_string(param_name),
          value: value,
          message: "must be less than or equal to #{max_val}"
        }}
      _ -> {:ok, value}  # Not a number, skip max validation
    end
  end

  defp validate_string_length_constraints(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc_params} ->
      param_value = Map.get(acc_params, param_name)

      # Skip validation if parameter is nil
      if param_value == nil do
        {:cont, {:ok, acc_params}}
      else
        with {:ok, _} <- validate_min_length(param_name, param_value, param_opts),
             {:ok, _} <- validate_max_length(param_name, param_value, param_opts) do
          {:cont, {:ok, acc_params}}
        else
          {:error, error} -> {:halt, {:error, [error]}}
        end
      end
    end)
  end

  defp validate_min_length(param_name, value, opts) do
    min_len = Keyword.get(opts, :__min_length__) || Keyword.get(opts, :min_length)

    case min_len do
      nil -> {:ok, value}
      min_len when is_binary(value) and byte_size(value) >= min_len -> {:ok, value}
      min_len when is_binary(value) ->
        {:error, %{
          parameter: to_string(param_name),
          value: value,
          message: "must be at least #{min_len} characters long"
        }}
      _ -> {:ok, value}  # Not a string, skip length validation
    end
  end

  defp validate_max_length(param_name, value, opts) do
    max_len = Keyword.get(opts, :__max_length__) || Keyword.get(opts, :max_length)

    case max_len do
      nil -> {:ok, value}
      max_len when is_binary(value) and byte_size(value) <= max_len -> {:ok, value}
      max_len when is_binary(value) ->
        {:error, %{
          parameter: to_string(param_name),
          value: value,
          message: "must be no more than #{max_len} characters long"
        }}
      _ -> {:ok, value}  # Not a string, skip length validation
    end
  end

  defp validate_custom_validator_constraints(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc_params} ->
      param_value = Map.get(acc_params, param_name)

      case Keyword.get(param_opts, :validator) do
        nil ->
          {:cont, {:ok, acc_params}}

        validator when is_function(validator, 1) ->
          # Skip validation if parameter is nil
          if param_value == nil do
            {:cont, {:ok, acc_params}}
          else
            try do
              if validator.(param_value) do
                {:cont, {:ok, acc_params}}
              else
                error = %{
                  parameter: to_string(param_name),
                  value: param_value,
                  message: "failed custom validation"
                }
                {:halt, {:error, [error]}}
              end
            rescue
              _ ->
                error = %{
                  parameter: to_string(param_name),
                  value: param_value,
                  message: "validation function error"
                }
                {:halt, {:error, [error]}}
            end
          end
      end
    end)
  end

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

  defp apply_type_coercion(params, schema) do
    Enum.reduce(params, %{}, fn {param_name, value}, acc ->
      case Enum.find(schema, fn {name, _opts} -> name == param_name end) do
        {_name, param_opts} ->
          type = Keyword.get(param_opts, :type)
          coerced_value = coerce_value(value, type)
          Map.put(acc, param_name, coerced_value)

        nil ->
          # Parameter not in schema, keep as-is
          Map.put(acc, param_name, value)
      end
    end)
  end

  defp coerce_value(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {int_val, ""} -> int_val
      _ -> value  # Can't coerce, keep original
    end
  end

  defp coerce_value(value, :float) when is_binary(value) do
    case Float.parse(value) do
      {float_val, ""} -> float_val
      _ -> value  # Can't coerce, keep original
    end
  end

  defp coerce_value(value, :boolean) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      "1" -> true
      "0" -> false
      _ -> value  # Can't coerce, keep original
    end
  end

  defp coerce_value(value, _type), do: value  # No coercion needed or supported
end
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
          validate_with_schema(schema, params, tool_name)

        {:error, :tool_not_found} ->
          error = [
            %{
              parameter: nil,
              value: nil,
              message: "Tool '#{tool_name}' not found"
            }
          ]

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
    {:error,
     [
       %{
         parameter: nil,
         value: params,
         message: "Parameters must be a map"
       }
     ]}
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
          {:error,
           [
             %{
               parameter: nil,
               value: nil,
               message: "Prompt '#{prompt_name}' not found"
             }
           ]}

        {:error, :no_validation_schema} ->
          # Server doesn't have validation schemas - skip validation
          {:ok, args}
      end
    else
      {:ok, args}
    end
  end

  def validate_prompt_args(_server_module, _prompt_name, args) do
    {:error,
     [
       %{
         parameter: nil,
         value: args,
         message: "Arguments must be a map"
       }
     ]}
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

  @doc """
  Updates the validation configuration at runtime.

  Writes to both Application env and persistent_term so that
  the change is visible immediately to all concurrent readers.
  """
  def update_validation_config(config) when is_list(config) do
    Application.put_env(:conduit_mcp, :validation, config)
    :persistent_term.put({ConduitMcp, :validation_config}, config)
    :ok
  end

  defp validation_config do
    :persistent_term.get({ConduitMcp, :validation_config}, [])
  end

  defp validation_enabled? do
    Keyword.get(validation_config(), :runtime_validation, true)
  end

  defp get_tool_validation_schema(server_module, tool_name) do
    if ConduitMcp.ServerMeta.has?(server_module, :validation_schema_tool) do
      case server_module.__validation_schema_for_tool__(tool_name) do
        nil -> {:error, :tool_not_found}
        {_full, _clean} = dual -> {:ok, dual}
        schema -> {:ok, {schema, nil}}
      end
    else
      # Server doesn't use DSL or doesn't have validation schemas - skip validation
      {:error, :no_validation_schema}
    end
  end

  defp get_prompt_validation_schema(server_module, prompt_name) do
    if ConduitMcp.ServerMeta.has?(server_module, :validation_schema_prompt) do
      case server_module.__validation_schema_for_prompt__(prompt_name) do
        nil -> {:error, :prompt_not_found}
        {_full, _clean} = dual -> {:ok, dual}
        schema -> {:ok, {schema, nil}}
      end
    else
      # Server doesn't use DSL or doesn't have validation schemas - skip validation
      {:error, :no_validation_schema}
    end
  end

  defp validate_with_schema({full_schema, precomputed_clean}, params, context) do
    config = validation_config()

    # Atomise keys for NimbleOptions — schema-driven for nested objects.
    atom_params = normalize_params(params, full_schema)

    # Coerce *before* checking constraints. The custom checks are type-specific
    # — `check_min_value/3` ignores a binary, and `check_custom_validator/3`
    # would hand the user's function a binary — so running them on uncoerced
    # input makes `min:`/`max:`/`validator:` bypassable by sending a number as a
    # string: the check skips it, coercion then turns it into a number, and the
    # clean schema has already had those markers stripped, so NimbleOptions does
    # not check them either. They failed *open*.
    coerced_params =
      if Keyword.get(config, :type_coercion, true) do
        apply_type_coercion(atom_params, full_schema)
      else
        atom_params
      end

    # Handle custom validations that NimbleOptions doesn't support directly
    case validate_custom_constraints(coerced_params, full_schema) do
      {:error, errors} ->
        formatted_errors = format_validation_errors(errors)
        {:error, formatted_errors}

      {:ok, checked_params} ->
        # Use pre-computed clean schema if available, otherwise strip at runtime
        clean_schema = precomputed_clean || SchemaConverter.strip_markers(full_schema)
        keyword_params = Map.to_list(checked_params)

        case NimbleOptions.validate(keyword_params, clean_schema) do
          {:ok, validated_keyword_params} ->
            # Convert back to map and string keys for consistency
            validated_params = Map.new(validated_keyword_params)
            string_params = convert_keys_to_strings(validated_params)
            {:ok, restore_additional_properties(string_params, params, full_schema)}

          {:error, %NimbleOptions.ValidationError{} = error} ->
            formatted_errors = format_nimble_options_error(error, params)

            if Keyword.get(config, :log_validation_errors, false) do
              Logger.warning("Validation failed for #{context}: #{inspect(formatted_errors)}")
            end

            {:error, formatted_errors}
        end
    end
  end

  # Key normalisation
  #
  # NimbleOptions' nested `keys:` validation is atom-key-only, but JSON-RPC
  # delivers string keys. Top-level keys keep the historical
  # `String.to_existing_atom`-with-string-fallback behaviour; nested object keys
  # are matched against the *declared* field names of that object instead.
  #
  # Two reasons the nested pass is schema-driven rather than a blanket
  # recursion. It never mints an atom from client input — unbounded atom
  # creation is a memory-exhaustion DoS, and declared field names were already
  # interned at compile time by the DSL. And it makes the key type deterministic:
  # the old blanket recursion left a nested key an atom or a string depending on
  # whether it happened to be interned already, which is what made object
  # validation flaky rather than uniformly broken.
  defp normalize_params(params, schema) do
    Map.new(params, fn {key, value} ->
      atom_key = existing_atom(key)
      {atom_key, normalize_value(value, param_opts(schema, atom_key))}
    end)
  end

  defp param_opts(schema, key) when is_atom(key), do: Keyword.get(schema, key, [])
  defp param_opts(_schema, _key), do: []

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp existing_atom(key), do: key

  # Only an object with a declared `keys:` schema is descended into; every other
  # value — open bags, arrays, scalars — passes through untouched.
  defp normalize_value(value, opts) when is_map(value) do
    case Keyword.get(opts, :keys) do
      nil -> value
      nested_schema -> normalize_object(value, nested_schema, additional_properties?(opts))
    end
  end

  defp normalize_value(value, _opts), do: value

  defp normalize_object(map, nested_schema, additional?) do
    declared = declared_names(nested_schema)

    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case declared_key(declared, nested_schema, key) do
        {:ok, name} ->
          Map.put(acc, name, normalize_value(value, Keyword.get(nested_schema, name, [])))

        :error when additional? ->
          # Dropped so NimbleOptions' `keys:` schema doesn't reject it; merged
          # back from the original request by restore_additional_properties/3.
          acc

        :error ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp declared_names(nested_schema) do
    Map.new(nested_schema, fn {name, _opts} -> {Atom.to_string(name), name} end)
  end

  defp declared_key(declared, _nested_schema, key) when is_binary(key) do
    Map.fetch(declared, key)
  end

  defp declared_key(_declared, nested_schema, key) when is_atom(key) do
    if Keyword.has_key?(nested_schema, key), do: {:ok, key}, else: :error
  end

  defp declared_key(_declared, _nested_schema, _key), do: :error

  defp additional_properties?(opts), do: Keyword.get(opts, :additional_properties, false)

  # An object declared `additional_properties: true` had its undeclared keys
  # pruned before validation, so they are merged back from the original request.
  # Declared keys keep the validated value, which carries nested defaults.
  defp restore_additional_properties(validated, original, schema) do
    merge_object(validated, original, schema, [])
  end

  defp merge_object(validated, original, schema, opts) do
    merged =
      if additional_properties?(opts) do
        Map.merge(convert_keys_to_strings(original), validated)
      else
        validated
      end

    Enum.reduce(schema, merged, fn {name, field_opts}, acc ->
      case Keyword.get(field_opts, :keys) do
        nil -> acc
        nested_schema -> merge_nested_object(acc, original, name, nested_schema, field_opts)
      end
    end)
  end

  defp merge_nested_object(acc, original, name, nested_schema, field_opts) do
    key = Atom.to_string(name)

    with {:ok, validated_value} when is_map(validated_value) <- Map.fetch(acc, key),
         {:ok, original_value} when is_map(original_value) <- fetch_either(original, key, name) do
      Map.put(
        acc,
        key,
        merge_object(validated_value, original_value, nested_schema, field_opts)
      )
    else
      _ -> acc
    end
  end

  defp fetch_either(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, atom_key)
    end
  end

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

  # Custom constraint validation — single pass over the schema, recursing into
  # declared nested objects.

  defp validate_custom_constraints(params, schema) do
    # Undeclared *top-level* keys are checked here rather than left to
    # NimbleOptions for two reasons. Its message (`unknown options [:zzq]`)
    # carries no machine-readable parameter, so a client got `parameter: nil` at
    # depth 0 and a dotted path at every other depth. And an undeclared key that
    # does not intern stays a binary, which makes `Map.to_list/1` a non-keyword
    # list and raises out of `NimbleOptions.validate/2` — so the same mistake
    # surfaced as a validation error or an internal error depending on whether
    # the atom happened to exist. Same atom-table luck as RC3, one level up.
    errors =
      unknown_key_errors(nil, params, schema, false) ++
        collect_schema_errors(params, schema, nil)

    case errors do
      [] -> {:ok, params}
      errors -> {:error, errors}
    end
  end

  # `path` is the dotted parameter path of the enclosing object, `nil` at the
  # top level. Errors carry it so a nested failure names the field the client
  # actually sent, e.g. `bag.inner.city`.
  defp collect_schema_errors(params, schema, path) do
    Enum.flat_map(schema, fn {name, opts} ->
      case Map.get(params, name) do
        nil -> []
        value -> collect_constraint_errors(join_path(path, name), value, opts)
      end
    end)
  end

  defp join_path(nil, name), do: to_string(name)
  defp join_path(path, name), do: "#{path}.#{name}"

  defp collect_constraint_errors(path, value, opts) do
    own =
      [
        check_enum(path, value, opts),
        check_min_value(path, value, opts),
        check_max_value(path, value, opts),
        check_min_length(path, value, opts),
        check_max_length(path, value, opts),
        check_custom_validator(path, value, opts)
      ]
      |> Enum.flat_map(fn
        :ok -> []
        {:error, error} -> [error]
      end)

    own ++ nested_object_errors(path, value, opts)
  end

  # NimbleOptions' `keys:` schema handles nested structure — required fields,
  # types, depth — but it cannot report an undeclared key usefully (for a string
  # key its message is `expected atom, got: "zzz"`) and it does not know about
  # the custom constraints, so both are handled here.
  defp nested_object_errors(path, value, opts) when is_map(value) do
    case Keyword.get(opts, :keys) do
      nil ->
        []

      nested_schema ->
        unknown_key_errors(path, value, nested_schema, additional_properties?(opts)) ++
          collect_schema_errors(value, nested_schema, path)
    end
  end

  defp nested_object_errors(_path, _value, _opts), do: []

  defp unknown_key_errors(_path, _map, _nested_schema, true), do: []

  defp unknown_key_errors(path, map, nested_schema, false) do
    declared = declared_names(nested_schema)

    for {key, value} <- map, declared_key(declared, nested_schema, key) == :error do
      name = key_to_string(key)

      %{
        parameter: join_path(path, name),
        value: value,
        message: unknown_key_message(name, path)
      }
    end
  end

  defp unknown_key_message(name, nil), do: "unknown parameter #{inspect(name)}"

  defp unknown_key_message(name, path),
    do: "unknown field #{inspect(name)} in object #{inspect(path)}"

  # `declared_key/3` tolerates any key term, so this must too. Reachable through
  # the public `validate_tool_params/3`, though not over JSON-RPC, where object
  # keys are always strings.
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: inspect(key)

  defp check_enum(param_name, value, opts) do
    enum_values = Keyword.get(opts, :__enum_values__) || Keyword.get(opts, :enum)

    case enum_values do
      nil ->
        :ok

      enum_values ->
        if value in enum_values do
          :ok
        else
          {:error,
           %{
             parameter: to_string(param_name),
             value: value,
             message: "must be one of #{inspect(enum_values)}"
           }}
        end
    end
  end

  defp check_min_value(param_name, value, opts) do
    min_val = Keyword.get(opts, :__min_value__) || Keyword.get(opts, :min)

    case min_val do
      nil ->
        :ok

      min_val when is_number(value) and value >= min_val ->
        :ok

      min_val when is_number(value) ->
        {:error,
         %{
           parameter: to_string(param_name),
           value: value,
           message: "must be greater than or equal to #{min_val}"
         }}

      _ ->
        :ok
    end
  end

  defp check_max_value(param_name, value, opts) do
    max_val = Keyword.get(opts, :__max_value__) || Keyword.get(opts, :max)

    case max_val do
      nil ->
        :ok

      max_val when is_number(value) and value <= max_val ->
        :ok

      max_val when is_number(value) ->
        {:error,
         %{
           parameter: to_string(param_name),
           value: value,
           message: "must be less than or equal to #{max_val}"
         }}

      _ ->
        :ok
    end
  end

  defp check_min_length(param_name, value, opts) do
    min_len = Keyword.get(opts, :__min_length__) || Keyword.get(opts, :min_length)

    cond do
      min_len == nil or not is_binary(value) ->
        :ok

      # String.length/1 counts graphemes — "characters" as users understand
      # them — unlike byte_size/1, which over-counts multi-byte UTF-8.
      String.length(value) >= min_len ->
        :ok

      true ->
        {:error,
         %{
           parameter: to_string(param_name),
           value: value,
           message: "must be at least #{min_len} characters long"
         }}
    end
  end

  defp check_max_length(param_name, value, opts) do
    max_len = Keyword.get(opts, :__max_length__) || Keyword.get(opts, :max_length)

    cond do
      max_len == nil or not is_binary(value) ->
        :ok

      String.length(value) <= max_len ->
        :ok

      true ->
        {:error,
         %{
           parameter: to_string(param_name),
           value: value,
           message: "must be no more than #{max_len} characters long"
         }}
    end
  end

  defp check_custom_validator(param_name, value, opts) do
    case Keyword.get(opts, :validator) do
      nil ->
        :ok

      validator when is_function(validator, 1) ->
        try do
          if validator.(value) do
            :ok
          else
            {:error,
             %{
               parameter: to_string(param_name),
               value: value,
               message: "failed custom validation"
             }}
          end
        rescue
          _ ->
            {:error,
             %{
               parameter: to_string(param_name),
               value: value,
               message: "validation function error"
             }}
        end
    end
  end

  defp apply_type_coercion(params, schema) do
    # Build a map for O(1) lookup instead of O(n) Enum.find per param
    schema_map = Map.new(schema)

    Map.new(params, fn {param_name, value} ->
      case Map.get(schema_map, param_name) do
        nil ->
          {param_name, value}

        param_opts ->
          {param_name, coerce_param(value, param_opts)}
      end
    end)
  end

  # A declared object's fields are validated for type, so they have to be
  # coerced for type too — otherwise `%{"age" => "30"}` is accepted at the top
  # level and the identical `%{"bag" => %{"age" => "30"}}` is rejected.
  defp coerce_param(value, param_opts) when is_map(value) do
    case Keyword.get(param_opts, :keys) do
      nil -> coerce_value(value, Keyword.get(param_opts, :type))
      nested_schema -> apply_type_coercion(value, nested_schema)
    end
  end

  defp coerce_param(value, param_opts) do
    coerce_value(value, Keyword.get(param_opts, :type))
  end

  defp coerce_value(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {int_val, ""} -> int_val
      # Can't coerce, keep original
      _ -> value
    end
  end

  defp coerce_value(value, :float) when is_binary(value) do
    case Float.parse(value) do
      {float_val, ""} -> float_val
      # Can't coerce, keep original
      _ -> value
    end
  end

  defp coerce_value(value, :boolean) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      "1" -> true
      "0" -> false
      # Can't coerce, keep original
      _ -> value
    end
  end

  # No coercion needed or supported
  defp coerce_value(value, _type), do: value
end

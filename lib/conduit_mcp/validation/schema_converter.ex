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
  - `:object` -> `{:map, :any, :any}` for an open object (no declared fields);
    `:map` with a nested `keys:` schema when nested fields are declared
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

  ## Nested Objects

  An `:object` param that declares nested fields is converted to
  `type: :map, keys: [...]`, built by recursing through this same function, so
  nesting works to any depth and NimbleOptions reports errors with a key path
  (`in options [:bag, :inner]`).

  Undeclared keys in such an object are rejected unless the param carries
  `additional_properties: true`. An object with no declared fields is an open
  bag: `{:map, :any, :any}`, anything accepted.

  Nested keys arrive as strings over JSON-RPC and NimbleOptions' nested
  validation is atom-key-only, so `ConduitMcp.Validation` atomises nested keys
  before validating — but only those matching a *declared* field name, which
  are already interned at compile time. Client input never mints an atom.

  ### Enforcement boundary

  Nested validation covers `:object` params and objects nested inside them.
  It does **not** cover objects inside `:array` items: NimbleOptions has no
  way to attach a `keys:` schema to a list element type. Item schemas declared
  with `items :object do ... end` are published in the JSON Schema for clients
  but are not enforced server-side beyond `{:list, :any}`.

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

  defp convert_param_to_nimble_option(%{name: name, type: type, opts: opts} = param) do
    {name, type_opts(type, param) ++ extract_validation_opts(opts)}
  end

  # `additional_properties: false` on an object with *no* declared fields is a
  # deliberate "empty object only" contract, so it takes the `keys:` path with
  # an empty declared list rather than degrading to an open bag.
  defp type_opts(:object, param) do
    nested = Map.get(param, :nested) || []
    additional = Keyword.get(Map.get(param, :opts) || [], :additional_properties)

    if nested == [] and additional != false do
      [type: {:map, :any, :any}]
    else
      [type: :map, keys: dsl_params_to_nimble_options(nested)]
    end
  end

  defp type_opts(type, _param), do: [type: convert_type(type)]

  defp convert_type(:string), do: :string
  defp convert_type(:integer), do: :integer
  # NimbleOptions uses :float, not :number
  defp convert_type(:number), do: :float
  defp convert_type(:boolean), do: :boolean
  # `:map` is shorthand for `{:map, :atom, :any}`, which rejects string keys —
  # and a JSON object's keys are strings. `{:map, :string, :any}` is not the
  # answer either: nested keys matching a declared field name are atomised
  # before validation, so a real payload carries both key types.
  defp convert_type(:object), do: {:map, :any, :any}
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

  defp convert_validation_opt({:validator, {module, function}}, acc)
       when is_atom(module) and is_atom(function) do
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

  # Selects between strict and pass-through semantics for an object's
  # undeclared keys. Consumed by `ConduitMcp.Validation`, stripped before the
  # schema reaches NimbleOptions.
  defp convert_validation_opt({:additional_properties, value}, acc) when is_boolean(value) do
    [{:additional_properties, value} | acc]
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
    # Remove custom constraint markers before validating with NimbleOptions
    clean_schema = strip_markers(schema)

    # Test the schema with empty options to validate its structure
    NimbleOptions.validate([], clean_schema)
    :ok
  rescue
    # A bad schema definition surfaces as a raise, not a return value — an
    # empty-options run always reports the missing required options. Narrow to
    # the classes NimbleOptions raises for that, so a bug in our own conversion
    # (e.g. a FunctionClauseError in `strip_markers/1`) crashes loudly instead of
    # being reported to the developer as "your schema is invalid".
    error in [ArgumentError, NimbleOptions.ValidationError] ->
      {:error, Exception.message(error)}
  end

  @custom_constraint_markers [
    :__enum_values__,
    :__min_value__,
    :__max_value__,
    :__min_length__,
    :__max_length__,
    :validator,
    :min,
    :max,
    :min_length,
    :max_length,
    :enum,
    :additional_properties
  ]

  @doc """
  Strips custom constraint markers from a schema, recursing through nested
  `keys:` schemas.

  The markers carry constraints NimbleOptions has no native option for
  (`enum`, `min`/`max`, length limits, custom validators) plus the
  `additional_properties` knob. They ride alongside the real options in the
  *full* schema and must be removed before it reaches NimbleOptions, which
  rejects unknown option keys — including inside a nested `keys:` schema.

  Single source of truth. Used by `ConduitMcp.Validation`,
  `ConduitMcp.DSL.SchemaBuilder`, and `ConduitMcp.Endpoint`.
  """
  def strip_markers(schema) when is_list(schema) do
    Enum.map(schema, fn {param_name, param_opts} ->
      {param_name, strip_param_markers(param_opts)}
    end)
  end

  # Components may have no schema at all. Anything else non-list is a bug in the
  # caller, and silently yielding `[]` on the *runtime* path would mean handing a
  # tool a schema that declares nothing.
  def strip_markers(nil), do: []

  defp strip_param_markers(param_opts) do
    param_opts
    |> Keyword.drop(@custom_constraint_markers)
    |> Keyword.replace_lazy(:keys, &strip_markers/1)
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
      {:ok, detailed_errors} ->
        detailed_errors

      {:error, _} ->
        # Fallback to generic error
        [
          %{
            parameter: nil,
            value: nil,
            message: message
          }
        ]
    end
  end

  # Private helper functions for error parsing

  # NimbleOptions' message embeds the offending value verbatim via `inspect/1`,
  # so a client-supplied string can contain anything this parser looks for.
  # Every pattern below is therefore anchored to the message's own structure:
  # the reason is always the prefix, and the key path is always the suffix.
  # Matching anywhere in the message let a client forge a wholly fabricated
  # error (and suppress the real one) by sending its text as a parameter value.
  defp parse_validation_error(message, original_params) do
    cond do
      String.starts_with?(message, "required :") ->
        parse_required_error(message, original_params)

      String.starts_with?(message, "invalid value for :") ->
        parse_invalid_value_error(message)

      true ->
        {:error, :unparseable}
    end
  end

  defp parse_required_error(message, _original_params) do
    # NimbleOptions format: "required :name option not found, received options: [...]"
    case Regex.run(~r/^required :(\w+) option not found/, message) do
      [_, field_name] ->
        {:ok,
         [
           %{
             parameter: qualify_with_key_path(field_name, message),
             value: nil,
             message: "is required"
           }
         ]}

      nil ->
        {:error, :no_field_found}
    end
  end

  # For a nested schema NimbleOptions appends the enclosing key path, e.g.
  # `(in options [:bag, :inner])`. Fold it into the parameter name so a nested
  # failure names the field the client actually sent (`bag.inner.city`) rather
  # than an ambiguous bare `city`. Anchored to the end of the message: the
  # genuine path is always last, so an unanchored match would prefer a forged
  # one embedded in a client-supplied value.
  defp qualify_with_key_path(field_name, message) do
    case Regex.run(~r/\(in options \[([^\]]+)\]\)$/, message) do
      [_, path] ->
        path
        |> String.split(",")
        |> Enum.map_join(".", &String.trim_leading(String.trim(&1), ":"))
        |> Kernel.<>("." <> field_name)

      nil ->
        field_name
    end
  end

  # NimbleOptions format: "invalid value for :name option: expected string, got: 1"
  # optionally followed by the key path. Anchored at the start for the same
  # reason as above — the reason is structural, anything later in the message may
  # be client-supplied.
  defp parse_invalid_value_error(message) do
    case Regex.run(~r/^invalid value for :(\w+) option: /, message) do
      [prefix, field_name] ->
        reason =
          message
          |> String.replace_prefix(prefix, "")
          |> String.replace(~r/ \(in options \[[^\]]+\]\)$/, "")

        {:ok,
         [
           %{
             parameter: qualify_with_key_path(field_name, message),
             value: nil,
             message: reason
           }
         ]}

      nil ->
        {:error, :no_field_found}
    end
  end
end

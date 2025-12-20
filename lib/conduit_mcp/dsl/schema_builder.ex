defmodule ConduitMcp.DSL.SchemaBuilder do
  @moduledoc """
  Builds JSON Schema and NimbleOptions schemas from DSL parameter definitions.

  This module converts the accumulated parameter definitions from the DSL
  into both JSON Schema format (for MCP client validation) and NimbleOptions
  schemas (for runtime server-side validation).

  ## Dual Schema Generation

  The module now generates two types of schemas:

  1. **JSON Schema** - Used by MCP clients for input validation and introspection
  2. **NimbleOptions Schema** - Used for runtime server-side parameter validation

  Both schemas are generated from the same DSL parameter definitions but serve
  different purposes in the validation pipeline.
  """

  alias ConduitMcp.Validation.SchemaConverter

  @doc """
  Builds a complete tool schema from DSL definition.

  ## Example

      iex> tool_def = %{
      ...>   name: "greet",
      ...>   description: "Greets someone",
      ...>   params: [
      ...>     %{name: :name, type: :string, description: "Name", opts: [required: true]},
      ...>     %{name: :age, type: :number, description: "Age", opts: []}
      ...>   ],
      ...>   handler: {:fn, fn _conn, p -> {:ok, p} end}
      ...> }
      iex> ConduitMcp.DSL.SchemaBuilder.build_tool_schema(tool_def)
      %{
        "name" => "greet",
        "description" => "Greets someone",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Name"},
            "age" => %{"type" => "number", "description" => "Age"}
          },
          "required" => ["name"]
        }
      }
  """
  def build_tool_schema(%{name: name, description: description, params: params}) do
    %{
      "name" => to_string(name),
      "description" => description,
      "inputSchema" => build_input_schema(params)
    }
  end

  @doc """
  Builds a JSON Schema input schema from parameter definitions.
  """
  def build_input_schema(params) when is_list(params) do
    {properties, required} = build_properties_and_required(params)

    schema = %{
      "type" => "object",
      "properties" => properties
    }

    if required != [] do
      Map.put(schema, "required", required)
    else
      schema
    end
  end

  @doc """
  Builds a prompt schema from DSL definition.
  """
  def build_prompt_schema(%{name: name, description: description, args: args}) do
    schema = %{
      "name" => to_string(name),
      "description" => description
    }

    # Add arguments if present
    if args != [] do
      Map.put(schema, "arguments", build_prompt_arguments(args))
    else
      schema
    end
  end

  @doc """
  Builds a resource schema from DSL definition.
  """
  def build_resource_schema(%{uri: uri, description: description, mime_type: mime_type}) do
    schema = %{
      "uri" => uri
    }

    schema = if description, do: Map.put(schema, "description", description), else: schema
    schema = if mime_type, do: Map.put(schema, "mimeType", mime_type), else: schema

    schema
  end

  # Private helpers

  defp build_properties_and_required(params) do
    Enum.reduce(params, {%{}, []}, fn param, {props, required} ->
      param_name = to_string(param.name)
      property = build_property(param)

      new_props = Map.put(props, param_name, property)

      new_required =
        if Keyword.get(param.opts, :required, false) do
          [param_name | required]
        else
          required
        end

      {new_props, new_required}
    end)
    |> then(fn {props, required} -> {props, Enum.reverse(required)} end)
  end

  defp build_property(%{type: :object, nested: nested_params} = param) do
    base = %{"type" => "object"}

    base = add_description(base, param)
    base = add_enum(base, param)

    # Build nested properties
    {nested_props, nested_required} = build_properties_and_required(nested_params)

    base = Map.put(base, "properties", nested_props)

    if nested_required != [] do
      Map.put(base, "required", nested_required)
    else
      base
    end
  end

  defp build_property(%{type: :array, items: items_def} = param) do
    base = %{"type" => "array"}

    base = add_description(base, param)

    # Build items schema
    items_schema = build_items_schema(items_def)
    Map.put(base, "items", items_schema)
  end

  defp build_property(param) do
    type_str = atom_to_json_type(param.type)

    base = %{"type" => type_str}
    base = add_description(base, param)
    base = add_enum(base, param)
    base = add_default(base, param)

    base
  end

  defp build_items_schema(%{type: :object, nested: nested_params}) do
    {nested_props, nested_required} = build_properties_and_required(nested_params)

    schema = %{
      "type" => "object",
      "properties" => nested_props
    }

    if nested_required != [] do
      Map.put(schema, "required", nested_required)
    else
      schema
    end
  end

  defp build_items_schema(%{type: type}) do
    %{"type" => atom_to_json_type(type)}
  end

  defp build_prompt_arguments(args) do
    Enum.reduce(args, [], fn arg, acc ->
      arg_def = %{
        "name" => to_string(arg.name),
        "description" => arg.description || "",
        "required" => Keyword.get(arg.opts, :required, false)
      }

      [arg_def | acc]
    end)
    |> Enum.reverse()
  end

  defp add_description(schema, %{description: nil}), do: schema
  defp add_description(schema, %{description: desc}), do: Map.put(schema, "description", desc)

  defp add_enum(schema, param) do
    case Keyword.get(param.opts, :enum) do
      nil -> schema
      enum_values when is_list(enum_values) -> Map.put(schema, "enum", enum_values)
    end
  end

  defp add_default(schema, param) do
    case Keyword.get(param.opts, :default) do
      nil -> schema
      default_value -> Map.put(schema, "default", default_value)
    end
  end

  defp atom_to_json_type(:string), do: "string"
  defp atom_to_json_type(:number), do: "number"
  defp atom_to_json_type(:integer), do: "integer"
  defp atom_to_json_type(:boolean), do: "boolean"
  defp atom_to_json_type(:object), do: "object"
  defp atom_to_json_type(:array), do: "array"
  defp atom_to_json_type(:null), do: "null"
  defp atom_to_json_type(other), do: to_string(other)

  # ======= DUAL SCHEMA GENERATION =======

  @doc """
  Builds both JSON Schema and NimbleOptions validation schema from tool definition.

  Returns a map containing both schema types for comprehensive validation.

  ## Examples

      iex> tool_def = %{name: "greet", params: [...]}
      iex> ConduitMcp.DSL.SchemaBuilder.build_dual_schemas(tool_def)
      %{
        json_schema: %{"name" => "greet", "inputSchema" => %{...}},
        nimble_options_schema: [name: [type: :string, required: true], ...]
      }

  """
  def build_dual_schemas(tool_def) do
    %{
      json_schema: build_tool_schema(tool_def),
      nimble_options_schema: build_nimble_options_schema(tool_def)
    }
  end

  @doc """
  Builds dual schemas for prompt definitions.
  """
  def build_dual_prompt_schemas(prompt_def) do
    %{
      json_schema: build_prompt_schema(prompt_def),
      nimble_options_schema: build_nimble_options_prompt_schema(prompt_def)
    }
  end

  @doc """
  Builds a NimbleOptions validation schema from tool definition.

  Converts DSL parameter definitions into a NimbleOptions schema format
  that can be used for runtime parameter validation with type coercion
  and advanced constraints.

  ## Examples

      iex> tool_def = %{
      ...>   name: "calculate",
      ...>   params: [
      ...>     %{name: :a, type: :integer, opts: [required: true, min: 0]},
      ...>     %{name: :b, type: :integer, opts: [required: true, min: 0]}
      ...>   ]
      ...> }
      iex> ConduitMcp.DSL.SchemaBuilder.build_nimble_options_schema(tool_def)
      [
        a: [type: :integer, required: true, min: 0],
        b: [type: :integer, required: true, min: 0]
      ]

  """
  def build_nimble_options_schema(%{params: params}) do
    SchemaConverter.dsl_params_to_nimble_options(params)
  end

  @doc """
  Builds a NimbleOptions validation schema for prompt arguments.
  """
  def build_nimble_options_prompt_schema(%{args: args}) do
    SchemaConverter.dsl_params_to_nimble_options(args)
  end

  @doc """
  Validates that a NimbleOptions schema is properly formed.

  This is used during compile time to ensure the generated schema
  is valid for NimbleOptions validation.
  """
  def validate_nimble_options_schema(schema) do
    SchemaConverter.validate_schema(schema)
  end

  @doc """
  Compiles validation schemas for all tools in a server module.

  This function is used during the `@before_compile` hook to generate
  validation schemas for all tools defined in the DSL.

  ## Examples

      iex> tools = [
      ...>   %{name: "greet", params: [...]},
      ...>   %{name: "calc", params: [...]}
      ...> ]
      iex> ConduitMcp.DSL.SchemaBuilder.compile_tool_validation_schemas(tools)
      %{
        "greet" => [name: [type: :string, required: true], ...],
        "calc" => [a: [type: :integer, min: 0], ...]
      }

  """
  def compile_tool_validation_schemas(tools) when is_list(tools) do
    Enum.reduce(tools, %{}, fn tool, acc ->
      tool_name = to_string(tool.name)
      validation_schema = build_nimble_options_schema(tool)
      Map.put(acc, tool_name, validation_schema)
    end)
  end

  @doc """
  Compiles validation schemas for all prompts in a server module.
  """
  def compile_prompt_validation_schemas(prompts) when is_list(prompts) do
    Enum.reduce(prompts, %{}, fn prompt, acc ->
      prompt_name = to_string(prompt.name)
      validation_schema = build_nimble_options_prompt_schema(prompt)
      Map.put(acc, prompt_name, validation_schema)
    end)
  end

  @doc """
  Generates compile-time validation schema lookup functions.

  This creates the AST for functions that will be injected into the
  server module to provide fast schema lookups at runtime.

  Returns quoted AST that defines:
  - `__validation_schema_for_tool__/1`
  - `__validation_schema_for_prompt__/1`
  """
  def generate_validation_lookup_functions(tools, prompts) do
    tool_schemas = compile_tool_validation_schemas(tools)
    prompt_schemas = compile_prompt_validation_schemas(prompts)

    quote do
      @doc false
      def __validation_schema_for_tool__(tool_name) do
        case unquote(Macro.escape(tool_schemas)) do
          %{^tool_name => schema} -> schema
          _ -> nil
        end
      end

      @doc false
      def __validation_schema_for_prompt__(prompt_name) do
        case unquote(Macro.escape(prompt_schemas)) do
          %{^prompt_name => schema} -> schema
          _ -> nil
        end
      end

      @doc false
      def __all_validation_schemas__ do
        %{
          tools: unquote(Macro.escape(tool_schemas)),
          prompts: unquote(Macro.escape(prompt_schemas))
        }
      end
    end
  end

  @doc """
  Validates all schemas in a tool/prompt definition list.

  Used during compile time to catch schema generation errors early.
  Returns `:ok` if all schemas are valid, or `{:error, details}` if any are invalid.
  """
  def validate_all_schemas(tools, prompts) do
    tool_results = Enum.map(tools, &validate_tool_schema/1)
    prompt_results = Enum.map(prompts, &validate_prompt_schema/1)

    all_results = tool_results ++ prompt_results
    errors = Enum.filter(all_results, fn result -> elem(result, 0) == :error end)

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  # Private helpers for schema validation

  defp validate_tool_schema(tool) do
    try do
      nimble_schema = build_nimble_options_schema(tool)
      case validate_nimble_options_schema(nimble_schema) do
        :ok -> {:ok, tool.name}
        {:error, reason} -> {:error, {tool.name, reason}}
      end
    rescue
      error -> {:error, {tool.name, Exception.message(error)}}
    end
  end

  defp validate_prompt_schema(prompt) do
    try do
      nimble_schema = build_nimble_options_prompt_schema(prompt)
      case validate_nimble_options_schema(nimble_schema) do
        :ok -> {:ok, prompt.name}
        {:error, reason} -> {:error, {prompt.name, reason}}
      end
    rescue
      error -> {:error, {prompt.name, Exception.message(error)}}
    end
  end
end

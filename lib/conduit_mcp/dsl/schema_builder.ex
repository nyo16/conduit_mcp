defmodule ConduitMcp.DSL.SchemaBuilder do
  @moduledoc """
  Builds JSON Schema from DSL parameter definitions.

  This module converts the accumulated parameter definitions from the DSL
  into proper JSON Schema format for MCP tool input schemas.
  """

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
end

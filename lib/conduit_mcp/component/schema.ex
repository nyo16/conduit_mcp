defmodule ConduitMcp.Component.Schema do
  @moduledoc """
  Schema DSL for defining parameters in Component modules.

  Provides a simple `schema do ... end` block with `field` declarations
  that generate both JSON Schema (for MCP client introspection) and
  NimbleOptions schemas (for server-side runtime validation).

  ## Example

      defmodule MyApp.Echo do
        use ConduitMcp.Component, type: :tool, description: "Echoes text"

        schema do
          field :text, :string, "The text to echo", required: true, max_length: 150
          field :count, :integer, "Repeat count", default: 1, min: 1, max: 10
        end

        @impl true
        def execute(%{text: text, count: count}, _conn) do
          text(String.duplicate(text, count))
        end
      end

  ## Supported Types

  - `:string` — String values
  - `:integer` — Integer values
  - `:number` — Numeric values (float)
  - `:boolean` — Boolean values
  - `:object` — Nested objects (use block form with nested `field` calls)
  - `:array` / `{:array, item_type}` — Arrays

  ## Field Options

  - `required: true` — Mark as required (default: false)
  - `default: value` — Default value
  - `enum: [...]` — Allowed values
  - `min: n` / `max: n` — Numeric constraints
  - `min_length: n` / `max_length: n` — String length constraints
  - `validator: fn` — Custom validator function
  """

  @doc """
  Defines the parameter schema for a component.

  Wraps `field` declarations and accumulates them into `@component_fields`.
  """
  defmacro schema(do: block) do
    quote do
      Module.put_attribute(__MODULE__, :component_fields, [])
      unquote(block)

      Module.put_attribute(
        __MODULE__,
        :component_fields,
        Enum.reverse(Module.get_attribute(__MODULE__, :component_fields))
      )
    end
  end

  @doc """
  Defines a field in the component schema.

  ## Examples

      # Simple field
      field :name, :string, "User's name", required: true

      # Field with options
      field :age, :integer, "User's age", min: 0, max: 150

      # Field without description (uses opts keyword)
      field :tags, {:array, :string}, "Tag list"

      # Nested object field
      field :address, :object, "Mailing address", required: true do
        field :street, :string, "Street", required: true
        field :city, :string, "City", required: true
      end
  """
  defmacro field(name, type, description, opts \\ [], do_block \\ nil)

  defmacro field(name, :object, description, opts, do: nested_block) do
    quote do
      Module.put_attribute(__MODULE__, :__component_nested_fields, [])

      unquote(nested_block)

      field_def = %{
        name: unquote(name),
        type: :object,
        description: unquote(description),
        opts: unquote(opts),
        nested: Enum.reverse(Module.get_attribute(__MODULE__, :__component_nested_fields)),
        items: nil
      }

      current = Module.get_attribute(__MODULE__, :component_fields) || []
      Module.put_attribute(__MODULE__, :component_fields, [field_def | current])

      Module.delete_attribute(__MODULE__, :__component_nested_fields)
    end
  end

  defmacro field(name, :array, description, opts, do: nested_block) do
    quote do
      Module.put_attribute(__MODULE__, :__component_array_items, nil)

      unquote(nested_block)

      field_def = %{
        name: unquote(name),
        type: :array,
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: Module.get_attribute(__MODULE__, :__component_array_items)
      }

      current = Module.get_attribute(__MODULE__, :component_fields) || []
      Module.put_attribute(__MODULE__, :component_fields, [field_def | current])

      Module.delete_attribute(__MODULE__, :__component_array_items)
    end
  end

  defmacro field(name, type, description, opts, nil) do
    quote do
      field_def = %{
        name: unquote(name),
        type: unquote(type),
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: nil
      }

      # Accumulate into the right attribute depending on nesting context
      if Module.has_attribute?(__MODULE__, :__component_nested_fields) do
        current = Module.get_attribute(__MODULE__, :__component_nested_fields) || []
        Module.put_attribute(__MODULE__, :__component_nested_fields, [field_def | current])
      else
        current = Module.get_attribute(__MODULE__, :component_fields) || []
        Module.put_attribute(__MODULE__, :component_fields, [field_def | current])
      end
    end
  end
end

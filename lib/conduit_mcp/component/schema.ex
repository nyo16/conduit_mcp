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
  - `:object` — Nested objects (block form with nested `field` calls; the
    blockless form declares an open object with no constrained keys)
  - `:array` / `{:array, item_type}` — Arrays. Use the block form with
    `items/1,2` to constrain the item type

  ## Field Options

  - `required: true` — Mark as required (default: false)
  - `default: value` — Default value
  - `enum: [...]` — Allowed values
  - `min: n` / `max: n` — Numeric constraints
  - `min_length: n` / `max_length: n` — String length constraints
  - `validator: fn` — Custom validator function
  - `additional_properties: bool` — For `:object`: whether keys the block did
    not declare are accepted. Defaults to `false` when the field declares
    nested fields and `true` when it does not, and drives
    `"additionalProperties"` in the generated JSON Schema so the published
    schema matches what is enforced.

  ## Nested Objects and Array Items

  Nested fields are enforced at runtime to any depth — required, types, and
  every option above — and undeclared keys are rejected. Array item schemas are
  published for clients but not enforced server-side; see
  `ConduitMcp.Validation.SchemaConverter` for why.

  Handlers receive string keys at every depth below the top level.
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

      # Open object field — any keys accepted
      field :metadata, :object, "Arbitrary metadata"

      # Array of objects
      field :rows, :array, "Rows" do
        items :object do
          field :id, :integer, "Row id", required: true
        end
      end
  """
  defmacro field(name, type, description, opts \\ [], do_block \\ nil)

  # Elixir appends a `do` block as a trailing `[do: ...]` keyword list rather
  # than filling the explicit `do_block` argument, so `field :bag, :object do
  # ... end` and `field :bag, :object, "desc" do ... end` arrive with the block
  # sitting in the `description`/`opts` position and `do_block` still `nil`.
  # Without these two clauses they bind to the blockless clause below, which
  # evaluates the block into `:description`/`:opts` and drops the nested fields.
  defmacro field(name, type, [{:do, nested_block}], [], nil) do
    build_block_field(name, type, nil, [], nested_block, __CALLER__)
  end

  defmacro field(name, type, description, [{:do, nested_block}], nil) do
    build_block_field(name, type, description, [], nested_block, __CALLER__)
  end

  defmacro field(name, type, description, opts, do: nested_block) do
    build_block_field(name, type, description, opts, nested_block, __CALLER__)
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

      ConduitMcp.Component.Schema.__push_field__(__MODULE__, field_def, __ENV__)
    end
  end

  @doc """
  Declares the item type of the enclosing `:array` field.

  ## Examples

      field :tags, :array, "Tags" do
        items :string
      end

      field :users, :array, "Users" do
        items :object do
          field :name, :string, "Name", required: true
        end
      end
  """
  defmacro items(type) when is_atom(type) do
    quote do
      ConduitMcp.Component.Schema.__assert_in_array_block__(:items, __MODULE__, __ENV__)

      Module.put_attribute(__MODULE__, :__component_array_items, %{
        type: unquote(type),
        nested: nil
      })
    end
  end

  defmacro items(type, do: nested_block) do
    build_items(type, nested_block, __CALLER__)
  end

  # Block bodies, shared by the explicit block form and the re-dispatched
  # trailing-`[do: ...]` forms above.

  defp build_block_field(name, :object, description, opts, nested_block, _caller) do
    quote do
      parent_nested = ConduitMcp.Component.Schema.__open_nested_scope__(__MODULE__)

      unquote(nested_block)

      nested_fields =
        ConduitMcp.Component.Schema.__close_nested_scope__(__MODULE__, parent_nested)

      field_def = %{
        name: unquote(name),
        type: :object,
        description: unquote(description),
        opts: unquote(opts),
        nested: nested_fields,
        items: nil
      }

      ConduitMcp.Component.Schema.__push_field__(__MODULE__, field_def, __ENV__)
    end
  end

  defp build_block_field(name, :array, description, opts, nested_block, _caller) do
    quote do
      Module.put_attribute(__MODULE__, :__component_array_items, nil)

      unquote(nested_block)

      items = Module.get_attribute(__MODULE__, :__component_array_items)
      Module.delete_attribute(__MODULE__, :__component_array_items)

      field_def = %{
        name: unquote(name),
        type: :array,
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: items
      }

      ConduitMcp.Component.Schema.__push_field__(__MODULE__, field_def, __ENV__)
    end
  end

  defp build_block_field(name, type, _description, _opts, _nested_block, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "field #{Macro.to_string(name)}: the block form is only supported for " <>
          ":object and :array fields, got: #{Macro.to_string(type)}"
  end

  defp build_items(:object, nested_block, _caller) do
    quote do
      ConduitMcp.Component.Schema.__assert_in_array_block__(:items, __MODULE__, __ENV__)

      parent_nested = ConduitMcp.Component.Schema.__open_nested_scope__(__MODULE__)

      unquote(nested_block)

      nested_fields =
        ConduitMcp.Component.Schema.__close_nested_scope__(__MODULE__, parent_nested)

      Module.put_attribute(__MODULE__, :__component_array_items, %{
        type: :object,
        nested: nested_fields
      })
    end
  end

  defp build_items(type, _nested_block, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "items: the block form is only supported for :object items, " <>
          "got: #{Macro.to_string(type)}"
  end

  # Compile-time accumulator plumbing. These run while the *using* module is
  # being compiled; they are public only so the generated code can call them.

  @doc false
  # Starts a fresh nested-field scope and returns the enclosing one (`nil` when
  # there is none) so it can be restored by `__close_nested_scope__/2`.
  # Without the save/restore an object nested inside another object would wipe
  # its parent's accumulated fields.
  def __open_nested_scope__(module) do
    parent = Module.get_attribute(module, :__component_nested_fields)
    Module.put_attribute(module, :__component_nested_fields, [])
    parent
  end

  @doc false
  def __close_nested_scope__(module, parent_nested) do
    nested = Module.get_attribute(module, :__component_nested_fields) || []

    if parent_nested do
      Module.put_attribute(module, :__component_nested_fields, parent_nested)
    else
      Module.delete_attribute(module, :__component_nested_fields)
    end

    Enum.reverse(nested)
  end

  @doc false
  # Single choke point for every field declaration: routes into the innermost
  # open scope. An `:array` block accumulates its item type through `items`, so
  # a bare `field` there is a mistake — it used to leak into the parent's field
  # list and silently corrupt it.
  def __push_field__(module, field_def, env) do
    cond do
      Module.has_attribute?(module, :__component_nested_fields) ->
        prepend_attribute(module, :__component_nested_fields, field_def)

      Module.has_attribute?(module, :__component_array_items) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "field #{inspect(field_def.name)}: an :array field block declares its item " <>
              "type with `items`, not `field` — use `items :object do ... end`"

      true ->
        prepend_attribute(module, :component_fields, field_def)
    end
  end

  @doc false
  def __assert_in_array_block__(macro, module, env) do
    unless Module.has_attribute?(module, :__component_array_items) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{macro} is only valid inside an :array field block"
    end

    :ok
  end

  defp prepend_attribute(module, attribute, value) do
    current = Module.get_attribute(module, attribute) || []
    Module.put_attribute(module, attribute, [value | current])
  end
end

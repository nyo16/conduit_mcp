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

  alias ConduitMcp.DSL.FieldScope

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
    {description, opts} = split_description_opts(description)
    build_block_field(name, type, description, opts, nested_block, __CALLER__)
  end

  defmacro field(name, type, description, opts, do: nested_block) do
    build_block_field(name, type, description, opts, nested_block, __CALLER__)
  end

  defmacro field(name, type, description, opts, nil) do
    assert_no_block!(name, description, opts, __CALLER__)

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

  # `field :bag, :object, required: true do ... end` — description omitted.
  # Elixir collapses the trailing keywords into the `description` argument, so
  # without this the opts were silently dropped and the keyword list landed in
  # `"description"`, which is not JSON-encodable — breaking `tools/list` for the
  # whole endpoint. A description is a string, so a keyword list here is opts.
  defp split_description_opts([]), do: {nil, []}
  defp split_description_opts([{key, _} | _] = opts) when is_atom(key), do: {nil, opts}
  defp split_description_opts(description), do: {description, []}

  # The clauses that route a trailing `[do: ...]` to the block form depend on
  # argument positions that only the default-injecting header produces. Change a
  # default and they quietly stop matching, and a block silently falls through to
  # the blockless clause above — which evaluates it into `:description`/`:opts`,
  # exactly the bug this module was fixed for. Fail loudly instead.
  defp assert_no_block!(name, description, opts, caller) do
    if block?(description) or block?(opts) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "field #{Macro.to_string(name)}: a `do` block reached the blockless clause. " <>
            "This is a bug in ConduitMcp's macro dispatch — please report it."
    end

    :ok
  end

  defp block?([{:do, _} | _]), do: true
  defp block?(_), do: false

  @doc """
  Declares the item type of the enclosing `:array` field.

  Item schemas are published to clients in the JSON Schema but are **not**
  enforced server-side — NimbleOptions cannot attach a nested schema to a list
  element type. Validate item contents in your `execute/2`.

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
      # Hide any enclosing object's field scope for the duration of the block.
      # Without this, a bare `field` inside an `:array` block nested in an
      # `:object` block would find the parent's scope open and silently land
      # there as a sibling of the array (RC6, one level down) instead of being
      # rejected by `__push_field__/3`.
      parent_nested = ConduitMcp.Component.Schema.__hide_nested_scope__(__MODULE__)
      Module.put_attribute(__MODULE__, :__component_array_items, nil)

      unquote(nested_block)

      items = Module.get_attribute(__MODULE__, :__component_array_items)
      Module.delete_attribute(__MODULE__, :__component_array_items)

      # Restore before pushing, so the array field itself lands in the enclosing
      # scope rather than at the top level.
      ConduitMcp.Component.Schema.__restore_nested_scope__(__MODULE__, parent_nested)

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
  # The scope mechanics live in `ConduitMcp.DSL.FieldScope`, shared with
  # `ConduitMcp.DSL` — the two front ends had divergent copies, and the
  # divergence was where the bugs were.

  @nested :__component_nested_fields
  @array_items :__component_array_items

  @doc false
  def __open_nested_scope__(module), do: FieldScope.open(module, @nested)

  @doc false
  def __hide_nested_scope__(module), do: FieldScope.hide(module, @nested)

  @doc false
  def __close_nested_scope__(module, parent), do: FieldScope.close(module, @nested, parent)

  @doc false
  def __restore_nested_scope__(module, parent), do: FieldScope.restore(module, @nested, parent)

  @doc false
  # Single choke point for every field declaration: routes into the innermost
  # open scope. An `:array` block accumulates its item type through `items`, so
  # a bare `field` there is a mistake — it used to leak into the parent's field
  # list and silently corrupt it.
  def __push_field__(module, field_def, env) do
    cond do
      FieldScope.open?(module, @nested) ->
        FieldScope.prepend(module, @nested, field_def)

      FieldScope.open?(module, @array_items) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "field #{inspect(field_def.name)}: an :array field block declares its item " <>
              "type with `items`, not `field` — use `items :object do ... end`"

      true ->
        FieldScope.prepend(module, :component_fields, field_def)
    end
  end

  @doc false
  # An `:array` block hides any enclosing object scope, so "inside an array
  # block" is precisely "array open and no field scope open". The looser
  # `array open` alone also accepted `items` nested inside `items :object do ...
  # end`, where the inner declaration was overwritten and silently vanished.
  def __assert_in_array_block__(macro, module, env) do
    cond do
      not FieldScope.open?(module, @array_items) or FieldScope.open?(module, @nested) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "#{macro} is only valid directly inside an :array field block"

      Module.get_attribute(module, @array_items) != nil ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{macro}: an :array field block declares exactly one item type, " <>
              "and one is already declared here"

      true ->
        :ok
    end
  end
end

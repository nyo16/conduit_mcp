defmodule ConduitMcp.DSL.FieldScope do
  @moduledoc false

  # Shared compile-time scope plumbing for the two DSL front ends.
  #
  # Both `ConduitMcp.DSL` (`tool ... param ... field`) and
  # `ConduitMcp.Component.Schema` (`schema ... field`) accumulate nested field
  # declarations into a module attribute while the *using* module compiles, and
  # both need the same three operations: open a fresh scope for an object block,
  # hide the enclosing scope for an array block (which collects an item type, not
  # fields), and restore the enclosing scope afterwards.
  #
  # This lived in duplicate before, and the duplicate was where the bugs were:
  # missing save/restore corrupted a parent object's field list at depth >= 2,
  # and a missing hide let a bare `field` inside a nested `:array` block leak
  # into the enclosing object. One implementation, two callers.
  #
  # `nil` means "no enclosing scope"; `[]` means "an enclosing scope that is
  # still empty". The distinction matters — `[]` is truthy in Elixir, so the two
  # must be discriminated by clause, not by an `if`.

  @doc false
  # Opens a fresh scope, returning the enclosing one for `close/3`.
  def open(module, attribute) do
    parent = Module.get_attribute(module, attribute)
    Module.put_attribute(module, attribute, [])
    parent
  end

  @doc false
  # Closes the enclosing scope without opening a new one, so a field declared
  # here has nowhere to land and is rejected rather than silently absorbed.
  def hide(module, attribute) do
    parent = Module.get_attribute(module, attribute)
    Module.delete_attribute(module, attribute)
    parent
  end

  @doc false
  # Returns this scope's fields in declaration order and reinstates the parent.
  def close(module, attribute, parent) do
    fields = Module.get_attribute(module, attribute) || []
    restore(module, attribute, parent)
    Enum.reverse(fields)
  end

  @doc false
  def restore(module, attribute, nil), do: Module.delete_attribute(module, attribute)

  def restore(module, attribute, parent),
    do: Module.put_attribute(module, attribute, parent)

  @doc false
  def open?(module, attribute), do: Module.has_attribute?(module, attribute)

  @doc false
  def prepend(module, attribute, value) do
    current = Module.get_attribute(module, attribute) || []
    Module.put_attribute(module, attribute, [value | current])
  end
end

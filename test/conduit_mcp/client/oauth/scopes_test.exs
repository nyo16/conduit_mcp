defmodule ConduitMcp.Client.OAuth.ScopesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.OAuth.Scopes

  doctest ConduitMcp.Client.OAuth.Scopes

  @resource "https://mcp.example.com/mcp"

  test "parse/1 and join/1" do
    assert Scopes.parse(nil) == []
    assert Scopes.parse("") == []
    assert Scopes.parse(" a  b a ") == ["a", "b"]
    assert Scopes.join([]) == nil
    assert Scopes.join(["a"]) == "a"
  end

  property "union/2 keeps previous first, adds new challenged scopes in order, no duplicates" do
    scope = string(?a..?e, min_length: 1, max_length: 2)

    check all(
            previous <- list_of(scope, max_length: 6),
            challenged <- list_of(scope, max_length: 6)
          ) do
      union = Scopes.union(previous, challenged)

      assert union == Enum.uniq(union)
      assert MapSet.new(union) == MapSet.union(MapSet.new(previous), MapSet.new(challenged))
      assert Enum.take(union, length(Enum.uniq(previous))) == Enum.uniq(previous)

      added = union -- Enum.uniq(previous)
      assert added == challenged |> Enum.uniq() |> Enum.reject(&(&1 in previous))
    end
  end

  test "OA-10: at most 2 step-up attempts per resource and scope set" do
    attempts = %{}
    assert Scopes.step_up_allowed?(attempts, @resource, ["a", "b"])

    attempts = Scopes.record_step_up(attempts, @resource, ["a", "b"])
    assert Scopes.step_up_allowed?(attempts, @resource, ["b", "a"])

    attempts = Scopes.record_step_up(attempts, @resource, ["b", "a", "a"])
    refute Scopes.step_up_allowed?(attempts, @resource, ["a", "b"])

    # A different scope set or resource has its own count.
    assert Scopes.step_up_allowed?(attempts, @resource, ["a", "b", "c"])
    assert Scopes.step_up_allowed?(attempts, "https://other.example.com", ["a", "b"])

    # Configurable limit.
    assert Scopes.step_up_allowed?(attempts, @resource, ["a", "b"], 3)
    refute Scopes.step_up_allowed?(%{}, @resource, ["a"], 0)
  end
end

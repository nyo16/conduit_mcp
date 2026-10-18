defmodule ConduitMcp.Client.OAuth.Scopes do
  @moduledoc """
  Scope lists and step-up bookkeeping.

  Scopes are lists of strings; on the wire they are one space-delimited
  string (RFC 6749 §3.3), see `parse/1` and `join/1`.

  ## Step-up (OA-10)

  When a server answers 403 with `error="insufficient_scope"`, the client
  re-authorizes with `union/2` of the scopes it requested before and the
  challenged ones (MCP 2026-07-28 *Step-Up Authorization Flow*; applied to
  both eras). To stop a server from looping the client through the
  authorization server, attempts are counted per `{resource, scope set}` in a
  plain map the caller keeps (`record_step_up/3`) and checked with
  `step_up_allowed?/4` (default limit 2). The scope set is order- and
  duplicate-insensitive, so `["b", "a"]` and `["a", "b", "a"]` share a count.
  """

  @typedoc "Step-up attempt counts, keyed by `step_up_key/2`."
  @type attempts :: %{optional({String.t(), [String.t()]}) => non_neg_integer()}

  @default_max_step_up 2

  @doc """
  Splits a space-delimited scope string; `nil` gives `[]`. Empty items from
  repeated spaces are dropped and duplicates removed, first occurrence kept.

      iex> ConduitMcp.Client.OAuth.Scopes.parse("read  write read")
      ["read", "write"]
  """
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(scope) when is_binary(scope),
    do: scope |> String.split(" ", trim: true) |> Enum.uniq()

  @doc """
  The `scope` parameter value for `scopes`, or `nil` for an empty list (the
  parameter is then omitted).

      iex> ConduitMcp.Client.OAuth.Scopes.join(["read", "write"])
      "read write"
  """
  @spec join([String.t()]) :: String.t() | nil
  def join([]), do: nil
  def join(scopes) when is_list(scopes), do: Enum.join(scopes, " ")

  @doc """
  `previous` followed by every scope of `challenged` not already present,
  without duplicates: the order of first appearance is kept.

      iex> ConduitMcp.Client.OAuth.Scopes.union(["read", "write"], ["admin", "read"])
      ["read", "write", "admin"]
  """
  @spec union([String.t()], [String.t()]) :: [String.t()]
  def union(previous, challenged) when is_list(previous) and is_list(challenged),
    do: Enum.uniq(previous ++ challenged)

  @doc "The `t:attempts/0` key for `resource` and the set of `scopes`."
  @spec step_up_key(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def step_up_key(resource, scopes) when is_binary(resource) and is_list(scopes),
    do: {resource, scopes |> Enum.uniq() |> Enum.sort()}

  @doc """
  Whether another step-up for `resource` with `scopes` is allowed: fewer than
  `max` (default #{@default_max_step_up}) attempts are recorded in `attempts`.

      iex> alias ConduitMcp.Client.OAuth.Scopes
      iex> attempts = %{} |> Scopes.record_step_up("https://mcp.example.com", ["a"])
      iex> Scopes.step_up_allowed?(attempts, "https://mcp.example.com", ["a"])
      true
      iex> attempts = Scopes.record_step_up(attempts, "https://mcp.example.com", ["a"])
      iex> Scopes.step_up_allowed?(attempts, "https://mcp.example.com", ["a"])
      false
  """
  @spec step_up_allowed?(attempts(), String.t(), [String.t()], non_neg_integer()) :: boolean()
  def step_up_allowed?(attempts, resource, scopes, max \\ @default_max_step_up)
      when is_map(attempts) and is_integer(max) and max >= 0,
      do: Map.get(attempts, step_up_key(resource, scopes), 0) < max

  @doc "Records one step-up attempt for `resource` with `scopes`."
  @spec record_step_up(attempts(), String.t(), [String.t()]) :: attempts()
  def record_step_up(attempts, resource, scopes) when is_map(attempts),
    do: Map.update(attempts, step_up_key(resource, scopes), 1, &(&1 + 1))
end

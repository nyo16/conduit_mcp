defmodule ConduitMcp.Client.ToolCall do
  @moduledoc """
  One intended `tools/call`: which server, which tool, with which arguments.

  This is the value hooks, policy and approvers see. `args_digest` is the
  lower-case hex SHA-256 of the arguments' canonical JSON (object keys sorted
  recursively, atom and string keys treated alike), so an approval can be
  bound to the exact arguments that were shown and a later change to them is
  detectable.

  `meta` is user `_meta` for the request; reserved keys are added (and win)
  when the request is encoded, not here.
  """

  alias ConduitMcp.Client.Canonical

  @enforce_keys [:server_id, :name, :args, :args_digest]
  defstruct [:server_id, :name, :args, :args_digest, meta: %{}]

  @type t :: %__MODULE__{
          server_id: String.t(),
          name: String.t(),
          args: map(),
          meta: map(),
          args_digest: String.t()
        }

  @doc """
  Builds a call and computes its `args_digest`.

  Raises when `args` is not JSON-encodable (including when it contains a
  `ConduitMcp.Client.Secret`).

  ## Options

    * `:meta` - user `_meta` for the request (default `%{}`).

  ## Example

      iex> a = ConduitMcp.Client.ToolCall.new("files", "read", %{"path" => "/a", "n" => 1})
      iex> b = ConduitMcp.Client.ToolCall.new("files", "read", %{n: 1, path: "/a"})
      iex> a.args_digest == b.args_digest
      true
  """
  @spec new(String.t(), String.t(), map(), keyword()) :: t()
  def new(server_id, name, args, opts \\ [])
      when is_binary(server_id) and is_binary(name) and is_map(args) do
    %__MODULE__{
      server_id: server_id,
      name: name,
      args: args,
      meta: Keyword.get(opts, :meta, %{}),
      args_digest: Canonical.sha256(args)
    }
  end

  @doc """
  Replaces the arguments and recomputes the digest (used when a pre-hook
  rewrites them).
  """
  @spec put_args(t(), map()) :: t()
  def put_args(%__MODULE__{} = call, args) when is_map(args),
    do: %{call | args: args, args_digest: Canonical.sha256(args)}
end

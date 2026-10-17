defmodule ConduitMcp.Client.Grants do
  @moduledoc """
  "Always allow" approvals of a `ConduitMcp.Client` (PO-10, PO-11).

  When `ConduitMcp.Client.Policy` decides `:ask` for a call, the client's
  `:on_ask` approver is called (see `ConduitMcp.Client.Pipeline`). An answer
  of `{:allow, :always}` records a grant keyed

      {principal, server_id, tool_name, fingerprint}

  that answers the same question for `:grant_ttl` (default 24 hours)
  without asking again:

    * `principal` is the call's `:principal` option (the end user the host
      acts for; `nil` when not given), so one user's grant never applies to
      another (PO-10). Without principals, grants are per client.
    * `fingerprint` is the tool's `ConduitMcp.Client.Fingerprint` when it
      was approved: a server that changes the tool's definition gets asked
      about again (PO-6).

  A grant only settles an `:ask`. It never overrides a deny rule, and it
  marks the tool's current fingerprint as approved for that principal, so
  the policy's pin (`pin_tools`) and `allow_new_tools` checks treat the
  tool as known.

  Grants live in the client's governance table: `:protected` ETS owned by a
  process under the client's supervisor, read directly by callers and
  written only by that process. They are lost when the client restarts
  (which only means asking again).
  """

  alias ConduitMcp.Client.{Error, Governance}
  alias ConduitMcp.Client.Governance.Owner

  @typedoc "One live grant."
  @type grant :: %{
          principal: term(),
          server_id: String.t(),
          tool: String.t(),
          fingerprint: String.t(),
          expires_at: integer()
        }

  @doc """
  The client's unexpired grants. `expires_at` is Unix time in milliseconds
  (from the client's `:clock`).
  """
  @spec list(term()) :: {:ok, [grant()]} | {:error, Error.t()}
  def list(client) do
    with {:ok, ref} <- Governance.lookup(client) do
      now = Governance.now(ref.settings)

      grants =
        for {{:grant, principal, server_id, tool, fingerprint}, expires_at} <-
              select_grants(ref.table),
            expires_at > now do
          %{
            principal: principal,
            server_id: server_id,
            tool: tool,
            fingerprint: fingerprint,
            expires_at: expires_at
          }
        end

      {:ok, grants}
    end
  end

  @doc "Removes every grant of `principal`."
  @spec revoke(term(), term()) :: :ok | {:error, Error.t()}
  def revoke(client, principal) do
    with {:ok, ref} <- Governance.lookup(client), do: Owner.write(ref.owner, {:revoke, principal})
  end

  @doc "Removes every grant."
  @spec clear(term()) :: :ok | {:error, Error.t()}
  def clear(client) do
    with {:ok, ref} <- Governance.lookup(client), do: Owner.write(ref.owner, :clear_grants)
  end

  @doc false
  # Whether an unexpired grant exists for `{principal, server_id, tool, fingerprint}`.
  @spec granted?(Governance.ref(), {term(), String.t(), String.t(), String.t()}, integer()) ::
          boolean()
  def granted?(ref, {principal, server_id, tool, fingerprint}, now) do
    case Governance.read(ref.table, {:grant, principal, server_id, tool, fingerprint}) do
      [{_key, expires_at}] -> expires_at > now
      _none -> false
    end
  end

  @doc false
  # Records a grant for `ttl` ms from `now`.
  @spec put(Governance.ref(), {term(), String.t(), String.t(), String.t()}, integer()) :: :ok
  def put(ref, key, now),
    do: Owner.write(ref.owner, {:put_grant, key, now + ref.settings.grant_ttl, now})

  defp select_grants(table) do
    :ets.match_object(table, {{:grant, :_, :_, :_, :_}, :_})
  rescue
    ArgumentError -> []
  end
end

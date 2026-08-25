defmodule ConduitMcp.Principal do
  @moduledoc """
  The one canonical representation of "who is calling".

  Both authentication plugs (`ConduitMcp.Plugs.Auth` and
  `ConduitMcp.Plugs.OAuth`) write a principal through `put/2`, and every
  consumer that needs an identity — task ownership, per-user rate limiting,
  scope checks — reads it through this module.

  Before this existed, each consumer guessed a different shape from
  `conn.assigns[:current_user]` and all of them guessed wrong: `Plugs.OAuth`
  assigned a *map of claims* (containing `exp`, `iat`, `jti`), so task
  ownership — an exact-match comparison — never matched across two requests
  by the same user, and the owner's own task 404'd.

  ## Shape

  The principal is a plain map, always with these keys:

      %{
        id: String.t() | nil,     # stable scalar identity, comparable with ==
        scopes: [String.t()],     # granted OAuth scopes ([] for other strategies)
        strategy: atom() | nil,   # :oauth | :bearer_token | :api_key | :function
        claims: map() | nil,      # verified JWT claims for :oauth, nil otherwise
        user: term()              # whatever a :function verifier returned
      }

  `:id` is the **only** field safe to compare or use as a key. It is
  deliberately a scalar and deliberately free of per-request values:

    * `:oauth` — the token's `sub` claim.
    * `:function` / `:custom` — derived from the verifier's return value
      (`:id`, `"id"`, `:sub`, `"sub"`, or the value itself when it is a
      binary/integer/atom).
    * `:bearer_token` / `:api_key` — the configured `:principal_id`, or a
      stable digest of the shared credential. A static shared secret really
      does identify one principal; configure `:principal_id` when you need a
      readable name for it.

  `nil` means "unauthenticated" and, for task scoping, "no scoping".

  ## Assigns

  The principal lives in `conn.assigns[:mcp_principal]` (`assign_key/0`) and
  scopes are mirrored into `conn.assigns[:oauth_scopes]`
  (`scopes_assign_key/0`) for backward compatibility with
  `ConduitMcp.Plugs.OAuth.has_scope?/2` and existing consumer code.
  """

  @assign_key :mcp_principal
  @scopes_assign_key :oauth_scopes
  @unknown_ip "unknown"

  @defaults %{id: nil, scopes: [], strategy: nil, claims: nil, user: nil}

  @type t :: %{
          id: String.t() | nil,
          scopes: [String.t()],
          strategy: atom() | nil,
          claims: map() | nil,
          user: term()
        }

  @doc "The `conn.assigns` key holding the canonical principal."
  @spec assign_key() :: atom()
  def assign_key, do: @assign_key

  @doc "The `conn.assigns` key holding the granted scopes."
  @spec scopes_assign_key() :: atom()
  def scopes_assign_key, do: @scopes_assign_key

  @doc """
  Assigns a principal, filling in defaults for any key `fields` omits, and
  mirrors its scopes into `scopes_assign_key/0`.

  `:id` is normalised through `derive_id/1`, so the `id/1` `@spec` holds by
  construction no matter what an application passes. `put/2` is public and a
  non-scalar id would otherwise flow into every keyed surface - task
  ownership, the rate-limit bucket, scope checks.
  """
  @spec put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put(conn, fields) when is_map(fields) do
    principal =
      @defaults
      |> Map.merge(fields)
      |> Map.update!(:id, &derive_id/1)

    conn
    |> Plug.Conn.assign(@assign_key, principal)
    |> Plug.Conn.assign(@scopes_assign_key, principal.scopes)
  end

  @doc "Returns the principal, or `nil` when the request is unauthenticated."
  @spec get(Plug.Conn.t() | map() | nil) :: t() | nil
  def get(%{assigns: assigns}) when is_map(assigns), do: Map.get(assigns, @assign_key)
  def get(_conn), do: nil

  @doc """
  Returns the stable scalar identity, or `nil`.

  This is the only value that may be compared, stored, or used as a key.
  """
  @spec id(Plug.Conn.t() | map() | nil) :: String.t() | nil
  def id(conn) do
    case get(conn) do
      %{id: id} -> id
      _ -> nil
    end
  end

  @doc "Returns the granted scopes, or `[]`."
  @spec scopes(Plug.Conn.t() | map() | nil) :: [String.t()]
  def scopes(%{assigns: assigns}) when is_map(assigns),
    do: Map.get(assigns, @scopes_assign_key) || []

  def scopes(_conn), do: []

  @doc """
  Derives a stable scalar id from an arbitrary verifier return value.

  Returns `nil` when no scalar identity can be found — callers must then fall
  back to something else rather than key on an unstable term.

  A **struct** is namespaced by its type: `%MyApp.User{id: 42}` derives
  `"MyApp.User:42"`, not `"42"`. Two record types with independent primary-key
  sequences would otherwise collapse into one principal, and task ownership is
  an exact string compare — so a `%MyApp.ApiClient{id: 42}` service account
  would read and cancel `%MyApp.User{id: 42}`'s tasks. This is the same
  defect `ConduitMcp.Plugs.OAuth`'s `resolve_subject/2` closes by prefixing
  the producing claim; here the type is what distinguishes them.

  Plain maps carry no type, so they are not namespaced: an OAuth claims map
  and a hand-built `%{id: ...}` are indistinguishable, and prefixing one shape
  and not the other would only move the collision.
  """
  @spec derive_id(term()) :: String.t() | nil
  def derive_id(%struct{} = value) do
    case struct_id(value) do
      nil -> nil
      id -> inspect(struct) <> ":" <> id
    end
  end

  def derive_id(%{id: id}), do: scalar(id)
  def derive_id(%{"id" => id}), do: scalar(id)
  def derive_id(%{sub: sub}), do: scalar(sub)
  def derive_id(%{"sub" => sub}), do: scalar(sub)
  def derive_id(value), do: scalar(value)

  defp struct_id(%{id: id}), do: scalar(id)
  defp struct_id(%{sub: sub}), do: scalar(sub)
  defp struct_id(_value), do: nil

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp scalar(_value), do: nil

  @doc """
  Returns the client IP as a string, or `"unknown"`.

  `:inet.ntoa/1` returns `{:error, :einval}` for a malformed `remote_ip`, and
  piping that straight into `to_string/1` raises `Protocol.UndefinedError` —
  killing the request process instead of returning a rate-limit response. The
  default key functions of both rate-limit plugs go through here.
  """
  @spec client_ip(Plug.Conn.t() | map()) :: String.t()
  def client_ip(%{remote_ip: remote_ip}) do
    case :inet.ntoa(remote_ip) do
      {:error, _reason} -> @unknown_ip
      address -> List.to_string(address)
    end
  end

  def client_ip(_conn), do: @unknown_ip

  @doc """
  Returns a rate-limit bucket key: the principal id when authenticated,
  otherwise the client IP.
  """
  @spec rate_limit_key(Plug.Conn.t() | map()) :: String.t()
  def rate_limit_key(conn) do
    case id(conn) do
      nil -> client_ip(conn)
      principal_id -> "user:" <> principal_id
    end
  end
end

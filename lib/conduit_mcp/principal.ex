defmodule ConduitMcp.Principal do
  @moduledoc """
  The one canonical representation of "who is calling".

  Both authentication plugs (`ConduitMcp.Plugs.Auth` and
  `ConduitMcp.Plugs.OAuth`) write a principal through `put/2`, and every
  consumer that needs an identity — task ownership, per-user rate limiting,
  scope checks — reads it through this module.

  Never key on `conn.assigns[:current_user]`: it is whatever the application
  shaped it as, and for `ConduitMcp.Plugs.OAuth` it carries the claims map,
  whose `exp`, `iat` and `jti` change on every token. An exact-match comparison
  against it never matches the same user twice.

  ## Shape

  The principal is a plain map, always with these keys:

      %{
        id: String.t() | nil,     # stable scalar identity, comparable with ==
        scopes: [String.t()],     # granted OAuth scopes ([] for other strategies)
        strategy: atom() | nil,   # :oauth | :bearer_token | :api_key | :function
                                  # (the deprecated :custom strategy records :function)
        claims: map() | nil,      # verified JWT claims for :oauth, nil otherwise
        user: term()              # whatever a :function verifier returned
      }

  ## Id formats

  `:id` is the **only** field safe to compare or use as a key. It is always a
  string (or `nil`) and never contains per-request values. Its exact format
  depends on the strategy:

  | Strategy | `:id` | Example |
  |---|---|---|
  | `:oauth` | `"<claim>:<value>"` for the first of `:subject_claims` (default `["sub", "client_id"]`) holding a non-empty string or an integer | `"sub:user-123"`, `"client_id:svc-42"`, `"sub:12345"` |
  | `:function` / `:custom`, or `:verify` with no `:token` / `:api_key` | `derive_id/1` of the verifier's return value, or `"static:<digest>"` when it has no identity | `"MyApp.User:42"`, `"42"`, `"alice"` |
  | `:bearer_token` with `:token` / `:api_key` with `:api_key` | the configured `:principal_id`, else `"static:<digest>"` | `"ci-bot"`, `"static:0wRuzI3TJCrfYoAa"` |

  * **OAuth ids are prefixed by the claim that produced them** so `sub` and
    `client_id` cannot alias. An authorization server that lets a client pick
    its own `client_id` would otherwise let it register a target user's `sub`
    as its `client_id`, obtain a client-credentials token (no `sub`, so the
    fallback claim wins) and resolve to that user's principal. Integer claims
    render as decimal strings, so `sub: 1` and `client_id: "1"` would collide
    too without the prefix. A verified token with none of the claims is
    rejected with 401.
  * **Verifier-derived ids** follow `derive_id/1`: a struct is namespaced by
    its type (`"MyApp.User:42"`); a plain map yields its `:id`, `"id"`, `:sub`
    or `"sub"` unprefixed; a bare binary, integer or atom is used as-is. The
    status markers `true`, `false` and `:ok` carry no identity, so a verifier
    returning `{:ok, true}` gets the credential digest instead.
  * **`"static:<digest>"`** is the first 12 bytes of the SHA-256 of the
    presented credential, base64url-encoded without padding: the credential
    `"shared-secret"` always yields `"static:0wRuzI3TJCrfYoAa"`. It is stable
    across requests and restarts and never echoes the credential. A static
    shared secret really does identify one principal; set `:principal_id`
    when you need a readable name for it. `:principal_id` is rejected
    whenever `:verify` authenticates (`:function` / `:custom`, or
    `:bearer_token` / `:api_key` without `:token` / `:api_key`), where one
    fixed id would merge every user.

  `nil` = no principal: sees only unowned tasks; nothing under
  `:tasks_require_owner` (see `ConduitMcp.Tasks.get/2`).

  ## Anonymous clients

  Without a principal, rate-limit keys (`rate_limit_key/1`, the default keys
  of `ConduitMcp.Plugs.RateLimit` and `ConduitMcp.Plugs.MessageRateLimit`) and
  cancellation scopes fall back to `client_bucket/1`: the IPv4 address, or
  the IPv6 `/64` prefix — one host is typically allocated a whole `/64`, so a
  per-address key would let it rotate addresses to evade limits. IPv4-mapped
  IPv6 addresses unwrap to the embedded IPv4 address. `client_ip/1` is the
  precise address, for display and logging.

  To key the HTTP rate limiter on the precise address instead, pass
  `key_func: &ConduitMcp.Principal.client_ip/1`.

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
  A principal assigned without `put/2` whose `:id` is not a string yields
  `nil`, so every consumer (task ownership, rate-limit and cancellation
  scopes) treats it as anonymous rather than raising on it.
  """
  @spec id(Plug.Conn.t() | map() | nil) :: String.t() | nil
  def id(conn) do
    case get(conn) do
      %{id: id} when is_binary(id) -> id
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

  Accepted shapes:

    * a **struct** → `"<inspect(struct)>:<v>"`, where `<v>` is its `:id` (or
      `:sub` when it has no `:id` field); e.g. `%MyApp.User{id: 42}` derives
      `"MyApp.User:42"`;
    * a **map** → the value under the first of `:id`, `"id"`, `:sub`, `"sub"`
      that it has, unprefixed;
    * a bare **binary**, **integer** or **atom** → itself as a string.

  A scalar is a binary, an integer, or an atom other than `nil`, `true`,
  `false` and `:ok`. Those four carry no identity — `true` is what a
  "credential is valid" verifier returns for every caller — so they derive
  `nil`, as does any other shape. Callers must then fall back to something
  else rather than key on an unstable term; `ConduitMcp.Plugs.Auth` uses the
  credential digest.

      iex> ConduitMcp.Principal.derive_id(%{id: 42})
      "42"
      iex> ConduitMcp.Principal.derive_id(%{"sub" => "alice"})
      "alice"
      iex> ConduitMcp.Principal.derive_id(:svc)
      "svc"
      iex> ConduitMcp.Principal.derive_id(true)
      nil
      iex> ConduitMcp.Principal.derive_id(%{"exp" => 1_700_000_000})
      nil

  A struct is namespaced by its type because two record types with
  independent primary-key sequences would otherwise collapse into one
  principal, and task ownership is an exact string compare — a
  `%MyApp.ApiClient{id: 42}` service account would read and cancel
  `%MyApp.User{id: 42}`'s tasks. `ConduitMcp.Plugs.OAuth` closes the same
  hole by prefixing the claim that produced the id.

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

  # `true`, `false` and `:ok` are success markers, not identities: a verifier
  # returning `{:ok, true}` would otherwise give every caller the id "true".
  # Returning nil lets `ConduitMcp.Plugs.Auth` fall back to the credential
  # digest instead.
  defp scalar(value) when value in [true, false, :ok], do: nil
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp scalar(_value), do: nil

  @doc """
  Returns the client IP as a string, or `"unknown"`.

  This is the precise address, for display and logging. Rate-limit and
  cancellation keys use `client_bucket/1` instead, which groups IPv6 clients
  by `/64`.

  `:inet.ntoa/1` returns `{:error, :einval}` for a malformed `remote_ip`, and
  piping that straight into `to_string/1` raises `Protocol.UndefinedError` —
  killing the request process instead of returning a rate-limit response.
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
  Returns the bucket an anonymous client is keyed on: its address for IPv4,
  its `/64` prefix for IPv6, or `"unknown"` for a malformed `remote_ip`.

  An ISP or hosting provider typically allocates a whole `/64` to one
  subscriber or host, and the host picks its own interface identifier (the low
  64 bits) freely — privacy extensions rotate it on their own. Keying on the
  full address would let one client mint a fresh bucket per request, so every
  address in a `/64` shares one bucket, rendered as the prefix with the
  interface identifier zeroed: `"2001:db8:1:2::/64"`.

  An IPv4-mapped IPv6 address (`::ffff:192.0.2.1`, what a dual-stack socket
  reports for an IPv4 peer) is unwrapped to the embedded IPv4 address, so the
  same IPv4 client lands in the same bucket whichever socket family accepted
  it — and is not merged with every other IPv4 client under `"::ffff:0:0/64"`.

  `client_ip/1` remains the precise address, for display and logging.

      iex> ConduitMcp.Principal.client_bucket(%{remote_ip: {192, 0, 2, 7}})
      "192.0.2.7"
      iex> ConduitMcp.Principal.client_bucket(%{remote_ip: {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}})
      "2001:db8:1:2::/64"
      iex> ConduitMcp.Principal.client_bucket(%{remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}})
      "192.0.2.1"
  """
  @spec client_bucket(Plug.Conn.t() | map()) :: String.t()
  def client_bucket(%{remote_ip: {0, 0, 0, 0, 0, 0xFFFF, _hi, _lo} = address}) do
    if :inet.is_ipv6_address(address),
      do: client_ip(%{remote_ip: :inet.ipv4_mapped_ipv6_address(address)}),
      else: @unknown_ip
  end

  def client_bucket(%{remote_ip: {a, b, c, d, _, _, _, _} = address}) do
    if :inet.is_ipv6_address(address),
      do: client_ip(%{remote_ip: {a, b, c, d, 0, 0, 0, 0}}) <> "/64",
      else: @unknown_ip
  end

  def client_bucket(conn), do: client_ip(conn)

  @doc """
  Returns a rate-limit bucket key: `"user:" <> id` when authenticated,
  otherwise `client_bucket/1` (the IPv4 address, or the IPv6 `/64`).
  """
  @spec rate_limit_key(Plug.Conn.t() | map()) :: String.t()
  def rate_limit_key(conn) do
    case id(conn) do
      nil -> client_bucket(conn)
      principal_id -> "user:" <> principal_id
    end
  end
end

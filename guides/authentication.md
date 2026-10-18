# Authentication

ConduitMCP supports multiple authentication strategies. Configure auth in transport options or in `ConduitMcp.Endpoint` use opts.

## Prerequisites

Bearer token, API key and custom-function strategies need no extra
dependencies. **OAuth 2.1 does**, and it is compiled in only when those
dependencies were present when `:conduit_mcp` was built:

| You configure | You need |
|---|---|
| `strategy: :oauth` | `{:joken, "~> 2.6"}` and `{:jose, "~> 1.11"}` |
| `key_provider: {ConduitMcp.OAuth.KeyProvider.JWKS, ...}` | additionally `{:req, "~> 0.6.1 or ~> 0.7"}` |

After adding them, **force a rebuild of `:conduit_mcp`**:

```bash
mix deps.get
mix deps.compile conduit_mcp --force
```

`ConduitMcp.Plugs.OAuth` and `ConduitMcp.OAuth.KeyProvider.JWKS` are wrapped
in `if Code.ensure_loaded?(Dep)` guards, which are conditional *compilation*.
Mix does not recompile an already-built dependency when you later add one of
its optional deps, so without the `--force` rebuild the modules stay absent.
When that happens the transport's `init/1` raises
`ConduitMcp.OptionalDependencyError` naming the missing dependency and this
command.

`ConduitMcp.OAuth.KeyProvider.Static` also needs `:joken`/`:jose`, but not
`:req`.

## Strategies

### Bearer Token

Static token comparison against the `Authorization: Bearer <token>` header.

```elixir
auth: [
  strategy: :bearer_token,
  token: "your-secret-token"
]
```

### API Key

Static key comparison against a custom header (default: `x-api-key`).

```elixir
auth: [
  strategy: :api_key,
  api_key: "your-api-key",
  header: "x-api-key"        # optional, this is the default
]
```

### Custom Function

Your own verification logic. Receives the credential string, must return `{:ok, user}` or `{:error, reason}`.

```elixir
auth: [
  strategy: :function,
  verify: fn token ->
    case MyApp.Auth.verify(token) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, "Invalid token"}
    end
  end
]
```

### Database Lookup

```elixir
auth: [
  strategy: :function,
  verify: fn token ->
    case MyApp.Repo.get_by(ApiToken, token: token) do
      %ApiToken{user: user} -> {:ok, user}
      nil -> {:error, "Invalid token"}
    end
  end
]
```

### MFA Tuple

```elixir
auth: [
  strategy: :function,
  verify: {MyApp.Auth, :verify_token, []}
]
```

### OAuth 2.1 (RFC 9728)

JWT-based verification with JWKS key discovery.

```elixir
auth: [
  strategy: :oauth,
  issuer: "https://auth.example.com",
  audience: "my-mcp-server",
  key_provider: {ConduitMcp.OAuth.KeyProvider.JWKS,
    jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
]
```

### Disable Auth

```elixir
auth: [enabled: false]
```

## Accessing the Authenticated User

Whatever your `:verify` function returned is stored in
`conn.assigns[:current_user]` (configurable with `assign_as:`). Use it for
application data — display names, roles, your own structs:

```elixir
# DSL mode
tool "profile", "Get profile" do
  handle fn conn, _params ->
    case conn.assigns[:current_user] do
      nil -> error("Not authenticated")
      user -> json(user)
    end
  end
end

# Endpoint mode
def execute(_params, conn) do
  user = conn.assigns[:current_user]
  text("Hello #{user.name}")
end
```

## The canonical principal

`:current_user` is shaped by *you*, so the library cannot use it as an
identity. For anything that compares, stores, or keys on "who is calling" —
task ownership, per-user rate limiting, scope checks — read
`ConduitMcp.Principal`:

```elixir
ConduitMcp.Principal.id(conn)      # stable scalar identity, or nil
ConduitMcp.Principal.scopes(conn)  # granted OAuth scopes, or []
ConduitMcp.Principal.get(conn)     # %{id:, scopes:, strategy:, claims:, user:}
```

`id/1` is always a string (or `nil`). Its exact format depends on the strategy:

| Strategy | `id` | Example |
|---|---|---|
| `:oauth` | `"<claim>:<value>"` for the first of `:subject_claims` (default `["sub", "client_id"]`) holding a non-empty string or an integer | `"sub:user-123"`, `"client_id:svc-42"`, `"sub:12345"` |
| `:function` / `:custom`, or `:verify` with no `:token` / `:api_key` | `ConduitMcp.Principal.derive_id/1` of the verifier's return; `"static:<digest>"` when it carries no identity | see below |
| `:bearer_token` with `:token` / `:api_key` with `:api_key` | the configured `principal_id:`, else `"static:<digest>"` | `"ci-bot"`, `"static:0wRuzI3TJCrfYoAa"` |

- **OAuth ids carry the claim name.** Without the prefix, an authorization
  server that lets a client pick its own `client_id` would let it register a
  victim's `sub` as its `client_id`, obtain a client-credentials token (no
  `sub`, so `client_id` wins) and become that user's principal. Integer claims
  render as decimal strings, so `sub: 1` and `client_id: "1"` would collide
  too.
- **Verifier returns** (`:function`, and the deprecated `:custom`, which is
  recorded as `strategy: :function`):

  | `{:ok, ...}` from `:verify` | `id` |
  |---|---|
  | `%MyApp.User{id: 42}` (any struct with `:id`, else `:sub`) | `"MyApp.User:42"` |
  | `%{id: 42}` / `%{"id" => 42}` / `%{sub: "alice"}` / `%{"sub" => "alice"}` | `"42"` / `"alice"` |
  | `"alice"`, `42`, `:svc` | `"alice"`, `"42"`, `"svc"` |
  | `true`, `false`, `:ok`, or no scalar identity | `"static:<digest>"` of the presented credential |

  Structs are namespaced by type so `%User{id: 42}` and `%ApiClient{id: 42}`
  stay different principals. `principal_id:` is rejected at `init/1` whenever
  `:verify` authenticates — including `:bearer_token` / `:api_key` without a
  `:token` / `:api_key` — since one fixed id would merge every user into one
  principal.
- **`"static:<digest>"`** is the first 12 bytes of the SHA-256 of the
  credential, base64url without padding (`"shared-secret"` →
  `"static:0wRuzI3TJCrfYoAa"`). Stable across requests and restarts; never
  echoes the credential.

`nil` = no principal: sees only unowned tasks; nothing under
`:tasks_require_owner` (see `ConduitMcp.Tasks.get/2`). Rate-limit keys and
cancellation scopes fall back to the client bucket,
`ConduitMcp.Principal.client_bucket/1`: the IPv4 address, or the IPv6 `/64`
(see [Rate Limiting](rate_limiting.md#anonymous-clients)).

> **An OAuth token with no usable subject claim is rejected with 401.** `sub`
> is optional in a JWT and absent from many client-credentials access tokens.
> Accepting one would create an authenticated principal that everything
> downstream reads as anonymous — tasks unowned (visible to every caller
> unless `:tasks_require_owner` is set), rate limiting on the shared
> client-address bucket. Point `:subject_claims` at whatever your
> authorization server does emit:
>
> ```elixir
> auth: [strategy: :oauth, subject_claims: ["sub", "client_id", "tenant_id"], ...]
> ```

> **Never key on `:current_user` or on the OAuth claims map.** The claims map
> carries `exp`, `iat` and `jti`, which change on every token — an exact-match
> comparison against it never matches the same user twice, so an owner-scoped
> task 404s for its own owner.

For a static shared credential, set `principal_id:` to give it a readable
identity. It requires the secret itself (`:token` or `:api_key`):

```elixir
auth: [strategy: :bearer_token, token: "...", principal_id: "ci-bot"]
```

OAuth scopes are also mirrored to `conn.assigns[:oauth_scopes]`.

## Configuration in Endpoint Mode

In Endpoint mode, auth config is declared in the `use` opts and auto-extracted by transports:

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Endpoint,
    name: "My Server",
    version: "1.0.0",
    auth: [strategy: :bearer_token, token: "secret"]

  component MyApp.Echo
end

# Transport auto-extracts auth — no need to repeat it
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
 port: 4001}
```

## Insufficient Scope and Step-Up

A tool, resource or prompt can require OAuth scopes (`scope "users:delete"` in the DSL, `scope:` on a component). A request whose token lacks them is rejected before the callback runs. How it's rejected depends on the strategy.

**Under `strategy: :oauth`** the response is **HTTP 403** with a Bearer challenge, so the client can ask its authorization server for a token with more scope and retry:

```http
HTTP/1.1 403 Forbidden
www-authenticate: Bearer error="insufficient_scope", scope="users:delete", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
content-type: application/json

{"jsonrpc": "2.0", "id": 4,
 "error": {"code": -32000, "message": "Insufficient scope. Required: users:delete",
           "data": {"error": "insufficient_scope", "scope": "users:delete"}}}
```

The body is still the JSON-RPC error, with the request id, so the client can match it to its request. Both protocol eras get the same challenge.

**Every other strategy** answers the same JSON-RPC error at HTTP 200. Only OAuth has an authorization server to step up with. The error's `data` (`"error" => "insufficient_scope"`, `"scope"`) is the same under every strategy.

A request with no principal at all fails a scope check closed.

## Modern Era (`2026-07-28`)

Authentication runs before the protocol era is decided, so both eras authenticate the same way, with the same 401.

- **`server/discover` is authenticated** like every other POST, even though it needs no `_meta`. Capabilities can depend on who is asking. Under `strategy: :oauth`, the 401 carries `WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource"`, so a modern client can find the authorization server and authorize first.
- **Listen streams end with their token.** A `subscriptions/listen` stream opened with an OAuth bearer token closes at the token's `exp`, or at `:max_stream_lifetime` if that comes first. See [Subscriptions](subscriptions.md#how-a-stream-ends).
- **Ownership follows the principal.** MRTR `requestState` tokens and tasks-extension tasks are bound to `ConduitMcp.Principal.id/1`. Without authentication they are bound to `nil`, and MRTR state then expires after 60 seconds instead of 5 minutes.

> #### Client-side OAuth {: .info}
>
> This library's OAuth support verifies tokens, which is the server's side of the protocol. The client-side concerns — RFC 9207 `iss` validation, `application_type`, issuer-bound credentials and Client ID Metadata Documents — belong to the planned ConduitMCP client. They are covered in the upcoming client OAuth guide (`client_oauth.md`), not here. The server doesn't ignore them; they aren't its job.

## Telemetry

Auth events: `[:conduit_mcp, :auth, :verify]` with metadata `%{strategy, status}`,
plus `:reason` on failure. `:reason` is always an atom, never verifier or token
text: `:invalid_credential` / `:invalid_return` for `ConduitMcp.Plugs.Auth`, and
the set in the "Telemetry" section of `ConduitMcp.Plugs.OAuth` for `:oauth`.

## Behavior

- CORS preflight (`OPTIONS`) requests skip authentication
- Failed auth returns HTTP 401 with `{"error": "Unauthorized", "message": "..."}`
- The `assign_as:` option controls the conn assigns key (default: `:current_user`)

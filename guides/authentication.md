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

`id/1` is:

| Strategy | `id` |
|---|---|
| `:oauth` | the first of `:subject_claims` present in the token (default `["sub", "client_id"]`) |
| `:function` / `:custom` | derived from the verifier's return (`:id`, `"id"`, `:sub`, `"sub"`, or a bare binary/integer/atom) |
| `:bearer_token` / `:api_key` | the configured `principal_id:`, else a stable digest of the shared credential |

> **An OAuth token with no usable subject claim is rejected with 401.** `sub`
> is optional in a JWT and absent from many client-credentials access tokens.
> Accepting one would create an authenticated principal that everything
> downstream reads as anonymous — tasks unowned and world-readable, rate
> limiting on the shared IP bucket. Point `:subject_claims` at whatever your
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
identity:

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

## Telemetry

Auth events: `[:conduit_mcp, :auth, :verify]` with metadata `%{strategy, status, error}`.

## Behavior

- CORS preflight (`OPTIONS`) requests skip authentication
- Failed auth returns HTTP 401 with `{"error": "Unauthorized", "message": "..."}`
- The `assign_as:` option controls the conn assigns key (default: `:current_user`)

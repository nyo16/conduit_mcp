# Authentication

ConduitMCP supports multiple authentication strategies. Configure auth in transport options or in `ConduitMcp.Endpoint` use opts.

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

The authenticated user is stored in `conn.assigns[:current_user]`:

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

OAuth scopes are available in `conn.assigns[:oauth_scopes]`.

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

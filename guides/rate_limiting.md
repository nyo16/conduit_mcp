# Rate Limiting

ConduitMCP supports two layers of rate limiting using [Hammer](https://hex.pm/packages/hammer). Both are optional.

## Setup

Add `hammer` to your dependencies:

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.9.0"},
    {:hammer, "~> 7.2"}
  ]
end
```

Define a Hammer module and add it to your supervision tree:

```elixir
defmodule MyApp.RateLimiter do
  use Hammer, backend: :ets
end

# In application.ex
children = [
  {MyApp.RateLimiter, [clean_period: :timer.minutes(1)]}
]
```

## HTTP Rate Limiting

Limits raw HTTP connections — prevents DDoS and connection flooding.

```elixir
rate_limit: [
  backend: MyApp.RateLimiter,
  scale: :timer.seconds(60),
  limit: 100
]
```

| Option | Default | Description |
|--------|---------|-------------|
| `:backend` | required | Hammer module with `hit/3` |
| `:enabled` | `true` | Toggle on/off |
| `:scale` | `60_000` | Time window in ms |
| `:limit` | `60` | Max requests per window |
| `:key_func` | IP-based | `(Plug.Conn.t()) -> String.t()` |

## Message Rate Limiting

Limits MCP method calls (tool calls, resource reads, prompt gets) per time window.

Think of it as: HTTP rate limit = "how fast can you knock on the door", message rate limit = "how many questions can you ask once inside."

```elixir
message_rate_limit: [
  backend: MyApp.RateLimiter,
  scale: :timer.minutes(5),
  limit: 50,
  excluded_methods: ["initialize", "ping"]
]
```

| Option | Default | Description |
|--------|---------|-------------|
| `:backend` | required | Hammer module with `hit/3` |
| `:enabled` | `true` | Toggle on/off |
| `:scale` | `300_000` | Time window in ms (5 min) |
| `:limit` | `50` | Max messages per window |
| `:key_func` | user-aware | Uses `conn.assigns[:current_user]` if set, falls back to IP |
| `:excluded_methods` | `[]` | Methods to skip (e.g., `["initialize", "ping"]`) |

**Behaviors:**
- POST only — GET and OPTIONS requests pass through
- Notifications skipped — JSON-RPC notifications (no `id` field) are not counted
- User-aware — default key uses authenticated user when Auth plug is in the pipeline
- Key prefix — keys are prefixed with `"msg:"` to avoid collision with HTTP rate limiter
- HTTP 429 — returns JSON-RPC error with code `-32000` and `Retry-After` header

## Per-user Rate Limiting

```elixir
rate_limit: [
  backend: MyApp.RateLimiter,
  limit: 100,
  key_func: fn conn ->
    case conn.assigns[:current_user] do
      %{id: id} -> "user:#{id}"
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
]
```

## Configuration in Endpoint Mode

In Endpoint mode, rate limiting is declarative in the `use` opts:

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Endpoint,
    name: "My Server",
    version: "1.0.0",
    rate_limit: [backend: MyApp.RateLimiter, limit: 60, scale: 60_000],
    message_rate_limit: [backend: MyApp.RateLimiter, limit: 50, scale: 300_000]

  component MyApp.Echo
end

# Transport auto-extracts rate_limit config
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
 port: 4001}
```

Explicit transport opts always override Endpoint config.

## Telemetry

- `[:conduit_mcp, :rate_limit, :check]` — HTTP rate limit checks with `%{status, count, retry_after}`
- `[:conduit_mcp, :message_rate_limit, :check]` — Message rate limit checks with `%{status, key, method}`

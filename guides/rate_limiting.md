# Rate Limiting

ConduitMCP supports two layers of rate limiting using [Hammer](https://hex.pm/packages/hammer). Both are optional.

## Setup

Add `hammer` to your dependencies:

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.10"},
    {:hammer, "~> 7.2"}
  ]
end
```

**After adding it, force a rebuild of `:conduit_mcp`:**

```bash
mix deps.get
mix deps.compile conduit_mcp --force
```

`ConduitMcp.Plugs.RateLimit` resolves its Hammer backend at runtime, but
`:hammer` must be in your dependency tree for the backend module to exist.
If you add an optional dependency after `:conduit_mcp` has already been
compiled into `_build`, Mix will not rebuild it — the `--force` compile above
is what makes the change take effect.

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
| `:key_func` | client bucket | `(Plug.Conn.t()) -> String.t()`; default is the IPv4 address or IPv6 `/64` (see [Anonymous clients](#anonymous-clients)) |

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
| `:key_func` | principal-aware | Uses `ConduitMcp.Principal.id/1` if authenticated, falls back to the client bucket (IPv4 address or IPv6 `/64`) |
| `:excluded_methods` | `[]` | Methods to skip (e.g., `["initialize", "ping"]`) |

**Behaviors:**
- POST only — GET and OPTIONS requests pass through
- Notifications skipped — JSON-RPC notifications (no `id` field) are not counted
- User-aware — default key uses the canonical `ConduitMcp.Principal` when an auth plug is in the pipeline
- Key prefix — keys are prefixed with `"msg:"` to avoid collision with HTTP rate limiter
- HTTP 429 — returns JSON-RPC error with code `-32000` and `Retry-After` header

## Per-user Rate Limiting

The message rate limiter already does this out of the box: its default key is
`"msg:user:" <> ConduitMcp.Principal.id(conn)` for authenticated requests and
`"msg:" <>` the client bucket otherwise. Two OAuth subjects behind the same
proxy therefore get distinct buckets with no configuration.

The HTTP rate limiter keys on the client bucket by default, because it runs to
bound raw connections — including unauthenticated ones. Key it on the
principal when you want per-user HTTP limits:

```elixir
rate_limit: [
  backend: MyApp.RateLimiter,
  limit: 100,
  key_func: &ConduitMcp.Principal.rate_limit_key/1
]
```

`rate_limit_key/1` returns `"user:" <> id` when authenticated and the client
bucket otherwise. Do not hand-roll `conn.remote_ip |> :inet.ntoa() |> to_string()`:
`:inet.ntoa/1` returns `{:error, :einval}` for a malformed address and
`to_string/1` then raises, killing the request process instead of returning
429.

## Anonymous clients

Unauthenticated callers are keyed on `ConduitMcp.Principal.client_bucket/1`,
not on their exact address:

| Client address | Bucket |
|----------------|--------|
| IPv4 `192.0.2.7` | `"192.0.2.7"` |
| IPv6 `2001:db8:1:2:a:b:c:d` | `"2001:db8:1:2::/64"` |
| IPv4-mapped IPv6 `::ffff:192.0.2.1` | `"192.0.2.1"` |
| malformed `remote_ip` | `"unknown"` |

An ISP or hosting provider typically allocates a whole `/64` to one subscriber
or host, and the host chooses the low 64 bits itself (privacy extensions rotate
them automatically). Keying on the full IPv6 address would let a single client
take a fresh bucket for every request, so every address in a `/64` shares one.
A dual-stack socket reports IPv4 peers as IPv4-mapped IPv6 addresses; those
unwrap to the IPv4 address so one IPv4 client gets one bucket regardless of the
socket family, and IPv4 clients are not all merged under `::ffff:0:0/64`.

The same bucket is the cancellation scope of anonymous requests (see
`ConduitMcp.Cancellation`), so rotating addresses within a `/64` cannot
multiply the per-scope quota on recorded cancellations either.

`ConduitMcp.Principal.client_ip/1` still returns the precise address for
logging and display. To key the HTTP rate limiter on it instead, pass it as a
remote capture (required by `Plug.Router.forward/2`, which escapes the options
at compile time):

```elixir
rate_limit: [
  backend: MyApp.RateLimiter,
  key_func: &ConduitMcp.Principal.client_ip/1
]
```

For the message rate limiter, keep the `"msg:"` prefix so the two limiters do
not share buckets:

```elixir
defmodule MyApp.RateKeys do
  def message(conn) do
    case ConduitMcp.Principal.id(conn) do
      nil -> "msg:" <> ConduitMcp.Principal.client_ip(conn)
      id -> "msg:user:" <> id
    end
  end
end

message_rate_limit: [backend: MyApp.RateLimiter, key_func: &MyApp.RateKeys.message/1]
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

---
module: "ConduitMcp.Transport.StreamableHTTP"
date: "2026-11-10"
problem_type: security_issue
component: phoenix_router
symptoms:
  - "under a Phoenix router `forward`, an unauthenticated request's body is read before the 401 (body_params parsed, not %Plug.Conn.Unfetched{})"
  - "`max_body_bytes: 100` has no effect: an authenticated 2 KB body is answered 200 instead of 413"
root_cause: "a Phoenix endpoint runs its own Plug.Parsers (8 MB default) before the router, and Plug.Parsers skips a conn whose body_params are already fetched, so the transport's own parse-after-auth parser never runs"
severity: medium
tags: [phoenix, forward, plug-parsers, body-limit, auth-order, endpoint, plug-forward]
---

# Phoenix `forward` parses the MCP body before the transport authenticates

## Symptoms

The transports run `auth → rate_limit → Plug.Parsers(length: :max_body_bytes)`,
so a rejected request costs no body read. Mounted with a router `forward`, both
guarantees disappeared. I checked this with a throwaway `Plug.Builder` pipeline
mimicking an endpoint:

| forwarding position | no token | token, 2 KB body, limit 100 |
|---|---|---|
| above `Plug.Parsers` | 401, body unread | 413 |
| below `Plug.Parsers` (= router `forward`) | 401, **body read** | **200** |

## Root Cause

Phoenix's endpoint pipeline is `... → Plug.Parsers → Router`. By the time the
router forwards, `conn.body_params` is already a map (read up to 8 MB). Our
transport's `Plug.Parsers` sees a fetched body and does nothing, so the transport
can't enforce `:max_body_bytes` or parse-after-auth.

## Solution

Forward from a plug placed **above** `plug Plug.Parsers` in the endpoint. Use
`Plug.forward/4` on the path prefix, then halt:

```elixir
defmodule MyAppWeb.MCPForward do
  @behaviour Plug
  alias ConduitMcp.Transport.StreamableHTTP

  @impl true
  def init(opts) do
    {at, opts} = Keyword.pop!(opts, :at)
    {String.split(at, "/", trim: true), StreamableHTTP.init(opts)}
  end

  @impl true
  def call(%Plug.Conn{path_info: path_info} = conn, {prefix, transport_opts}) do
    case Enum.split(path_info, length(prefix)) do
      {^prefix, rest} ->
        conn |> Plug.forward(rest, StreamableHTTP, transport_opts) |> Plug.Conn.halt()

      _other ->
        conn
    end
  end
end
```

In `Plug.Test`, the over-limit case raises `Plug.Parsers.RequestTooLargeError`
(`Plug.Exception.status/1` is 413). Bandit or the endpoint's error handler turns
it into the 413 response.

### Files Changed

- `README.md` "Phoenix Integration": the plug and endpoint placement
- `guides/rate_limiting.md` "Request order": the caveat
- `lib/conduit_mcp/transport/streamable_http.ex`, `sse.ex` moduledocs (`:max_body_bytes`)

## Prevention

- Any guarantee that depends on plug order inside the transport only holds when
  the transport is the first thing to touch the body. Document how the host
  mounts it, not just the transport's internal order.
- When claiming "body unread", prove it with `match?(%Plug.Conn.Unfetched{}, conn.body_params)`
  on the returned conn.

## Related

- `.claude/plans/hardening-0.11.1/scratchpad.md`: C1 "move the parser, not the limiter"

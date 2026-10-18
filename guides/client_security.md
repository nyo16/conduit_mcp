# Client Security

An MCP client connects your application, and often an LLM acting for your
users, to code you do not control. This guide summarizes what the client
assumes, what it does by default, and what remains your job.

## Threat model

Treat everything that comes from a server as **untrusted input**:

- **Servers.** A server may be malicious, compromised, or simply buggy. Its
  self-reported `serverInfo.name` is display data only; the client identifies
  servers by the operator-assigned `server_id`.
- **Tool definitions.** Names, descriptions, schemas and annotations are
  server-written. A description can carry instructions aimed at the model
  ("tool poisoning"), a name can imitate another tool, a schema can be
  pathological, and a definition can change after you approved it
  ("rug pull").
- **Tool results, resources, prompts and instructions.** Anything a server
  returns can try to steer the model (prompt injection), including into
  calling another server's tool with data it just read (cross-server
  exfiltration).
- **Server requests.** Sampling, elicitation and roots requests let a server
  ask for model calls, user input and local paths.

The client's stance on prompt injection is **flag, don't solve**. Injection
cannot be detected reliably, so the client does not try. It removes the
characters that hide text from humans, caps sizes, never fetches what a
server points at, records what it changed in `provenance`, and gives the
host the hooks to decide: tool filters, a policy with fixed precedence,
approvals bound to exact arguments, fingerprint pinning, and taint rules.
See [client_permissions_and_hooks.md](client_permissions_and_hooks.md).

## Security defaults

Every value below is the default. Each is enforced in code; the module named
is where it lives.

### Tools and governance

| Area | Default |
|---|---|
| Authorization (`ConduitMcp.Client`) | A plain client has **no policy** and sends what it is asked to. A `ConduitMcp.Client.Hub` refuses to start without `:policy`; allowing everything must be spelled out (`:allow_all`) |
| Precedence (`ConduitMcp.Client.Policy`) | deny > pin > ask > allow > default, hard-coded |
| Unmatched call | `:ask` with an approver, else denied (`reason: :no_rule`) |
| Matching | On the `{server_id, tool}` pair, never a namespaced string. Deny and ask rules match loosely (case, `-`/`.`/`_`); allow rules match exactly |
| Failing predicates | Count as matching in deny/ask lists and not matching in allow lists |
| Annotations | Untrusted (`trusted: false`): annotation rules see the conservative value |
| Rug pulls | `pin_tools: true`, `allow_new_tools: false`, `approved_fingerprints: :first_listing` |
| Approvals | `:ask_timeout` 60 s; the approver sees the exact arguments and their digest, which must be unchanged at send time; grants per principal and fingerprint, `:grant_ttl` 24 h |
| Hooks (`ConduitMcp.Client.Hooks`) | Run in tasks with a 5 s deadline; fail closed (a failing pre-hook sends nothing, a failing post-hook withholds the result); no hook can allow |
| Tool names (intake) | Outside `[A-Za-z0-9_.-]` (1-128), malformed, duplicate, or with invalid `x-mcp-header` annotations: dropped, warned, `tool.rejected` telemetry |
| Hidden tools (`ConduitMcp.Client.ToolFilter`) | Absent from listings and adapter output; calling one fails like an unknown tool |
| Hub naming (`ConduitMcp.Client.Naming`) | Operator `server_id`s (`^[a-z][a-z0-9_]{0,31}$`, no `__`, no trailing `_`, unique); every colliding tool is excluded; model names resolve by table lookup; an unknown name sends nothing |
| Schema validation (`ConduitMcp.Client.SchemaValidator`) | Off. When on: schemas over 64 levels, 1 000 subschemas or 256 KiB, or with non-local `$ref`, are refused; refs are never dereferenced over the network |

### Content for models

| Area | Default |
|---|---|
| Server instructions | `include_instructions: false`: `instructions_for_llm/1` returns `nil`. When on: 4 KiB cap, invisible characters removed, prefixed with the server's name unless `trusted: true` |
| Tool descriptions in adapters | Invisible characters (bidi, zero-width, tag, other controls) removed; 4 KiB cap |
| Results shaped for a model (`shape: :llm`, the adapter default) | 100 KiB cap (`:max_result_bytes_for_llm`); invisible characters removed and flagged; SVG and other non-allowlisted media replaced by placeholders; `_meta` and unknown keys dropped |
| Fetching | Nothing is fetched: not `resource_link` URIs, icons, embedded URIs or elicitation URLs |

### Server requests

| Area | Default |
|---|---|
| Capabilities (`ConduitMcp.Client.Handler`) | Nothing advertised without a handler callback; undeclared requests are refused before any callback runs |
| Rate limit | 10 input requests per second per server, bursts of 20 |
| Sampling | `maxTokens` clamped to 4 096; `includeContext` coerced to `"none"`; legacy sampling with no call in flight refused |
| Elicitation | URLs never opened; only absolute `https` without userinfo; `idn?` and `origin_mismatch?` flags; form schemas limited to the flat primitive subset; answers validated |
| Roots | Only local `file://` URIs, `.`/`..` resolved, asked per server |
| Legacy handlers | Run in tasks, never in the connection; killed after `:handler_timeout` (60 s, elicitation 5 min); at most 8 at once |
| Multi-round-trip (`ConduitMcp.Client.Request.MRTR`) | 8 rounds, 16 input requests per round, 64 KiB `requestState`; `requestState` held as a `Secret` and echoed byte-exact; retries always go to the same server |

### Connections

| Area | Default |
|---|---|
| Limits | 64 requests in flight, 128 queued, 4 listen streams; pagination capped at 100 pages, 10 000 items, 1 KiB cursors |
| Cache | Fresh only for the server's `ttlMs`, clamped to 1 hour; private results served only to the credential they were fetched with (HT-11) |
| Retries | Nothing that may have run is retried automatically |
| Era | Once modern, never downgraded to legacy; HTTP 5xx and network errors are never legacy evidence |
| Crash reports | The connection's `format_status/1` redacts the transport state and options, queued request params and every `assigns`; the stdio port owner redacts its state too |

## stdio

`ConduitMcp.Client.Transport.Stdio` runs a local process as this VM's user.

| Default | Why |
|---|---|
| `Port.open({:spawn_executable, path}, ...)`, never a shell | `:args` arrive literally; `"; rm -rf ~"` is one argument |
| `:command` may not contain whitespace | `"npx -y server"` raises: arguments go in `:args` |
| Environment allowlist (`HOME LOGNAME PATH SHELL TERM USER`; a Windows list on Windows), minus values starting with `()` | Your VM's secrets do not leak into every server |
| `.bat`/`.cmd` refused unless `allow_batch_files: true`; then `"%^&\|<>` in arguments refused | `cmd.exe` re-parses batch-file arguments |
| 8 MiB per message; 10 consecutive junk lines; 16 MiB unwritten stdin | A server cannot exhaust memory or stall the connection |
| stdin close, then `SIGTERM` after 2 s, `SIGKILL` after 2 s more | Servers that ignore EOF are still reaped |
| stderr never merged into stdout, never captured into `Logger` | Server stderr cannot corrupt the protocol stream or be logged by the client |
| In a hub: at most 16 stdio servers (`:max_stdio_servers`); a failed server restarted after full jitter from 1 s, doubling, capped at 30 s; each client gives up after 3 restarts in 5 s | A crash-looping or runaway configuration cannot fork without bound (ST-8) |

Know the limits:

- **Configuration is operator-only.** Whoever chooses `:command`, `:args`
  and `:env` runs code as your VM's user. Never build them from model output,
  server responses or end-user input, and treat imported server configs
  (for example from a desktop app's JSON) as code to review.
- **The env allowlist is hygiene, not isolation.** The server still runs as
  your user, with your file system and network.
- **No stderr capture.** stderr goes to this VM's stderr (`:inherit`), is
  discarded, or appended to a file (`:discard` and `{:file, path}` are POSIX
  only). It is never parsed or logged by the client.
- **Grandchildren may survive.** Launchers such as `npx` and `uvx` start the
  real server as a child. Closing stdin normally ends both, but the signals
  reach only the launcher's pid, so a grandchild that ignores EOF can outlive
  it.
- **A killed port owner only closes stdin.** If the port owner itself is
  killed (`Process.exit(pid, :kill)`, the VM halting), a server that ignores
  EOF keeps running.
- **PID reuse.** The pid is signalled after the port is closed, so reuse in
  that window is possible in theory.

When these matter, run servers under a wrapper that bounds and kills them:
a container, `systemd-run --user --scope -p MemoryMax=...`, `prlimit` for
resource limits, or MuonTrap for kill-on-parent-exit.

## Streamable HTTP

| Default | Meaning |
|---|---|
| `max_message_bytes: 8 MiB` | Per JSON body, per event-stream event, and per event-stream line; over it the request fails with `kind: :message_too_large` |
| No decompression | Requests send `accept-encoding: identity`; a response with a `content-encoding` fails |
| `redirect: false` | Every redirect fails. `:same_origin` follows only 307/308 to the same scheme, host and port, at most 5 |
| TLS verified | Peer verification against the system CA store. Any `verify:` other than `:verify_peer` (duplicates included) and any `verify_fun:` in `:transport_opts` are refused, for the transport and for OAuth requests |
| `insecure_skip_tls_verify: false` | Local development only; a warning is logged every time the transport starts |
| No bearer over plain HTTP | `:auth` with an `http` URL to a non-loopback host raises at start |
| Deadlines | A total deadline per request (bytes arriving slowly never extend it); long-lived streams get `listen_idle_timeout` (120 s) |
| Owned headers | `:headers` cannot set `accept`, `authorization`, `content-type`, `mcp-*`, `last-event-id` or hop-by-hop headers |
| Header bytes | A bearer token must be visible ASCII (0x21-0x7E), `:headers` values visible ASCII, space and tab. A static value outside that raises at start; a token obtained per request (an `:auth` function's, a token store's) outside it fails the request with `kind: :auth, reason: :invalid_token`, and a token endpoint's with `:invalid_token_response`. Neither error, nor any HTTP-layer error (`{:invalid_header_value, name}`), carries a header value, so a malformed token never reaches an error message, a log line or an LLM adapter's tool result |
| Session ids | 1 to 1024 visible ASCII characters, else the handshake fails; held as a `Secret` |
| 401 / 403 | `kind: :auth` with the parsed challenges |

### Server URL policy

`server_url_policy: :any` (default) trusts the URL: right for operator
configuration. When the URL comes from end users, use `:public_only`:

```elixir
{ConduitMcp.Client.Transport.StreamableHTTP,
 url: user_supplied_url,
 server_url_policy: :public_only,
 allow_private: ["10.20.0.0/16"]}
```

`:public_only` applies `ConduitMcp.Client.URLPolicy` before every request:
`https` only, and the host is resolved (A and AAAA) and refused if **any**
address is private, loopback, link-local, multicast or otherwise internal,
unless it falls inside an `:allow_private` CIDR. Hosts are parsed, never
string-matched: `127.1`, `0x7f.1`, `2130706433` and `[::ffff:127.0.0.1]` are
all loopback. URLs with user info, percent-encoded or non-ASCII hosts, IPv6
zone ids, backslashes or control characters are refused.

```elixir
ConduitMcp.Client.URLPolicy.check("https://127.1/", :public_only)
#=> {:error, {:blocked_address, {127, 0, 0, 1}}}
```

The request then connects to the first vetted address, never resolving the
name again, so a DNS answer that changes between the check and the connect
(rebinding) cannot send it elsewhere. TLS SNI, certificate verification and
the `Host` header all use the URL's host name. Each request (the legacy
GET stream and session `DELETE` included) is checked and pinned in its own
process; `resolver:` replaces DNS for the check, and runs there too, never
in the connection. The pinned connections come from pools the transport
starts in the Finch instance, yours with `finch:` included: one per vetted
address, sized by `:pool_size`, with `:transport_opts` as TLS options.

What this guarantees, and what it does not:

- **Every byte goes to an address that passed the policy at that request.**
  A later request resolves and vets the name again, so a pool may hold
  connections to every address the host has had.
- **The certificate check is the binding to the name.** That is why
  `:public_only` together with `insecure_skip_tls_verify: true` raises at
  start: without verification, whoever answers at the vetted address (or on
  the path to it) gets the request and its credentials.
- **Public addresses are still reachable.** The policy keeps requests away
  from internal networks; it does not vouch for the public server the user
  named.

## Secrets

Wrap credentials in `ConduitMcp.Client.Secret`:

```elixir
token = ConduitMcp.Client.Secret.new(System.fetch_env!("DOCS_TOKEN"))

inspect(token)                          #=> "#Secret<redacted>"
ConduitMcp.Client.Secret.expose(token)  #=> the value, where it belongs
```

| Path | Behaviour |
|---|---|
| `inspect/2`, `IO.inspect`, ExUnit diffs, crash-report translation | `#Secret<redacted>` |
| String interpolation, `to_string/1` | Raises `Protocol.UndefinedError` (the message stays redacted) |
| `Logger` metadata | Dropped by the formatter |
| `JSON.encode!/1` | Raises `ArgumentError` without the value, before any byte reaches the wire |

The client holds bearer tokens, legacy session ids, MRTR `requestState` and
`:env`/`:headers` values given as secrets this way. A `Secret` does not
guard against raw term printing (`:sys.get_state/1`,
`:erlang.term_to_binary/1`); client processes that hold one implement
`format_status/1` to redact their state.

Elsewhere:

- `ConduitMcp.Client.Error` messages render only the kind and a truncated
  reason; `data` (which may hold server content) is never rendered.
- Client telemetry metadata comes from a fixed allowlist: no arguments,
  results, `_meta`, tokens or raw error data. Tool names and methods are
  sanitized, and are server-supplied, so never use them as metric tags.
- **Finch's own telemetry is not the client's.** The `[:finch, ...]`
  events carry the request in their metadata, its headers included: the
  clear-text `Authorization` and `Mcp-Session-Id`. Never log or export
  Finch telemetry metadata wholesale; pick the fields you need.
- Server log entries (`notifications/message`) are rate limited per
  connection (`:log_rate_limit`, 50/s with bursts of 100; drops emit
  `[:conduit_mcp, :client, :log, :dropped]`) and reach subscribers and
  `handle_log/3` with every string passed through
  `ConduitMcp.Reflect.text/2` and the level clamped to the RFC 5424 set,
  so a server cannot forge your log lines.
- Trace context: only a well-formed W3C `traceparent` (from the
  `:traceparent` request option or `Logger.metadata()[:traceparent]`) is
  propagated in a modern request's `_meta`; `tracestate` and `baggage`
  never are.
- Hooks: what a failing hook raised is never logged or emitted.
- Task ids are bound to the credential that created them and may act as
  bearer tokens: never log them.
- Private cached results are keyed by credential (HT-11, enforced): a list
  the server marks `cacheScope: "private"` (or leaves unmarked) is served
  only while the client sends the credentials it was fetched with, and is
  deleted when they change (`ConduitMcp.Client.set_auth/3`, OAuth for
  another principal). The key is a digest: the token's SHA-256, the OAuth
  `{principal, issuer, resource}`, or an `:auth` function's
  `:credential_id`. Without a `:credential_id` an `:auth` function's
  private results are never served from the cache. See "Private results and
  credentials" in [client.md](client.md).
- Grants and the approval baseline belong to one client: pass `principal:`
  on calls, or run one client (or hub) per user when users differ.

## `ui://` resources

MCP Apps servers return self-contained HTML as `ui://` resources (see
[mcp_apps.md](mcp_apps.md)). The client reads them like any other resource
and does not render, sanitize or execute them. Rendering is the host's job,
and that HTML is server-written: show it only in a sandboxed iframe on an
origin separate from your application, with a restrictive Content Security
Policy, and never give it your session, cookies or tokens.

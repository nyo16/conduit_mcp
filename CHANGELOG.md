# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

P1 hardening: everything the 2026-08-24 audit classified as broken today for a
consumer. No public API removals.

### Breaking changes

Four defaults changed because the old ones were unsafe or wrong. Each has a
one-line opt-out.

- **CORS is off by default.** `:cors_origin` no longer defaults to `"*"`, and
  no `access-control-allow-*` header is emitted unless you set it. Previously
  every response carried `access-control-allow-origin: *`, so a page on
  `https://evil.example` could POST to the server and *read the reply* — the
  `options _` route answered the preflight 200 and `ACAO: *` authorised the
  read. No DNS rebinding required.
  Opt out: `cors_origin: "*"`.
- **An unset `:allowed_origins` now fails closed.** A request carrying an
  `Origin` header is rejected with 403 instead of logged-and-allowed. Requests
  *without* an `Origin` still pass, so non-browser MCP clients are unaffected.
  Opt out: `allowed_origins: "*"`.
- **Cross-mode error codes are now consistent, and spec-correct.** An unknown
  tool or prompt returns `-32602` with a top-level `"Unknown tool: <name>"` /
  `"Unknown prompt: <name>"` message in all three authoring modes; a missing
  resource returns `-32002`. Previously DSL and Endpoint mode buried the real
  reason inside a `-32602 "Parameter validation failed"` payload's
  `data.errors`, manual mode returned `-32601 "Tool not found"`, and a DSL
  server whose resources were all static raised `FunctionClauseError` on an
  unknown URI and answered `-32603 "Internal server error"`. `-32601` for a
  missing resource is a spec deviation, not a contract worth preserving.
- **`tasks/*` authorization is no longer default-open, and `tasks/list` is
  bounded.** A caller with no principal used to match *every* task; it now
  matches only unowned ones. `tasks/list` accepts a client `"limit"` and clamps
  it to a server maximum (default 100, `:tasks_list_max_limit`), where it
  previously serialised the whole table into one response.
  Opt in to stricter semantics: `config :conduit_mcp, :tasks_require_owner, true`
  makes unowned tasks inaccessible too.

- **An OAuth token with no usable subject claim is now rejected with 401.**
  `sub` is optional in a JWT and absent from many client-credentials access
  tokens; accepting one produced an *authenticated* principal that every
  consumer reads as anonymous — tasks created unowned and world-readable, rate
  limiting on the shared IP bucket. The claims consulted are configurable:
  `auth: [strategy: :oauth, subject_claims: ["sub", "client_id", ...]]`
  (default `["sub", "client_id"]`).
- **`:scope` on a DSL declaration is now validated at compile time.**
  `scope ""` used to compile clean and authorize everyone, because it splits to
  `[]` and `Enum.all?([], _)` is true. `ConduitMcp.Component` already rejected
  it; both authoring modes now share one validation.
- **`resources/subscribe`, `resources/unsubscribe` and `completion/complete`
  now enforce the referenced resource's or prompt's `:scope`.** Subscribing
  delivers a resource's change notifications and completion enumerates its
  argument values, so both were readable without the scope that gates reading
  it.
- **A list passed to `:cors_origin` now raises at `init/1`** instead of raising
  `FunctionClauseError` inside the pipeline on every request. `:allowed_origins`
  is the option that takes a list.

Two smaller behaviour changes worth knowing about:

- `notifications/cancelled` is now counted by `ConduitMcp.Plugs.MessageRateLimit`
  (other notifications are still exempt). It mutates server state and is
  reachable unauthenticated.
- `[:conduit_mcp, :auth, :verify]` telemetry reports `reason: :invalid_credential`
  for a failed static-strategy verification instead of the verifier's own
  reason, which may embed the credential.

### Security

- **Bandit is pinned to a security floor of 1.12.5** (`~> 1.12 and >= 1.12.5`).
  Bandit is a non-optional dependency and is the server both transports run
  on, so consumers inherited two HTTP/2 advisories against versions the old
  `~> 1.9` admitted:
  [CVE-2026-74836](https://osv.dev/vulnerability/EEF-CVE-2026-74836) (HIGH) —
  connection-window starvation pins an unbounded number of Plug processes
  indefinitely, and a client `RST_STREAM` cannot free them because the stream
  is blocked inside a synchronous call; and
  [CVE-2026-75484](https://osv.dev/vulnerability/EEF-CVE-2026-75484) (MEDIUM) —
  HTTP/2 header values containing CR, LF or NUL reach `conn.req_headers`
  unvalidated, which the HTTP/1 path already rejected.
- **`exp` is now enforced.** `Joken.Config.default_claims(default_exp: 3600)`
  only affects token *generation*; Joken validates by folding over the claims
  the token actually carries, so a token with **no `exp` was accepted forever**.
  `exp` is now mandatory and `nbf` is enforced when present.
- **Expired and wrong-issuer tokens now report themselves.**
  `normalize_joken_error/1` matched `"expired"` against a Joken failure that
  renders as `"Invalid token"`, so expiry, wrong issuer and wrong audience all
  collapsed into `:invalid_signature` / `"Token verification failed"`. It now
  dispatches on the failed claim, so a client can tell "refresh your token"
  from "this token is forged".
- **Cancellation rows are also bounded per scope**
  (`:cancellations_max_rows_per_scope`, default 256). A global cap alone is a
  cross-tenant denial of service: one unauthenticated client filling the table
  stops every *other* client's cancellations from being recorded. The
  cancellation table is now an `ordered_set`, so the per-scope count is a
  bounded range scan.
- **`ConduitMcp.Plugs.OriginValidation`'s moduledoc no longer claims to stop
  DNS rebinding.** It does not: after a rebind the attacker's page is
  *same-origin*, and browsers send no `Origin` on a same-origin GET, so the
  header-less path applies and the allowlist never runs. What Origin validation
  does cover is the cross-origin case (a cross-origin POST always carries
  `Origin`). The control for rebinding is `Host` validation, which this library
  does not implement — the moduledoc now says so and points at the mitigations.
- **Cross-client cancellation abuse fixed (`notifications/cancelled`).** The
  cancellation table was keyed on the raw client-chosen JSON-RPC id, so
  `{"requestId": "1"}` aborted every concurrent client's request id `1` and a
  `1..1000` loop aborted every in-flight tool call on the node. Rows are now
  keyed `{scope, id}`, where scope is the session id, else the principal, else
  the client IP. Ids must be a string or integer; a `{}` returns a JSON-RPC
  error instead of a 500.
- **`:scope` is now enforced on resources and prompts, not only tools.**
  `use ConduitMcp.Component, type: :resource, scope: "admin:read"` compiled
  clean and enforced nothing. `handle_resource_read/4` and
  `handle_prompt_get/4` gained the authorization hook, scopes are collected
  from all three declaration types (URI templates included), and the DSL's
  `scope/1` now raises at compile time outside a `tool`/`resource`/`prompt`
  block.
- **`strategy: :oauth` works on `ConduitMcp.Transport.SSE`.** SSE had no
  `:oauth` branch, so it fell through to `ConduitMcp.Plugs.Auth`'s catch-all
  and returned a blanket 401 "Server configuration error" plus a
  `Logger.error` on *every* request, even with a valid token.
- **JWKS refreshes are single-flighted and rate-limited.** Every cache miss was
  an independent outbound fetch: at TTL lapse with 500 rps, 500 requests each
  blocked a Bandit process for up to 15 s against an endpoint IdPs rate-limit.
  `fetch_key/2` also refreshed on *any* unknown `kid`, before any signature
  check, so an unauthenticated caller could drive one fetch per request. Now:
  one fetch per URI at a time, a `:refresh_cooldown` (default 30 s) on
  kid-triggered refreshes, and a lock-age guard so a crashed holder cannot
  wedge refreshes.
- **The JWKS 1 MB cap is enforced while streaming.** It was applied to an
  already-buffered, already-decompressed body, so a multi-gigabyte response
  exhausted the VM before the guard ran. Responses now stream through a
  size-bounded collector with `compressed: false`, so a compression bomb can
  never be expanded in memory. The `:req` requirement is now
  `"~> 0.6.1 or ~> 0.7"` — the `0.6.1` security floor was previously only prose.
- **The SSE keep-alive loop is bounded.** It matched only
  `{:plug_conn, :sent}` with an `after` timeout, so every other message
  accumulated forever *and* was rescanned on every tick — a monotonic leak with
  O(n) per-tick cost over a long-lived connection. It now drains foreign
  messages, honours `:max_connection_lifetime` (default 1 h) and rejects past
  `:max_connections` (default 1 000) with 503.
- **Reflected client text is bounded and stripped.** New `ConduitMcp.Reflect`
  clamps length and removes control characters for every client value echoed
  into an error message or log line (method names, `protocolVersion`, `taskId`,
  cancellation reasons, auth failure reasons). A non-string `protocolVersion`
  now returns `invalid_params` instead of raising into
  "Internal server error".
- **`mix bench` no longer ships to consumers.** `package.files` packaged `lib`
  wholesale and `elixirc_paths` compiled it in `:prod`, so `Mix.Tasks.Bench`
  was installed in consumer projects, appeared in their `mix help`, and created
  a stray `bench/output/` in their repo root. It now lives in `dev/`.
- **The RFC 9728 protected-resource metadata endpoint is publicly reachable.**
  It sat behind the auth plug, so the document a client fetches *after* a 401
  to discover the authorization server required already being authenticated.
  It is now served by both transports, without auth.

### Fixed

- **A JSON array in any reflected field no longer crashes the request.**
  `ConduitMcp.Reflect.text/2` rescued only `Protocol.UndefinedError`, but
  `to_string/1` on a list raises `ArgumentError` or `UnicodeConversionError`.
  `notifications/cancelled` pipes the client's `reason` through it on a path
  with no rescue, so `"reason": [1.5]` produced a bare 500 with no JSON-RPC
  reply on either transport. Arrays are now inspected; `[1, 2]` renders as
  `"[1, 2]"` rather than being coerced to two control characters and stripped
  to `""`.
- **`Plug.Router.forward` works again with `:rate_limit`.** Resolving plugs in
  `init/1` put a *local* function capture in the router's options, and
  `forward/2` escapes those at compile time — so the Phoenix integration in the
  README failed to compile with "cannot escape #Function<…default_key_func>"
  whenever rate limiting was configured. Both rate-limit plugs now expose
  `default_key_func/1` publicly and capture it remotely.
- **The global cancellation cap no longer denies callers who are under their
  own quota.** It was checked first, so one client opening 40 sessions and
  filling each scope's 256 rows (10 240 > the 10 000 default) refused every
  *other* client's cancellations — reinstating the cross-tenant denial of
  service the per-scope quota exists to prevent. The global cap is now a memory
  backstop that reclaims the oldest rows of the largest scope instead of
  rejecting.
- **SSE `:max_connections` fails closed.** An unreadable connection counter was
  read as "no slots taken", silently disabling the cap rather than enforcing
  it.
- **A supervised ETS owner that loses its table now retries.** The degrade was
  terminal: the process idled forever owning nothing while the table's lifetime
  silently became one request's. It also reported invalid `:ets.new/2` options
  as an ownership race; those now raise.
- **`:key_provider` validation covers `fetch_key/2`.** Only `fetch_keys/1` was
  checked, but `fetch_signing_key/2` dispatches on the token's `kid` — so a
  half-implemented provider passed `init/1` and raised
  `UndefinedFunctionError` on the first token from any real JWKS-publishing
  authorization server.
- **Endpoint mode reflects unknown resource URIs safely.** Two of the three
  "Resource not found" sites still interpolated the raw URI.
- **`ConduitMcp.Validation.format_validation_errors/1` accepts what the
  validators return.** They propagate `:tool_not_found` / `:prompt_not_found`
  as bare atoms, and the function was guarded `when is_list(errors)`, so the
  documented `{:error, errs} -> format_validation_errors(errs)` raised
  `FunctionClauseError` on a name typo.
- **A struct-shaped `:current_user` is namespaced by its type.**
  `%MyApp.User{id: 42}` and `%MyApp.ApiClient{id: 42}` both derived `"42"`, and
  task ownership is an exact string compare — so the service account could read
  and cancel the human's tasks.
- **A scoped resource with no `read` handler no longer skews scope
  enforcement.** It contributed to the templated scan but not to dispatch, so
  an overlapping template could enforce one scope and run another's handler.
- **The session table survives.** `:conduit_mcp_sessions` was created lazily by
  whichever request touched it first and died with that request, so
  `Session.get/2` returned `{:error, :not_found}` for a session id the client
  had just been handed. It is now owned by a supervised
  `ConduitMcp.Session.EtsStore.Owner`, capped
  (`:sessions_max_rows`, default 100 000) and swept by a
  `ConduitMcp.Session.Janitor` started for you (disable with
  `config :conduit_mcp, :session_janitor, false`). `initialize` fails closed
  with 503 when the store is at capacity.
- **One canonical authenticated principal.** `ConduitMcp.Plugs.OAuth` assigned
  a *claims map* to `:current_user`, and ownership is an exact-match
  comparison — so a task stamped on one request never matched on the next and
  **the owner's own task 404'd**; against static auth every client sharing a
  token collapsed into one owner. Both plugs now assign
  `ConduitMcp.Principal` (`conn.assigns[:mcp_principal]`) carrying a stable
  scalar `:id`, and task ownership, per-user rate limiting and scope checks all
  read it. `:current_user` is unchanged and still yours to shape.
- **Per-user message rate limiting actually works.** Its default key read a
  shape neither auth plug assigned, so two OAuth subjects behind one proxy
  shared a bucket. It now keys on the principal.
- **A malformed `remote_ip` no longer kills the request.**
  `conn.remote_ip |> :inet.ntoa() |> to_string()` raises
  `Protocol.UndefinedError` on `{:error, :einval}`; both rate-limit plugs now
  go through `ConduitMcp.Principal.client_ip/1`.
- **`tasks/list` filters in the C layer.** It copied the whole table into the
  caller's heap and filtered in Elixir, even when the filter matched nothing.
  `:owner`, `:status` and `:limit` are now one `:ets.select/3` match spec.
- **A typo'd validation option fails the build.**
  `field(:name, :string, min_lenght: 3)` used to warn and validate *nothing*.
  It now raises, with a "did you mean" suggestion.
- **`ConduitMcp.Protocol.server_error/0` exists.** The moduledoc advertised it
  while the `defdelegate` block omitted it, so calling it raised
  `UndefinedFunctionError`.
- **`ConduitMcp.Protocol.methods/0` cannot disagree with the router.** It was a
  second, hand-maintained copy missing six routed methods
  (`resources/templates/list`, all four `tasks/*`, `notifications/cancelled`).
  It is now derived from `ConduitMcp.Handler`'s dispatch table.
- **Optional dependencies fail loudly instead of 401ing.** The
  `if Code.ensure_loaded?` guards are conditional *compilation*, frozen when
  `:conduit_mcp` was built inside your `_build` — and Mix does not rebuild an
  already-built dependency when you later add one. Configuring
  `strategy: :oauth` or a JWKS `key_provider` without the dependency now raises
  `ConduitMcp.OptionalDependencyError` at `init/1`, naming the dependency and
  `mix deps.compile conduit_mcp --force`.
- Supervision documentation now matches the actual tree (`CLAUDE.md`,
  `ConduitMcp.Server`, `ConduitMcp.Session.EtsStore`), and
  `ConduitMcp.Application` appears in the generated docs.

### Added

- `ConduitMcp.Principal` — the canonical "who is calling", with `id/1`,
  `scopes/1`, `client_ip/1` and `rate_limit_key/1`.
- `ConduitMcp.Reflect` — the boundary helper for reflected client text.
- `ConduitMcp.Transport.Shared` — the single implementation of everything the
  two transports share. No function body exists in both transports any more,
  and each plug is resolved once in `init/1` rather than on every request.
- `ConduitMcp.OptionalDeps` / `ConduitMcp.OptionalDependencyError`.
- `ConduitMcp.Plugs.OriginValidation` now honours the documented `%Regex{}` and
  bare-string `:allowed_origins` shapes, which previously hit the catch-all and
  403'd every `Origin`-bearing request.
- `ConduitMcp.Plugs.Auth` gained `:principal_id` for naming the principal
  behind a shared static credential.
- Optional-dependency table in `README.md` and prerequisites blocks in
  `guides/authentication.md` and `guides/rate_limiting.md`, both stating the
  `mix deps.compile conduit_mcp --force` requirement.
- A bare-consumer CI job (`.github/scripts/bare_consumer_check.sh`) that builds
  `:conduit_mcp` inside a project declaring **no** optional dependencies — the
  one configuration the main suite can never cover, since `optional: true` deps
  are fetched for the defining project. `publish` now gates on it.
- `ConduitMcp.EtsOwner` — the shared implementation behind all five supervised
  ETS table owners. A lost `:ets.new/2` race now logs and degrades instead of
  raising: an Owner that raised on restart took `ConduitMcp.Supervisor` — and
  with it the consumer's application — down after three attempts in five
  seconds, and a janitor tick calling `ensure_table/0` is enough to cause it.
- `ConduitMcp.Session.Janitor` gained `:telemetry_event` and `:noun`. The
  library reuses this janitor for the cancellation table, so the cancellation
  sweep now emits `[:conduit_mcp, :cancellation, :janitor]` rather than
  reporting its evictions to your `[:conduit_mcp, :session, :cleanup]` handler
  once a minute.
- `:session_janitor` and `:cancellation_janitor` accept `true` as the symmetric
  spelling of `false`, and raise a message naming the key for anything else
  instead of a `CaseClauseError` inside `Application.start/2`.
- `ConduitMcp.Tasks.list/1` accepts `limit: :infinity` — the same "unbounded"
  spelling `:tasks_max_rows` uses. It previously returned `[]`.
- `ConduitMcp.Reflect.text/2` also strips U+061C (ALM), U+2060 and U+FEFF —
  the invisible format and bidi controls outside the ranges it already covered.
- `ConduitMcp.Plugs.RateLimit.default_key_func/1` and
  `ConduitMcp.Plugs.MessageRateLimit.default_key_func/1` are public
  (`@doc false`) so the resolved plug options survive `Plug.Router.forward/2`'s
  compile-time escape.
- **Test coverage** expanded to 975 tests (up from 745), 90.2% coverage.

## [0.10.1] - 2026-08-05

Follow-up hardening from a re-review of the 0.9.4–0.9.7 changes (PRs #13–#17).

### Security

- **Owner-scoped `tasks/*` routes (IDOR/BOLA).** The experimental `tasks/get`,
  `tasks/cancel`, `tasks/result`, and `tasks/list` routes keyed purely on the
  client-supplied `taskId`, so any caller could read or cancel any task (and
  `tasks/list` returned every task system-wide). They now scope to the caller's
  principal via a new owner-aware `ConduitMcp.Tasks` API. Scoping is **opt-in and
  back-compatible**: a request with no principal, or a task created without an
  owner, behaves exactly as before; a principal mismatch returns
  `{:error, :not_found}` without leaking the task's existence. Stamp ownership
  with `ConduitMcp.Tasks.create/3` and configure principal extraction with
  `:task_owner_fun` (default `conn.assigns[:current_user]` — return a stable
  scalar such as `sub`/`id`, since ownership is checked by exact match).
- **JWKS SSRF posture and stale-key window documented** in the
  `ConduitMcp.OAuth.KeyProvider.JWKS` moduledoc: `jwks_uri` is trusted operator
  config (private/link-local addresses are still fetched, not blocked — harden
  egress if the URI is less-trusted), and during a JWKS outage cached keys keep
  validating until `:stale_max_age` (default 24h) before failing closed.

### Added

- **`ConduitMcp.Tasks` owner-scoped API** — `create/3`, `get/2`, `cancel/2`,
  `list/2`, and `owner/1`, plus the configurable `:task_owner_fun`. The
  `ConduitMcp.Tasks.Store` `@moduledoc` documents the top-level `"owner"`
  convention; reference stores promote it in `to_map/1`.
- **Named error codes** `ConduitMcp.Errors.task_not_ready/0` (`-32004`) and
  `request_cancelled/0` (`-32800`), delegated from `ConduitMcp.Protocol`,
  replacing magic literals.
- **`[:conduit_mcp, :cancellation, :cleanup]` telemetry** (measurement
  `%{removed: count}`) emitted by `ConduitMcp.Cancellation.cleanup/1`, mirroring
  the session janitor.

### Fixed

- **JWKS ETS cache could crash a concurrent request.** The cache table was
  created by whichever request first fetched keys and destroyed when that
  process exited, so a concurrent request could hit an `:ets` `ArgumentError`
  on the authentication path. The table is now owned by a supervised process
  (`ConduitMcp.OAuth.KeyProvider.JWKS.Owner`, started from
  `ConduitMcp.Application`), which also lets the cache persist across requests
  as intended. Complements the 0.10.0 fix that tolerates losing the
  check-then-create race.

### Changed

- **Example app (`examples/oban_tasks_server/`) and guide hardening** — the
  Oban exception→telemetry bridge now marks a task `"failed"` on its final
  attempt (the previous `job.state` guard never fired, since the state is
  `"executing"` at exception time); `Tasks.Store.cancel/1` updates the row
  before cancelling the Oban job (so a failed write can't strand a `"working"`
  row); client-supplied durations are validated; the Oban dep is pinned to
  `~> 2.22.0` (raw-SQL coupling to internal tables); a logger note warns that
  crash metadata can leak job args; and the `guides/oban_tasks.md` worker
  example is corrected.

## [0.10.0] - 2026-08-05

### Security

- **Patched every dependency carrying a published advisory.** Verified against
  OSV across all 47 locked packages, which now report none.

  | Package | From | To | Advisories fixed |
  |---|---|---|---|
  | `plug` | 1.19.2 | 1.20.3 | quadratic-time decoding of nested query/body params (high, CVE-2026-54892); multipart `:length` not charged for part headers, enabling unbounded temp-file creation (medium, CVE-2026-56814); cookie attribute injection in `Plug.Conn.Cookies.encode/2` (low, CVE-2026-56813) |
  | `bandit` | 1.11.1 | 1.12.4 | quadratic CPU blow-up reassembling fragmented WebSocket messages (high, CVE-2026-65623) |
  | `mint` | 1.7.1 | 1.9.3 | CONTINUATION/HEADERS flood (high); unbounded `streams` map growth via PUSH_PROMISE (high); request-line CRLF injection (low); Content-Length `+` prefix (moderate) |
  | `req` | 0.5.17 | 0.7.2 | unbounded archive/compression extraction driven by response content-type (high); multipart header injection (moderate) |

  The `plug` and `bandit` advisories are the ones that matter for a deployed
  server: both are remote denial-of-service reachable through the transports on
  any request, with no configuration required. The `mint` and `req` ones reach
  this library only through the optional JWKS key provider — where the
  decompression advisory is genuinely reachable rather than merely present, since
  `ConduitMcp.OAuth.KeyProvider.JWKS` caps the JWKS body at 1MB but Req
  decompresses before that cap applies.

  No declared constraint changed: `~> 1.19`, `~> 1.9` and `~> 0.5` all already
  permitted the patched releases, so only `mix.lock` moved. `bandit 1.12` requires
  `thousand_island ~> 1.5`, so that moved too (1.4.3 -> 1.5.0); `plug_crypto`
  (2.1.1 -> 2.2.0), `finch` (0.20.0 -> 0.23.0), `hpax` and `castore` followed as
  transitives. The JWKS moduledoc now recommends `{:req, "~> 0.6"}`.
- **JWT algorithm allow-list** — `ConduitMcp.Plugs.OAuth` now validates the
  token header `alg` against an allow-list (new `:algorithms` option,
  default: RS/ES/PS families) *before* key lookup, and requires the resolved
  signing key to match the header algorithm's family. Static `oct` keys
  implicitly allow their HS algorithms, so existing HMAC setups keep working.
  Set `:algorithms` explicitly if you rely on a non-default algorithm.
- **JWKS fetch hardening** — the JWKS key provider now requires `https`
  (override with `allow_insecure_jwks: true` for dev), no longer follows
  redirects, applies connect/receive timeouts, and caps responses at 1MB.
  A failed refresh now serves previously cached keys with a logged warning
  instead of failing.
- **WWW-Authenticate header hygiene** — config-sourced values (resource URI,
  scopes) are stripped of CR/LF/quotes before header interpolation. The SSE
  `endpoint` event URL can now be pinned with the new `:base_url` option;
  the `Host`-header fallback is sanitized.
- **Origin-validation startup warning** — transports log a warning at init
  when `:allowed_origins` is unset (DNS-rebinding exposure for
  browser-reachable servers). Pass `allowed_origins: "*"` to opt out
  explicitly.

### Changed

- **Validation `min_length`/`max_length` now count graphemes**
  (`String.length/1`) instead of bytes — multi-byte UTF-8 input is no longer
  over-counted. Behavior change for non-ASCII parameter values.
- **Custom-constraint validation reports all violations at once** instead of
  halting at the first failing parameter — clients fixing bad input no longer
  need one round-trip per error.

### Fixed

- **HS (HMAC) token verification crashed** — the OAuth plug passed the oct
  JWK map to `Joken.Signer.create/2`, which requires the raw binary secret;
  static `oct` keys now work. Malformed signing keys now yield a 401 instead
  of crashing the request process.
- **ETS table-creation races** in the JWKS cache and session store could
  crash a request under concurrent cold start; both now tolerate losing the
  check-then-create race (matching the tasks/cancellation stores).
- **Unknown JWK key types** silently fell back to RS256, masking
  misconfiguration with a confusing signature error; they are now rejected
  with a logged warning.
- **`.credo.exs` accidentally disabled nearly the whole default check suite**
  (`enabled:` replaces the suite; `extra:` adjusts it). The full suite now
  runs locally and in CI.

### Deprecated

- Leaving `:allowed_origins` unset logs a warning; a future major release
  will require an explicit Origin policy for browser-reachable transports.

### Added

- **`require_session: true`** session option for
  `ConduitMcp.Transport.StreamableHTTP` — rejects non-`initialize` POSTs
  without an `Mcp-Session-Id` header (HTTP 400), per the MCP specification.
- **`:base_url` option** for `ConduitMcp.Transport.SSE` and **`:algorithms`**
  for `ConduitMcp.Plugs.OAuth` (see Security).
- **`resources/templates/list` method** — MCP-spec-required endpoint for
  discovering URI-templated resources. Templated resources (URIs with
  `{param}` placeholders) now appear here instead of in `resources/list`.
  New optional `handle_list_resource_templates/1` Server callback.
- **`notifications/cancelled` handling** via the new
  `ConduitMcp.Cancellation` module. Tool authors poll
  `Cancellation.cancelled?(conn)` to cooperatively abort long-running
  work. Handler stashes the request id in `conn.assigns[:mcp_request_id]`
  and emits `[:conduit_mcp, :request, :cancelled]` telemetry.
- **Capability advertisement** for `completions`, `logging`, and
  `resources.subscribe` — previously these features were routed but
  never declared on `initialize`, so spec-compliant clients never used
  them.
- **Tool schema fields** `title`, `icons`, `outputSchema`, and
  `execution.taskSupport` (MCP 2025-11-25). New DSL macros: `title/1`,
  `icons/1`, `output_schema/1`, `task_support/1`.
- **Tasks JSON-RPC methods** — `tasks/get`, `tasks/cancel`,
  `tasks/result`, `tasks/list` routed to `ConduitMcp.Tasks`.
- **`task/2` DSL helper** for returning a task id from a long-running
  tool invocation.
- **`ConduitMcp.Session.Janitor`** — opt-in GenServer that periodically
  prunes expired sessions from the ETS-backed store. Add to your
  supervision tree to bound memory growth on public-facing servers.
- **`ConduitMcp.Tasks.delete/1`, `cleanup/1`, and `Tasks.Janitor`** —
  parallel cleanup for the tasks table, which previously had no
  eviction at all.
- **`ConduitMcp.Tasks.Store` behaviour** — task storage is now
  pluggable, mirroring `ConduitMcp.Session.Store`. Configure via
  `config :conduit_mcp, :tasks_store, MyApp.MyTasksStore`. The default
  remains the in-memory `ConduitMcp.Tasks.EtsStore`, so existing
  servers keep their current behaviour without any changes. Standard
  `tasks/*` JSON-RPC routes dispatch through the configured store, so
  swapping in a durable backend (e.g., Oban + SQLite or Postgres)
  requires no handler changes.
- **`examples/async_tasks_server/`** — runnable example demonstrating
  the MCP 2025-11-25 tasks lifecycle (in-memory, ETS-backed).
- **`examples/oban_tasks_server/`** — runnable example demonstrating
  the same lifecycle backed by Oban + SQLite for durability, with the
  `input_required` state exercised via `{:snooze, _}`.
- **Object parameters actually work.** `:object` params (`ConduitMcp.DSL`) and
  `:object` fields (`ConduitMcp.Component.Schema`) were dead code: every
  declaration form crashed at compile time, and the one shape that compiled was
  rejected at runtime by the validator. All forms now compile and validate —
  blockless (open) objects, block objects with declared fields, objects nested
  in objects, and `items :object` inside an `:array`.
- **Nested runtime validation.** A declared object's nested fields are now
  enforced by NimbleOptions to any depth: required fields, types, and the
  custom constraints (`enum`, `min`/`max`, length limits, `validator`). Errors
  name the full path (`bag.inner.city`). Undeclared nested keys are rejected
  with an actionable message instead of NimbleOptions' `expected atom, got:
  "zzz"`. Nested keys are atomised only when they match a *declared* field
  name, so client input can never mint an atom.
- **`additional_properties:` option** for `:object` params and fields —
  `true` enforces the declared fields and passes undeclared keys through to the
  handler; `false` (the default once fields are declared) rejects them. It also
  drives `"additionalProperties"` in the generated JSON Schema, which is now
  always emitted for objects so the published schema matches what the server
  enforces.
- **`items/1,2` in `ConduitMcp.Component.Schema`** — component-mode array
  fields had no way to declare an item type at all, and a bare `field` inside
  an `:array` block silently corrupted the parent field list. `items` is now
  the only thing an `:array` block accepts, at every nesting depth.
- **3-arg (and 2-arg) block forms** — `param :bag, :object, "desc" do ... end`
  and `field :bag, :object do ... end` used to bind to the blockless clause
  (`[do: ...]` is a keyword list), silently discarding the block; the form the
  `field/4` docs themselves showed was broken. Both now work in both DSLs. A
  block on a type that has no block form raises a `CompileError` naming the
  file and line.
- **Type coercion now follows nested objects.** A nested `:integer` field
  accepts the same `"30"` the top level does; previously coercion stopped at
  depth 0 while nested type *checking* did not, so the two disagreed.
- **The two DSL front ends now accept the same programs.** `ConduitMcp.DSL`
  silently swallowed a bare `field` inside an `:array` block, an `items` outside
  one, and a `field` outside any object block, and raised a bare
  `FunctionClauseError` for `items :string do ... end`. All four are now
  `CompileError`s naming the file and line, matching `Component.Schema`. The
  compile-time scope plumbing both DSLs share moved into one place.

### Fixed

- **DSL empty-map type warning under Elixir 1.20** — `__scope_for_tool__/1`
  in DSL-mode servers without any scoped tools used to expand to
  `Map.get(%{}, _)`, which Elixir 1.20's type checker flags as always
  returning the default. Same fix as commit `0f05a9f` for Endpoint
  mode: replace the single-map lookup with per-tool function clauses
  plus a catch-all. Servers that never declared OAuth scopes now
  compile cleanly under `--warnings-as-errors`.
- **`min:`/`max:`/`validator:` were bypassable by sending a number as a string.**
  Custom constraints are checked by this library rather than NimbleOptions, and
  the checks ran *before* type coercion — so `check_min_value/3` skipped a binary
  value, coercion then turned it into a number, and the markers had already been
  stripped from the schema NimbleOptions sees. With `type_coercion: true` (the
  default), `"5"` passed `min: 18` and the handler received `5`. `validator:`
  was worse: the function was called with the uncoerced binary, and `"5" > 18` is
  `true` in Erlang term order. Coercion now runs first, so every constraint sees
  the value the handler will see. Note `enum:` now matches after coercion too —
  `enum: [1, 2, 3]` accepts `"1"` for an `:integer` field, where it previously
  rejected it.

### Changed

- **`resources/list` now returns only static URIs.** Templated URIs
  move to `resources/templates/list` per spec. Clients that relied on
  templated URIs in `resources/list` were already non-spec-compliant.
- **`Session.Store` behaviour** gained an optional `cleanup/1` callback
  used by `Session.Janitor`. Existing stores that don't implement it
  continue to work; the janitor logs a warning and idles.
- **OAuth scope rejection** on `tools/call` now returns a JSON-RPC
  error with the request's id (previously `nil`, breaking client
  correlation).
- **Validation errors now always carry a `parameter`.** A type mismatch used to
  return `parameter: nil` and NimbleOptions' raw prose, while a missing required
  field returned the field name — so a client author had to special-case the
  failure kind to locate the field. Every error now names its parameter, dotted
  for nested fields (`bag.inner.city`). Type-error messages no longer carry
  NimbleOptions' internal `(in options [:bag])` suffix, because the parameter
  says it.
- **Undeclared parameters are rejected with a proper error.** Previously left to
  NimbleOptions, which reported no parameter name and — for a name that did not
  already exist as an atom — raised out of validation entirely, so the same
  mistake surfaced as either a validation error or an internal error depending
  on the VM's atom table. Now always
  `%{"parameter" => name, "message" => "unknown parameter \"name\""}`.

### Removed

- **Validation telemetry events** `[:conduit_mcp, :validation, :started]`,
  `[:conduit_mcp, :validation, :success]`, and
  `[:conduit_mcp, :validation, :failed]` are no longer emitted. They
  fired on every validated request (three per call, even with no
  handler attached) and were redundant with the existing
  `[:conduit_mcp, :tool, :execute]` event. Migrate attached handlers
  to `[:conduit_mcp, :tool, :execute]` whose metadata's `:status`
  field indicates `:ok` / `:error` and whose payload includes
  validation failures.
- **`custom_constraint_markers/0`** on `ConduitMcp.Validation.SchemaConverter` —
  replaced by `strip_markers/1`, which does the stripping itself and recurses
  into nested `keys:` schemas. Callers that fetched the marker list to do their
  own `Keyword.drop/2` should call `strip_markers/1` instead; four modules in
  this library did exactly that and now share the one implementation.

## [0.9.7] - 2026-06-18

### Fixed

- **`tools/call` errors crashed when the request carried `_meta`** —
  `Handler.maybe_add_meta/2` unconditionally wrote the request's `_meta` into
  `["result", "_meta"]`, but error responses (`%{"error" => ...}`) have no
  `"result"` key. With a `_meta` present (clients such as the Python MCP SDK
  send a `progressToken` on every `tools/call`), this raised
  `"could not put/update key \"_meta\" on a nil value"`, which the handler
  masked as a generic `"Internal server error"` — so every tool that returned
  an error surfaced the wrong message. `_meta` is now only merged into
  responses that have a `"result"`; error responses pass through untouched.

## [0.9.3] - 2026-04-18

### Fixed

- **Empty-map type warnings under Elixir 1.20** — endpoints with no scoped tools and/or no prompts no longer trigger `Map.get/2,3` "will always return default" warnings from `@before_compile`-generated `__scope_for_tool__/1` and `__convert_to_atom_keys__/2`. Replaced single-map lookups with per-component function clauses (`__scope_for_tool__(<<name>>) -> scope` and `__key_map__(<<name>>) -> escaped_map`) plus catch-all fallbacks. `mix compile --warnings-as-errors` is now clean for read-only / tool-only endpoints.

## [0.9.1] - 2026-03-24

### Performance

- **persistent_term validation config** — replaced `Application.get_env` with `:persistent_term.get` for O(1) lock-free config reads on every validated request (4–10% faster validation, 5–11% less memory)
- **Cached server capabilities** — new `ConduitMcp.ServerMeta` module lazily caches all `function_exported?` results in persistent_term, eliminating 9 repeated BIF calls per request (2–7% faster handler dispatch)
- **Pre-computed clean schemas** — `__validation_schema_for_tool__/1` now returns `{full_schema, clean_schema}` tuples pre-stripped of constraint markers at compile time, eliminating per-request `Keyword.drop`
- **Static resource URI dispatch** — resources with no `{param}` placeholders now generate direct pattern-match clauses (O(1)) instead of linear regex scan (O(n))

### Fixed

- **Atom table exhaustion** — `String.to_atom/1` in validation replaced with `String.to_existing_atom/1` to prevent atom table exhaustion from malicious parameter names

### Added

- `ConduitMcp.Validation.update_validation_config/1` — public API for updating validation config at runtime (writes both Application env and persistent_term)

## [0.9.0] - 2026-03-22

### Added

- **MCP Apps support** — first-class support for the [MCP Apps extension](https://modelcontextprotocol.io/docs/extensions/apps), enabling tools to return interactive UI components rendered as sandboxed iframes in host clients
  - `meta/1` macro — attach arbitrary `_meta` metadata to tool definitions (generic, future-proof)
  - `ui/1` macro — shortcut for declaring `_meta.ui.resourceUri` on a tool
  - `app/2` macro — convenience that registers both a tool (with `_meta.ui`) and its `ui://` HTML resource in one declaration
  - `raw_resource/2` helper — return raw content with a MIME type from resource handlers
  - Component mode `ui:` option — `use ConduitMcp.Component, type: :tool, ui: "ui://..."`
- **MCP Apps guide** — new HexDocs guide covering DSL, Component, and app macro usage with client-side build workflow
- **MCP Apps example** — `examples/mcp_apps_demo/` with a server health dashboard demonstrating the full tool → UI resource → iframe pattern

## [0.8.5] - 2026-03-22

### Changed

- **Removed Jason dependency** — replaced with Elixir 1.18+ built-in `JSON` module across all lib, test, and transport code (one fewer dependency)

### Performance

- **Pre-compiled URI template regex** — resource URI matching regex is now compiled once at compile time instead of rebuilt on every request (2.4x faster resource reads in DSL mode, 1.7x in Endpoint mode)
- **Single-pass constraint validation** — merged 4 separate schema traversals (enum, numeric, string length, custom) into a single `Enum.reduce_while` pass (1.6x faster)
- **Optimized marker removal** — replaced 11-iteration `Enum.reduce` with `Keyword.drop/2` (2.2x faster)
- **Single config fetch** — validation reads `Application.get_env` once per call instead of 3 times (1.3x faster)
- **O(1) schema lookup in type coercion** — replaced `Enum.find` per parameter with pre-built `Map` lookup

### Added

- **Benchee benchmark suite** (`mix bench`) with 6 benchmark files:
  - `uri_template_bench` — dynamic regex vs pre-compiled vs String.split
  - `validation_bench` — full pipeline, key conversion, constraint passes, marker removal, config lookups
  - `handler_bench` — method dispatch, `function_exported?` overhead, telemetry cost
  - `json_bench` — built-in JSON encode/decode at varying payload sizes
  - `protocol_bench` — request validation and response construction baseline
  - `full_request_bench` — DSL vs Manual vs Endpoint mode comparison
- **`mix bench` task** — run all benchmarks, run specific (`mix bench validation`), or list (`mix bench --list`)
- **HTML benchmark reports** generated in `bench/output/`

## [0.8.0] - 2026-03-22

### Added

- **Endpoint + Component mode** — third way to define MCP servers alongside DSL and Manual modes
  - `ConduitMcp.Component` behaviour for defining tools, resources, and prompts as individual modules
  - `ConduitMcp.Component.Schema` DSL (`schema do field ... end`) with automatic JSON Schema and NimbleOptions generation
  - `ConduitMcp.Endpoint` aggregator with `component` macro, declarative rate_limit/message_rate_limit/auth config
  - Auto-detected capabilities from registered component types
  - Compile-time validation (duplicate names, invalid modules, missing callbacks)
  - Atom-keyed params in `execute/2` for ergonomic pattern matching
- **`ConduitMcp.Errors` module** — centralized JSON-RPC 2.0 and MCP error code constants
  - `parse_error/0`, `invalid_request/0`, `method_not_found/0`, `invalid_params/0`, `internal_error/0`, `server_error/0`, `resource_not_found/0`
  - Replaces hardcoded magic numbers across the codebase
- **Transport auto-extraction** — StreamableHTTP and SSE transports auto-read endpoint config (name, version, rate_limit, auth) as fallback defaults
- **Handler capability detection** — `build_capabilities/1` uses `__capabilities__/0` when available for selective capability advertisement
- **6 new documentation guides** — choosing_a_mode, endpoint_mode, dsl_mode, manual_mode, authentication, rate_limiting

### Improved

- **Test coverage** expanded to 503 tests (up from 405)
- **README restructured** with all 3 server modes, responses reference, MCP spec coverage table
- **Error codes refactored** — `ConduitMcp.Protocol` now delegates to `ConduitMcp.Errors`

## [0.7.0] - 2026-03-21

### Added

- **MCP spec 2025-11-25 support** with backward compatibility for 2025-06-18
  - Protocol version negotiation in `initialize` (supports both versions)
  - `MCP-Protocol-Version` response header on all POST responses
  - `MCP-Session-Id` header with session creation and validation
- **Pluggable session store** (`ConduitMcp.Session.Store` behaviour)
  - Default ETS store included (`ConduitMcp.Session.EtsStore`)
  - Documentation for Redis, PostgreSQL, and Mnesia stores
- **Cursor-based pagination** via arity-2 list callbacks (backward compatible with arity-1)
- **Tool annotations DSL** (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`)
- **`_meta` field passthrough** for `progressToken` support
- **`listChanged` capability declarations**
- **Origin header validation** for DNS rebinding prevention
- **New handler methods**: `completion/complete`, `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe`
- **`audio/2` helper macro** for audio content type
- **`ConduitMcp.Tasks`** module for long-running operation state machine
- **`ConduitMcp.Client`** module for server-to-client requests (sampling, elicitation, roots)
- **OAuth 2.1 authentication** (`ConduitMcp.Plugs.OAuth`) with JWT validation
  - JWKS key provider with HTTP fetching (`ConduitMcp.OAuth.KeyProvider.JWKS`)
  - Static key provider (`ConduitMcp.OAuth.KeyProvider.Static`)
  - Resource metadata endpoint (`ConduitMcp.OAuth.ResourceMetadata`)
  - Tool-level scope enforcement
- **New error code** `-32002` (resource not found)
- **CI/CD pipeline** with compile, format, credo, test, dialyzer, and hex publish jobs
- **Configurable initialize response** (`server_name`, `server_version` via `conn.private`)

### Improved

- **Test coverage** expanded to 405 tests (up from 309)
- **Dependencies updated**: bandit 1.10.3, credo 1.7.17, ex_doc 0.40.1, telemetry 1.4.1
- **Handler refactored** to reduce cyclomatic complexity with extracted helper functions

### Fixed

- Version mismatch where handler returned hardcoded version instead of app version
- Hardcoded protocol version in transport (now uses `Protocol.protocol_version/0`)
- Flaky telemetry tests caused by async race conditions
- Flaky StreamableHTTP tests caused by shared ETS state in async mode
- Elixir 1.20 compilation warnings

## [0.6.5] - 2026-02-07

### Added

- **Message-level rate limiting** (`ConduitMcp.Plugs.MessageRateLimit`)
  - Second rate limiting layer that limits MCP method calls per time window
  - POST-only: GET/OPTIONS pass through automatically
  - Skips JSON-RPC notifications (no `id` field)
  - Configurable excluded methods (e.g., `["initialize", "ping"]`)
  - User-aware default key function (uses `conn.assigns[:current_user]` from Auth plug)
  - `"msg:"` key prefix prevents Hammer counter collision with HTTP rate limiter
  - HTTP 429 response with `Retry-After` header and JSON-RPC error (code `-32000`)
  - Telemetry event: `[:conduit_mcp, :message_rate_limit, :check]`
  - PromEx metrics: `message_rate_limit_check_total`, `message_rate_limit_check_duration_milliseconds`
  - Configurable via `:message_rate_limit` transport option
  - Works alongside existing HTTP-level rate limiting

### Improved

- **Test coverage** expanded to 309 tests
- **README** updated with Rate Limiting documentation (HTTP + message-level)
- **Telemetry** documentation updated with message rate limit events
- **PromEx** plugin updated with message rate limit metrics
- Applied `mix format` to all files in the codebase

## [0.5.0] - 2025-11-24

### Added

- **Resource URI parameter extraction** - Complete implementation
  - Extracts parameters from URI templates (e.g., `"user://{id}"` → `"user://123"` → `%{"id" => "123"}`)
  - Supports multiple parameters (e.g., `"user://{id}/posts/{post_id}"`)
  - Uses proper regex escaping with placeholder tokens
  - Returns `{:ok, params}` on match or `:no_match` otherwise
  - Full implementation in `extract_uri_params/2` (internal)
  - Resolves TODO from previous versions

- **PromEx plugin** for Prometheus monitoring
  - Optional integration via `{:prom_ex, "~> 1.11", optional: true}`
  - Conditional compilation (only loads if PromEx available)
  - 10 production-ready metrics (5 counters + 5 histograms)
  - Monitors all ConduitMCP operations: requests, tools, resources, prompts, auth
  - Optimized histogram buckets per operation type
  - Low cardinality design with string normalization
  - Comprehensive documentation with PromQL query examples
  - Alert rule examples included
  - Zero runtime overhead when not enabled

### Improved

- **Test coverage** expanded significantly
  - 33 new tests added (21 for core features, 12 for PromEx)
  - Resource URI parameter extraction: 11 new tests
  - Prompt functionality: 4 new tests
  - Tool functionality: 6 new tests
  - PromEx plugin: 12 new tests
  - **Total: 229 tests, all passing**

- **Documentation** enhanced
  - Added comprehensive Prometheus Metrics section to README
  - 190+ lines of PromEx plugin documentation
  - PromQL query cookbook with examples
  - Alert rule templates
  - Complete metric reference

### Fixed

- Version consistency across all files (updated from 0.4.6 to 0.4.7, now 0.5.0)
- Removed repository artifacts:
  - Deleted `erl_crash.dump` (4.9 MB)
  - Deleted `conduit_mcp-0.4.0.tar` and `conduit_mcp-0.4.6.tar`
- Updated test badge count (193 → 229 passing)

### Breaking Changes

None - This release is fully backward compatible.

## [0.4.7] - 2025-11-19

### Added
- **`raw/1` helper macro** for direct JSON output without MCP content wrapping
  - Bypasses standard MCP content structure for debugging purposes
  - Returns `{:ok, data}` directly instead of wrapped content array
  - Supports maps, strings, lists, and all data types
  - Includes comprehensive documentation with MCP compatibility warnings
  - Full test coverage with 3 test cases

### Documentation
- Updated README.md helper functions list to include `raw/1`
- Added detailed module documentation with usage examples and warnings

## [0.4.6] - 2025-01-16

### Changed
- Streamlined README and CHANGELOG for clarity
- Focused documentation on essential features
- Reduced README by 53% (634 → 298 lines)
- Reduced CHANGELOG by 48% (190 → 99 lines)

### Improved
- README now highlights DSL as primary approach
- Removed outdated migration guides
- Cleaner examples and better organization
- Added version and test badges

## [0.4.5] - 2025-01-16

### Added
- **Clean DSL for defining MCP servers**
  - `tool`, `prompt`, `resource` macros for declarative definitions
  - Automatic JSON Schema generation from parameters
  - Helper functions: `text()`, `json()`, `error()`, `system()`, `user()`, `assistant()`
  - Support for inline functions, MFA handlers, and function captures
  - Parameter features: enums, defaults, required fields, type validation
- **Flexible authentication system**
  - `ConduitMcp.Plugs.Auth` with 5 strategies
  - Bearer token, API key, custom function, MFA, database lookup
  - CORS preflight bypass, configurable assign key
  - Case-insensitive bearer token support
- **Extended telemetry**
  - `[:conduit_mcp, :resource, :read]` - Resource operations
  - `[:conduit_mcp, :prompt, :get]` - Prompt operations
  - `[:conduit_mcp, :auth, :verify]` - Authentication
  - Complete observability for all MCP operations

### Changed
- Examples updated to use DSL (simple_tools_server, phoenix_mcp)
- Transport modules support `:auth` option
- Auth configured per-transport (no separate pipeline needed)
- Documentation streamlined to focus on DSL

### Tests
- 36 DSL tests (tools, prompts, resources, helpers, schema builder)
- 26 auth plug tests (all strategies, error handling, CORS)
- 16 telemetry tests
- 193 total tests, all passing

## [0.4.0] - 2025-01-16

### Changed (Breaking)
- **Pure stateless architecture**
  - Removed GenServer and Agent - zero process overhead
  - Server is just a module with pure functions
  - No supervision tree required
  - Maximum concurrency (limited only by Bandit)
- **Simplified callback API**
  - Removed `mcp_init/1`
  - Changed `{:reply, result, state}` → `{:ok, result}`
  - Callbacks receive `conn` (Plug.Conn) as first parameter
  - No more state passing/returning
  - Error maps use string keys
- **Handler updates**
  - Calls module functions directly (no GenServer.call)
  - Transport layers pass Plug.Conn for request context

### Performance
- Zero process overhead - pure function calls
- Full concurrent request processing
- No serialization bottleneck

## [0.3.0] - 2025-10-28

### Added
- Comprehensive test suite (109 tests, 82% coverage)
- Test infrastructure (TestServer, TelemetryTestHelper)
- ExCoveralls integration

### Changed
- Simplified and professionalized README

## [0.2.0] - 2025-10-09

### Added
- Telemetry events (`[:conduit_mcp, :request, :stop]`, `[:conduit_mcp, :tool, :execute]`)
- Configurable CORS headers
- Enhanced logging

### Fixed
- SSE buffering with nginx proxies

## [0.1.0] - 2025-10-08

### Added
- Initial release
- MCP specification 2025-06-18 implementation
- `ConduitMcp.Server` behaviour
- StreamableHTTP and SSE transports
- Tools, resources, and prompts support
- Basic authentication
- Phoenix integration example

[Unreleased]: https://github.com/nyo16/conduit_mcp/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/nyo16/conduit_mcp/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/nyo16/conduit_mcp/compare/v0.9.7...v0.10.0
[0.9.7]: https://github.com/nyo16/conduit_mcp/compare/v0.9.6...v0.9.7
[0.8.5]: https://github.com/nyo16/conduit_mcp/compare/v0.8.0...v0.8.5
[0.8.0]: https://github.com/nyo16/conduit_mcp/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/nyo16/conduit_mcp/compare/v0.6.5...v0.7.0
[0.6.5]: https://github.com/nyo16/conduit_mcp/compare/v0.5.0...v0.6.5
[0.4.6]: https://github.com/nyo16/conduit_mcp/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/nyo16/conduit_mcp/compare/v0.4.0...v0.4.5
[0.4.0]: https://github.com/nyo16/conduit_mcp/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/nyo16/conduit_mcp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nyo16/conduit_mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nyo16/conduit_mcp/releases/tag/v0.1.0

# Security review: P1 post-merge fixes (`git diff HEAD`)

Scope: the auth/authz/DoS surfaces in the assignment. Read-only. This agent has no shell, so nothing was
executed. **VERIFIED** means traced clause by clause through the source cited. **INFERRED** means it depends
on runtime behaviour I could not probe.

| Severity | Count |
|---|---|
| BLOCKER | 0 |
| WARNING | 2 |
| SUGGESTION | 7 |
| PERSISTENT (from round 3) | 0 |

Every round-3 security finding (W1–W4, S1–S7) is addressed by this diff. S1 and S2 are the subject of G6-S1
and G6-S2; W1 below is a gap in the G6-S2 fix.

**Fix verdicts (target list):**

| Item | Verdict |
|---|---|
| B1 | correct |
| W3 | correct: no dispatch/scope mismatch found (S7) |
| W4 | correct for the warm-cache path (S1, S2 on the edges) |
| W5 | correct; one comment is false under concurrency (S3) |
| W6 | correct |
| G4 | correct |
| G5-S6 | correct; its telemetry emit is W2 |
| G5-S7 | correct (S6 edge) |
| G6-S1 | correct |
| G6-S2 | **incomplete** (W1) |
| G6-S6 | correct and exhaustive today (S5) |

---

## WARNING

### W1. The G6-S2 `:principal_id` guard keys on the strategy name, but the verifier is what makes identities per-user. The default strategy with `verify:` still merges every user into one principal
**File**: `lib/conduit_mcp/plugs/auth.ex:127-135` (`init/1` guard), `:286-315` (`do_verify/2`), `:264-270` (`build_principal/3`)
**Status**: VERIFIED (clause trace)

`init/1` raises only when `strategy in [:function, :custom]`. `do_verify/2` does not dispatch on the strategy
name. It dispatches on which keys are set:

```elixir
defp do_verify(credential, %{strategy: :bearer_token, token: expected_token})
     when not is_nil(expected_token) do ...           # static only when :token is set
defp do_verify(credential, %{strategy: :api_key, api_key: expected_key})
     when not is_nil(expected_key) do ...             # static only when :api_key is set
defp do_verify(credential, %{verify: verify_fn}) when is_function(verify_fn, 1) do
  verify_fn.(credential)                              # any strategy with :verify lands here
```

`strategy` defaults to `:bearer_token` (`auth.ex:127`). Take either of these configs:

- `auth: [verify: &MyApp.verify/1, principal_id: "svc"]`
- `auth: [strategy: :api_key, header: "x-api-key", verify: &MyApp.lookup_key/1, principal_id: "svc"]`

Both pass `init/1`, because the strategy is `:bearer_token` / `:api_key`. At request time
`call/2` extracts the credential, the first two `do_verify` clauses fail their `not is_nil` guard, and the
per-user verifier runs. Then `build_principal/3` evaluates
`opts.principal_id || Principal.derive_id(user) || credential_id(credential)`, and `"svc"` wins for every
user.

The result is exactly what G6-S2 set out to prevent: shared task ownership (read, cancel and fetch results of
each other's tasks), one shared rate-limit bucket, and one cancellation scope (`"principal:svc"`). The
`:api_key` + verifier pattern (per-user API keys looked up in a DB) is a natural one. The moduledoc (`:25-31`)
says ":principal_id is for the static `:bearer_token` / `:api_key` strategies", which invites setting it there.

**Recommendation**: guard on the thing that decides the verification path. Allow `:principal_id` only when
the static secret for the strategy is configured:

```elixir
static? =
  (strategy == :bearer_token and Keyword.get(opts, :token) != nil) or
    (strategy == :api_key and Keyword.get(opts, :api_key) != nil)

if principal_id != nil and not static?, do: raise ArgumentError, ...
```

Update the moduledoc sentence to say "requires `:token` / `:api_key`". Add `auth_test.exs` cases for both
configs above: init raises, or a verifier returning two different users yields two different
`Principal.id/1` values.

### W2. G5-S6 makes a non-binary `uri` reach `[:conduit_mcp, :resource, :read]` telemetry on every server. The library's own default handler then raises and `:telemetry` detaches it for all events
**File**: `lib/conduit_mcp/handler.ex:459-492` (`handle_resource_read/4` emits `uri: uri` unconditionally at
`:486`); `lib/conduit_mcp/telemetry.ex:546-553` (the default `handle_event/4` for `:resource, :read` does
`"Resource read: uri=#{metadata.uri} ..."`); `telemetry.ex:91` documents `:uri (String.t)`.
**Status**: code path VERIFIED; the handler detach is INFERRED from `:telemetry`'s documented behaviour and
`Logger` macros evaluating their message only when the level is enabled (not probed).

Before the diff, on a scoped templated server, `"uri": {}` raised inside the scope lookup. `handler.ex:201`
rescued the raise, and the resource telemetry never fired. Now `authorize_resource/3` returns
`{:error, :invalid_uri}`, the function carries on, and it emits `%{uri: %{}}`.

`ConduitMcp.Telemetry.attach_default_handlers/0` attaches one handler id (`"conduit-mcp-default-logger"`)
to every event. When `:debug` is enabled (the dev default), `"#{%{}}"` raises `Protocol.UndefinedError` inside
the handler. `:telemetry` then detaches that handler id, which covers all its events. One request
(`{"method":"resources/read","params":{"uri":{}}}`, unauthenticated if `:auth` is unset) silently turns off
the operator's request/tool/resource logging. Operator handlers written against the documented `String.t`
fail the same way.

This diff adds a new instance of an existing problem. The same class already exists (INFERRED) for
`tools/call` with a non-binary `name`: `handle_tool_call/4` emits `tool_name: tool_name` on the
unknown-tool path (`handler.ex:437-446`).

**Recommendation**:
- In `handle_resource_read/4`, emit `uri` only when it is a binary (`uri: if(is_binary(uri), do: uri)`) or as
  `Reflect.text(uri)`, and document `String.t() | nil`.
- Make the default handlers render client-sourced metadata (`uri`, `tool_name`, `prompt_name`, `method`) with
  `Reflect.text/2` instead of raw interpolation. That also closes the siblings and the log-forging (`\n` in a
  uri string) they allow.

---

## SUGGESTION

### S1. JWKS: a cold cache with a failing IdP still makes one outbound fetch per request (serialised), and past `:stale_max_age` every request inside the cooldown logs at `:error`
**File**: `lib/conduit_mcp/oauth/key_provider/jwks.ex:157-169` (`fetch_on_miss/2`, branch 3), `:453-476` (`serve_stale/4`)
**Status**: VERIFIED (trace)

Checked, and correct:
- A warm row inside the cooldown now takes `serve_stale(..., :cooldown)`.
- `serve_stale/4` still enforces `:stale_max_age` on every path: fetch_on_miss branch 2, `refresh_keys/1` and
  `await_refresh/3`. Cooldown cannot pin keys past it.
- An invented `kid` during the cooldown gives `fetch_keys` → fresh → `find_key` nil → `refresh_keys` →
  cooldown → `serve_stale(:not_found, :cooldown)` → the same keys → nil → `{:error, :not_found}` →
  `:key_not_found`. It logs at debug only.
- The lock is checked before the cooldown. The winner writes `:last_refresh` before its fetch, so waiters
  still wait.

Remaining amplification:

1. **Cold cache** (boot while the IdP is down, or a node whose first fetch failed). With no row, branch 3
   always runs `fetch_and_cache/2`. The lock serialises the fetches but does not space them. After each
   failed fetch releases the lock, the next request fetches again. Unauthenticated requests with any
   well-formed JWT header (the fetch runs before the signature check, and `authenticate` runs before
   `rate_limit`) therefore drive back-to-back IdP requests at up to 1/RTT. That is the "IdPs rate-limit JWKS
   endpoints" failure the moduledoc cites. This is documented ("A cold cache ... always fetches"). But
   nothing is served from a cold cache anyway, so a cooldown there costs only 401s that are already
   happening.

   **Fix**: when there is no row and `cooling_down?/2` is true, return `{:error, :refresh_cooldown}`
   (perhaps with a shorter cold cooldown, for example 1–5 s).
2. **Past `:stale_max_age`** the cooldown branch calls `serve_stale/4`, which logs
   `Logger.error("JWKS refresh failed and cached keys ... exceed stale_max_age; failing closed")` on every
   request. It also returns the misleading reason `:refresh_cooldown` (or `:not_found` from `refresh_keys/1`,
   which telemetry maps to `:key_not_found`). G6-S4 quietened only the within-`stale_max_age` case. This is an
   unauthenticated, error-level log flood during a long IdP outage. It is better than before the diff, when
   every such request also fetched.

   **Fix**: honour `context == :cooldown` in the fail-closed branch too (debug, or once per window).

### S2. JWKS `refresh_keys/1` checks the cooldown before the lock, the very ordering `fetch_on_miss/2`'s new comment calls a bug
**File**: `jwks.ex:195-208`
**Status**: VERIFIED (trace); the ordering is pre-existing but now contradicts the invariant stated at `:141-156`.

During a key rotation, tokens carrying the new `kid` that arrive while a winner's refresh is in flight see
`cooling_down? == true`, because the winner wrote `:last_refresh` first. They are served the old set and get a
401 `:key_not_found` instead of waiting for the publish. This is availability only, limited to the fetch window.

**Fix**: in `refresh_keys/1`, check `:ets.member(@table, {:refresh_lock, jwks_uri})` first and route to
`fetch_and_cache/2` (which awaits), as `fetch_on_miss/2` does.

### S3. `Cancellation.reclaim/0`: concurrent reclaims pick the same rows, so "frees more rows than needed, never fewer" is false
**File**: `lib/conduit_mcp/cancellation.ex:336-362`
**Status**: INFERRED

W5 is correct single-threaded:
- The sort key `{-count, at}` gives the largest scope first, then oldest first.
- A full batch is freed even with 1-row scopes.
- The cost is O(n log n) per batch = amortised O(20 log n) per insert.

The comment's last sentence does not hold. Callers that pass `at_capacity?/0` together each take a snapshot,
sort it identically and delete **the same** `batch` keys. k racers therefore do k full scans and free about one
batch. Under an unauthenticated flood, k equals the arrivals during one scan (a few ms at n = 10 000), so the
per-insert cost at the cap is roughly k× the documented amortisation. It stays bounded, because arrivals after
the first delete see the table below the cap, so this is not a blocker.

**Fix**: correct the comment. Optionally single-flight `reclaim/0` with an `:ets.insert_new` lock row (the JWKS
pattern). Losers skip the reclaim and insert, since the global cap is only a memory backstop.

### S4. SSE: at the cap, every rejected `GET /sse` pays a full O(`max_connections`) sweep
**File**: `lib/conduit_mcp/transport/sse.ex:300-326` (`__acquire_slot__/2`, `sweep_dead_slots/1`)
**Status**: VERIFIED (trace)

B1 is correct:
- insert-then-count never over-admits;
- the sweep deletes only dead pids, so a racing live acquirer's row is never removed;
- the reject path deletes its own row;
- `release_connection_slot/0` is idempotent;
- the rescue fails closed;
- dead rows below the cap are bounded, because the table never exceeds `max` + in-flight acquirers.

I found no way for a client to hold a slot without a live stream process. Each slot is bounded by
`:max_connection_lifetime` as before.

The remaining concern: once live streams have reached the cap, each further `GET /sse` (with the right
`Accept` header) runs a `select` of up to `max` pids plus `Process.alive?/1` on each. That is 1 000 by default,
repeated per rejected request. Auth runs first, so an attacker needs a credential or an unauthenticated
server. The cost is tens of µs per request, which is cheap but attacker-driven.

**Fix (optional)**: skip the sweep when the last sweep (a timestamp row) was under ~1 s ago and found nothing
dead.

### S5. OAuth `telemetry_reason/1` has no catch-all
**File**: `lib/conduit_mcp/plugs/oauth.ex:520-525`
**Status**: VERIFIED exhaustive today

Every `{:error, reason}` that reaches the catch-all in `verify_token/3` is mapped:
- `peek_header` → `{:invalid_token, _}` / `:invalid_token_format`
- `check_alg_allowed` → `{:alg_not_allowed, _}` / `:missing_alg`
- `fetch_signing_key` → `{:key_unavailable, _}`
- `resolve_signer_alg` / `create_signer` → `:alg_mismatch` / `:unsupported_key_type` / `:invalid_key` /
  `{:invalid_key, _}`
- `normalize_joken_error` → atoms in the set

No header or provider text reaches telemetry metadata. The log line goes through `Reflect.text/2`, and tuples
fall back to `inspect(limit: 10, printable_limit: 256)`, so an 8 KB `alg` is clamped.

The weak spot is future-proofing: a reason added later raises `FunctionClauseError`, a 500 instead of a 401.
It fails closed, but it is noisy.

**Fix**: a final `defp telemetry_reason(_), do: :invalid_signature` (or a documented `:other`), and a test that
asserts every emitted reason is in `@telemetry_reasons`.

### S6. `Cancellation.scope/1` now raises if a principal id is not a binary
**File**: `cancellation.ex:143-148`; called from `handler.ex:135` in the `after` of every request with an id
**Status**: INFERRED (needs an app that bypasses `Principal.put/2`)

`"principal:" <> principal_id` raises `ArgumentError` for a non-binary. `Principal.put/2` normalises ids, so
both built-in plugs are safe. But `Principal.id/1` reads `conn.assigns[:mcp_principal]` unchecked. A custom
auth plug that does `assign(conn, :mcp_principal, %{id: user.id})` with an integer id now crashes every request
in the `after` block, which is a bare 500. Before G5-S7 the id was used raw, so this is new.

**Fix**: `principal_id when is_binary(principal_id) <- Principal.id(conn)` in `scope/1`, or make
`Principal.id/1` run `derive_id/1` on read.

### S7. Endpoint scope scan and dispatch both depend on the runtime atom table via `atomize_uri_params/1`
**File**: `lib/conduit_mcp/endpoint.ex:372-398` (dispatch), `:421-425` (`atomize_uri_params/1`); `dsl.ex:1551-1580` (`:atomize` scan)
**Status**: INFERRED, theoretical

W3's mirror is correct: the same regex, the same `extract_uri_params_compiled/3`, the same atomize, and
first-match-wins in both. I could not build a declaration order that dispatches one handler and checks
another's scope. I tried:
- an unscoped static URI before and after a scoped template (static `nil` clause emitted, and dispatch's static
  clause precedes the template chain);
- an unscoped template before a scoped one (`{:scope, nil}` wrapping stops the scan);
- handler-less DSL resources (excluded from both via `readable_resources/1`, which filters before `uniq_by`);
- duplicate URIs (DSL and Endpoint both de-duplicate first-wins before building dispatch and scope);
- `app/2` UI resources (they inherit the tool's scope);
- a template-looking static URI (the `String.contains?(uri, "{")` split is identical in
  `SchemaBuilder.templated?/1`, Endpoint `generate_resource_clause/1` and `generate_resource_scope_clauses/2`);
- the scope shortcut when only static resources are scoped (every template answers `nil` in both);
- a trailing-newline URI (`^...$` matches `user://me\n` into the template on both sides).

The one theoretical gap: `String.to_existing_atom/1` is evaluated twice, once per lookup. If a template param
name's atom first comes into existence between the scope check and dispatch, the check can skip a scoped
template that dispatch then runs. The atom could appear through lazy module loading in interactive mode,
never from client input.

**Fix**: param names are compile-time literals, so compute atomizability per template at compile time and drop
the runtime dependency.

---

## Checked, no finding

- **G6-S1** (`principal.ex:168-187`): `true` / `false` / `:ok` → `nil` → credential digest; structs are still
  namespaced, and `%{id: true}` → digest. A constant non-marker return (`{:ok, :valid}`, `{:ok, "ok"}`) still
  merges callers. That is inherent (a constant carries no identity), and the docs describe the accepted shapes.
- **G6-S2**: `init/1` runs at boot through `Shared.resolve_auth_plug/1`, so the raise is a configuration error
  (including under `Plug.Router.forward`), not a per-request one. W1 covers what it misses.
- **G6-S6**: see S5. The moduledoc table matches `@telemetry_reasons` exactly (14 atoms).
- **G5-S6**: `is_binary/1` gating is in place on `resources/read`, `subscribe` and `unsubscribe`
  (`authorize_resource/3`, `handler.ex:591-594`) and on `completion/complete` `ref.uri`
  (`validate_completion_ref/1`). Echoed values go through `Reflect.text(_, 40)`. A `ref/resource` completion
  carrying a template URI (`user://{id}`) matches that template's own regex, so it is checked against the
  right scope.
- **G5-S7**: `"session:"` / `"principal:"` / `"ip:"` are fixed and distinct, and cannot alias each other or
  `"global"`.
- **W6**: `is_list/1` is applied identically in `validate_session/2` and `create_session_for_initialize/2`.
  With `nil` / `false` / `true` no row is created. Cancellation scoping never used implicit sessions (the session
  id was only put into private when configured), so W6 weakens no isolation.
- **G4**: `validate_allowed_origins!/1` runs in `Shared.init/2`, rejects a Regex inside a list, and accepts
  `"*"`. The standalone plug fails closed on unknown shapes. The anchored example
  `~r/\Ahttps:\/\/example\.com\z/` is correct and appears in the plug and both transport docs.
- **W4 lock ordering**: `fetch_on_miss/2` checks the lock first, then the cooldown with a row, then fetches.
  Only one extra fetch per lock release is possible (the `:ets.member` → `insert_new` window). That is
  negligible.

## Pre-existing (not introduced by this diff)

- `cancellation.ex:168-190` (`cancel/3`): the `requestId` length is unbounded (only the 1 MB body cap applies).
  The per-scope quota bounds rows, not bytes: 256 × ~1 MB ≈ 256 MB per scope, and the 10 000-row cap ≈ 10 GB.
  IPv6 callers get a fresh `"ip:"` scope per address (/64 = unlimited scopes). Consider clamping ids (e.g.
  ≤ 256 bytes → `:invalid_request_id`) and aggregating IPv6 to /64. Worth promoting.
- `plugs/message_rate_limit.ex:193`: `"method=#{method}"` interpolates raw client JSON. A map `method` raises
  (500 instead of 429), and `\n` forges log lines. Use `Reflect.text/2`.
- `plugs/origin_validation.ex:96`: the raw `Origin` header goes into `Logger` metadata unclamped.
- `transport/sse.ex:95,293`: `:max_connections` is not validated. A non-integer (`"10"`, `:infinity`) compares
  greater than any count in term order, which silently disables the cap.
- `transport/sse.ex:354-363`: when the Owner is degraded, the fallback table is owned by a stream process.
  When that process exits, every live slot row is lost, so the cap can be exceeded.
- `transport/streamable_http.ex:140-150`: a session is not bound to the principal that created it. A known
  session id also selects that session's cancellation scope (session outranks principal in
  `Cancellation.scope/1`).
- `plugs/auth.ex:277-280`: `"static:<digest>"` is an unsalted, fast SHA-256 prefix. It appears in the
  rate-limit log/telemetry `key` and in cancellation telemetry `scope`, so a low-entropy static token (for
  example the README's `"my-secret-token"`) can be dictionary-reversed by anyone with metrics access.

## Tools to run manually

`mix sobelow --exit medium` (already green per the plan), `mix deps.audit`, `mix hex.audit`.

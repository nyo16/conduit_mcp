# P1 — Correctness & Security (target: v0.10.2)

**Source:** `.claude/audit/summaries/consolidated.md` (audit 2026-08-24, 50 findings / 15 root causes)
**Scope:** everything the audit classified as **broken today for a consumer**. No public API removals.
**Baseline to preserve:** compile `--warnings-as-errors` clean · format clean · `credo --strict` clean · dialyzer 0 · sobelow clean · 745 tests / 1.4s · coverage 87.3%

## Why this split

P1 is the "already broken" set. P2 (`hardening-p2-structural`) is refactoring with no behaviour change. P3 (`hardening-p3-performance`) is allocation and dependency hygiene. Splitting keeps a security patch reviewable — a 9-function transport refactor does not belong in the same diff as an auth fix.

## Sequencing constraints (do not reorder)

1. **Phase 0 before everything.** `TelemetryTestHelper` forwards *any* process's events into `assert_receive`, so every telemetry assertion in this plan is untrustworthy until it is fixed. The bare-consumer CI job is also the only thing that can *prove* RC1 fixed.
2. **RC2's owner and cap are one commit.** Adding the supervised owner without the row cap converts today's accidental self-clearing churn into a permanent unbounded leak — strictly worse than the bug.
3. **RC7 before RC8.** `Tasks.default_owner/1` cannot be made correct until a canonical principal exists to read.
4. **RC5's two edits ship together.** Requiring `exp` reaches the existing `:expired` clause; fixing the normalizer is what makes *genuinely* expired tokens report `:expired`. Either alone leaves a wrong client-visible answer.

---

## Phase 0 — Verification foundation

Nothing else can be trusted until these land.

- [x] **T-H1 — fix `TelemetryTestHelper`'s global handler leak.**
  `test/support/telemetry_test.ex:20-37` calls `:telemetry.attach/4` with a closure that `send`s to `pid` tagged with `ref`, but `ref` identifies the *handler*, not the *emitter* — so while attached, every emission of that event name from any concurrent test is forwarded. Proven: a `Task`-emitted event landed in the attaching test's mailbox.
  **Change:** capture `self()` at attach time and forward only when the emitting process matches, or thread a unique correlation value through the emitted metadata and filter on it. Keep the `:telemetry.attach/4` return value and assert it is `:ok`.
  **Acceptance:** a test that emits the same event name from a separate `Task` while attached does **not** receive it. The three affected `async: true` modules (`plugs/rate_limit_test.exs:166-174`, `plugs/message_rate_limit_test.exs:209`/`:334`/`:349`, `handler_test.exs:411`/`:435`/`:459`) still pass.

  **Done:** capture `self()` at attach; forward only same-process emissions. New test/conduit_mcp/telemetry_test_helper_test.exs proves a Task-emitted event is not forwarded.
- [x] **T-L5 — suite hygiene, four one-line fixes.**
  `test/test_helper.exs:1-4` calls `ExUnit.start()` with no options, so every `assert_receive` without an explicit timeout uses the 100 ms default — the tightest window in the suite, relied on by ~20 call sites. `ConduitMcp.TestRateLimiter.start_link/1`'s return value is discarded and it runs before `ExUnit.start()`, unsupervised, so a failure surfaces as opaque `:noproc`. `coveralls.json:2` sets `minimum_coverage: 78` against an actual 87.3% — a 9.3-point ratchet gap.
  **Change:** `ExUnit.start(assert_receive_timeout: 500)`; match on `{:ok, _}` from `TestRateLimiter.start_link/1`; raise `minimum_coverage` to 86.
  **Acceptance:** suite passes; deliberately dropping coverage by 2 points fails the gate.

  **Done:** `ExUnit.start(assert_receive_timeout: 500)`; `{:ok, _pid} =` on TestRateLimiter; coveralls minimum_coverage 86 (actual 89.8%).
- [x] **RC1a — add the bare-consumer CI job.**
  `optional: true` deps are fetched and compiled *for the defining project*, so every `Code.ensure_loaded?` guard evaluates `true` in this suite and the absent-dep build is the one configuration CI never builds (`mix.exs:56-66`, `.github/workflows/ci.yml:93-128`). `publish` gates only on that suite (`ci.yml:229`). `test/conduit_mcp/prom_ex_test.exs:166-170` asserts `refute Code.ensure_loaded?(ConduitMcp.PromEx)` — dead by construction.
  **Change:** new CI job that generates a throwaway consumer project depending only on `conduit_mcp` (no optional deps), compiles it, and asserts the guarded modules are absent *and* that configuring `strategy: :oauth` raises an actionable error rather than 401ing. Add `publish.needs` on it. Delete or rewrite the dead assertion in `prom_ex_test.exs:166-170`.
  **Acceptance:** the job fails against current `main` for the `strategy: :oauth` case and passes after RC1b.

  **Done:** .github/scripts/bare_consumer_check.sh + `bare_consumer` CI job; `publish.needs` extended. Verified failing against HEAD (init/1 accepted `:oauth`, every request 401 'Server configuration error') and passing after RC1b. Dead prom_ex assertion removed.
---

## Phase 1 — Consumer-breaking defects

- [x] **RC1b — validate optional-dep availability at `init/1`.**
  Whole-module `if Code.ensure_loaded?` guards at `plugs/oauth.ex:1`, `oauth/key_provider/jwks.ex:1`, `prom_ex.ex:1` are conditional *compilation* and freeze when conduit_mcp compiles inside the consumer's `_build`. Mix does not rebuild an already-built dep when the consumer later adds one. Proven in a 3-stage consumer project: `false/false` → still `false/false` after adding joken+req → `true/true` only after `mix deps.compile conduit_mcp --force`. Symptoms: `strategy: :oauth` falls through `transport/streamable_http.ex:116-118` to the `Plugs.Auth` catch-all (`plugs/auth.ex:164-167`) returning a blanket 401 per request; a JWKS `key_provider` becomes `UndefinedFunctionError` because `init/1` accepts any atom (`plugs/oauth.ex:63-68`) and dispatch is unguarded (`:190`, `:192`); `ConduitMcp.PromEx` in a plugin list is a supervision-boot crash; `application.ex:49-54` silently skips `JWKS.Owner`.
  **Change:** validate at `init/1` — the one point every affected path crosses. In `plugs/oauth.ex:63-68`, `Code.ensure_loaded?/1` + `function_exported?(mod, :fetch_keys, 1)` on `key_provider`. In both transports' `init/1`, resolve `strategy: :oauth` and raise if unavailable, replacing the compile-time-only fallback at `streamable_http.ex:108`. Error message must name the dep **and** `mix deps.compile conduit_mcp --force`.
  **Acceptance:** Phase 0's CI job passes. A consumer with joken installed but stale build gets a raise naming the remedy, not a 401.

  **Done:** New ConduitMcp.OptionalDeps + ConduitMcp.OptionalDependencyError; `validate_key_provider!/1` in Plugs.OAuth.init/1; both transports resolve `strategy: :oauth` in init/1 via Transport.Shared.
- [x] **RC1c — document optional dependencies.**
  A case-insensitive grep for `joken|jose|hammer|prom_ex|{:req` across `README.md` (install block `:28-35`) and all nine `guides/` files returns **zero matches**, while `guides/authentication.md:69-111` walks the consumer straight into `strategy: :oauth` + the JWKS provider. Install instructions exist only in the `@moduledoc` of modules that do not exist until the dep is installed (`plugs/oauth.ex:15-30`, `jwks.ex:50-58`, `prom_ex.ex:15-22`, `rate_limit.ex:13-14`) — a catch-22.
  **Change:** optional-dependency table in `README.md` (feature → dep → mix line) and a prerequisites block at the head of `guides/authentication.md` and `guides/rate_limiting.md`, both stating the `mix deps.compile conduit_mcp --force` requirement.
  **Acceptance:** every optional dep reachable from `README.md` without reading source.

  **Done:** Optional-dependency table in README.md; prerequisites blocks in guides/authentication.md and guides/rate_limiting.md, both naming `mix deps.compile conduit_mcp --force`.
- [x] **RC2 — supervise, cap, and sweep the session table (ONE commit).**
  `session/ets_store.ex:50-53` lazily creates `:conduit_mcp_sessions` from whichever process calls first; `application.ex:31` registers only `Cancellation.Owner`. Sessions are the one ETS subsystem of four with no supervised Owner — `tasks/ets_store.ex:174-202`, `cancellation.ex:165-191`, `jwks.ex:255-291` all have one, and `application.ex:44-48` documents the exact hazard being guarded elsewhere. Proven by `mix run`: `:undefined` after the creating process exits, lookup `{:error, :not_found}`, while the supervised cancellation table survived. The `rescue ArgumentError` at `:58` covers only the create race, not an operation against a vanished table, and `create/2`'s `:ets.insert` at `:70` sits outside it (coveralls: `:58` never hit). Sessions are created **by default** (`streamable_http.ex:327-331`; only an explicit `false` disables), and `initialize` is reachable with no session header by design (`:173-174`), so an unauthenticated client mints rows at request rate. No cap and no janitor — `Tasks.EtsStore` protects itself with `@default_max_rows 10_000` + `at_capacity?/0` (`tasks/ets_store.ex:28`, `:43`) against the identical threat; `Session.Janitor` must be hand-wired (`session/janitor.ex:17-23`), absent from `application.ex:56`.
  **Change:** add `Session.EtsStore.Owner` (Agent, `read_concurrency: true, write_concurrency: :auto`), a `@default_max_rows` cap enforced in `create/2`, and register both plus `{Session.Janitor, store: Session.EtsStore}` in `application.ex:31`.
  **Acceptance:** a test that kills the process which first touched the table then reads a session created before the kill still finds it. Creating past the cap returns an error rather than growing. `mix run` probe from the audit now reports the table alive.

  **Done:** Session.EtsStore.Owner (Agent, read_concurrency + write_concurrency: :auto); `:sessions_max_rows` cap (default 100_000); Owner + Session.Janitor registered in application.ex under distinct child ids. `initialize` fails closed with 503 at capacity.
- [x] **RC2b — correct the supervision doc drift.**
  `CLAUDE.md:31` ("No supervised processes") and `server.ex:11-13` ("No supervision tree required") are contradicted by `mix.exs:43` and `application.ex:56-61`. `session/ets_store.ex:8-10` claims lazy creation works "without explicit application start-up wiring" — disproven above. ArchAudit names the stale claim as the reason the session owner was never added. `ConduitMcp.Application` is also absent from every `groups_for_modules` entry (`mix.exs:143-205`).
  **Acceptance:** all three sites describe the actual tree; `ConduitMcp.Application` appears in a docs group.

  **Done:** CLAUDE.md:31, server.ex and session/ets_store.ex now describe the real tree; ConduitMcp.Application added to the Core docs group.
- [x] **RC10 — stop shipping `mix bench` to consumers.**
  `mix.exs:105` packages `lib` wholesale and `elixirc_paths(_), do: ["lib"]` (`:26`) compiles it in every env including `:prod`, so `lib/mix/tasks/bench.ex:1-60` ships and is live; `bench/` is not packaged. Proven: `mix hex.build` → 56 files including `lib/mix/tasks/bench.ex`; in a consumer, `mix help bench` lists it and `mix bench` creates stray `bench/output/` in their repo root (`bench.ex:19`), globs nothing (`:22`), then prints the false claim "HTML reports saved to bench/output/". It also claims the globally unnamespaced `Mix.Tasks.Bench`.
  **Change:** `defp elixirc_paths(:dev), do: ["lib", "dev"]` at `mix.exs:25`; `git mv lib/mix/tasks/bench.ex dev/mix/tasks/bench.ex`. Drop the now-unneeded `dialyzer: [plt_add_apps: [:mix]]` (`mix.exs:21`) if nothing else needs it.
  **Acceptance:** `mix bench` still works locally; `mix hex.build` tarball contains no `mix/tasks/`.

  **Done:** `elixirc_paths(:dev) = ["lib", "dev"]`; bench.ex moved to dev/mix/tasks/. `mix bench --list` works; hex tarball has 60 files, none under mix/tasks. `plt_add_apps: [:mix]` kept (dev/ still compiles in :dev, where dialyzer runs).
---

## Phase 2 — Authentication correctness

- [x] **RC5 — require `exp` and dispatch on the claim (both edits, one commit).**
  (a) **`exp` is not enforced at all.** `Joken.Config.default_claims(default_exp: 3600)` (`plugs/oauth.ex:231-236`) affects only *generation*; Joken validates by folding over the **token's** claims (`deps/joken/lib/joken.ex:375-385`), so a claim absent from the token is never validated, and `validate_claims/2` (`:259-262`) checks only `iss` and `aud`. A token with no `exp` is accepted **forever**, and `nbf` is likewise unenforced by absence — while the moduledoc advertises "Token expiration checking" (`:13`). Every existing test sets an `exp` (`plugs/oauth_test.exs:31`).
  (b) **`:expired` is dead code.** `oauth.ex:149-152` maps `{:error, :expired}` to 401 "Token expired", but `normalize_joken_error/1` (`:251-254`) does `String.contains?(reason_str, "expired")` against a Joken `exp` failure that renders as `[message: "Invalid token", claim: "exp", ...]` — no `"expired"` substring — so it falls to the `"Invalid"` branch. Proven by `mix run` with an hour-old RS256 token: body `"Token verification failed"`, telemetry `reason: :invalid_signature`. The same defect hides `{:error, :invalid_issuer}` (`:159-162`); the existing wrong-issuer test (`oauth_test.exs:101`) passes only because it asserts `status == 401` and gets there via `:invalid_signature`.
  **Change:** `validate_claims/2` requires a present integer `exp` (returning `{:error, :expired}` directly) and enforces `nbf` when present; rewrite `normalize_joken_error/1` to dispatch on `Keyword.get(reason, :claim)` (`"exp"` → `:expired`, `"iss"` → `:invalid_issuer`, else `:invalid_signature`).
  **Acceptance:** expired token → body "Token expired" **and** telemetry `reason: :expired`. `exp`-less token → rejected. Wrong issuer → `reason: :invalid_issuer`. Clients can distinguish "refresh" from "forged".

  **Done:** validate_claims/2 requires an integer `exp` and enforces `nbf`; normalize_joken_error/1 dispatches on `Keyword.get(reason, :claim)`. Expired -> 'Token expired' + `reason: :expired`; wrong issuer -> `:invalid_issuer`; exp-less token rejected.
- [x] **RC5b — test the alg-pinning path production actually takes.**
  `resolve_signer_alg/2`'s alg-pinned clause (`plugs/oauth.ex:298-304`, condition at `:299`) has **zero coverage hits** because `oauth_test.exs:10-15` builds its JWK with `Map.put("kid", "test-key")` and no `"alg"`, so every test falls through to the `%{"kty" => "RSA"}` clause at `:306`. Every real JWKS (Auth0, Okta, Entra, Keycloak, Google) publishes `alg`, so production takes the one clause the suite never enters. Also zero: `:309-311` (EC), `:324-326`, `:208` (missing-alg). Note the control itself was verified sound by inspection — the allowlist excludes `"none"` (`:200-208`, `@default_algorithms` at `:54`) and `kty` is pinned to the alg family.
  **Change:** add tests — alg-pinned JWK accepted, alg-mismatch (`alg: HS256` against an RSA JWK) rejected with `:alg_mismatch`, JWKS header with no `alg` rejected, and an EC key path.
  **Acceptance:** `plugs/oauth.ex` coverage rises from 76.0%; `:299` and `:309-311` have hits.

  **Done:** alg-pinned accept, alg-mismatch, missing-alg, no-kty and EC P-256 paths tested. plugs/oauth.ex coverage 76.0% -> 86.1%.
- [x] **RC7 — one canonical authenticated principal.**
  There is no canonical principal representation. `Plugs.OAuth` assigns `%{claims: claims, scopes: scopes}` (`plugs/oauth.ex:142`) and writes scopes to a bare atom key `:oauth_scopes` (`:141`); `Plugs.Auth`'s static strategies assign the constant `%{authenticated: true}` (`plugs/auth.ex:216`, `:225`). Three downstream consumers each guess a different shape and all three guess wrong: `Tasks.default_owner/1` returns `assigns[:current_user]` (`tasks.ex:177-178`) — against OAuth's map, ownership is exact-match on a map containing `exp`/`iat`/`jti`, so a task stamped on one request never matches on the next and **the owner's own task 404s**; against static auth every client sharing the token collapses into one owner and scoping is a no-op. `MessageRateLimit.default_key_func/1` (`plugs/message_rate_limit.ex:215-222`) matches `%{id: id}` or a binary, so neither principal matches and every request falls through to `conn.remote_ip`, contradicting its own moduledoc (`:30`, `:78-80`) — behind the reverse proxy these servers normally run behind, that is the proxy's address for everyone: one abusive tenant 429s every other tenant out of a shared bucket. `Handler.verify_scope/2` reads the literal `:oauth_scopes` (`handler.ex:391`), an atom written only by a conditionally-compiled module.
  **Change:** both auth plugs assign one documented principal carrying a stable scalar identity (OAuth `claims["sub"]`; static a configured or derived id) plus scopes, exposed through one always-compiled accessor pair (e.g. `Plugs.Auth.principal/1`, `scopes_assign/0`). Update all three consumers to read it.
  **Acceptance:** a task created on request A is retrievable by the same principal on request B under both OAuth and static auth. Two OAuth subjects get distinct rate-limit buckets behind a proxy.

  **Done:** New ConduitMcp.Principal (`:mcp_principal`, stable scalar `:id`); both plugs write it; Tasks.default_owner/1, MessageRateLimit default key and Handler.verify_scope/2 read it. OAuth id resolved from `:subject_claims` (default ["sub", "client_id"]) and a token with none is rejected 401.
- [x] **RC7b — test the default key functions.**
  `plugs/rate_limit.ex:158-160` (`conn.remote_ip |> :inet.ntoa() |> to_string()`) is the only uncovered line in a 95.0%-covered module: every test passes an explicit `key_func` (`plugs/rate_limit_test.exs:139`, `:160`; `transport/rate_limit_integration_test.exs:57`, `:117`), so the out-of-the-box behaviour of a DoS control is unverified — and `:inet.ntoa/1` raises on a malformed `remote_ip`, killing the request process instead of returning 429. This is the causal link: the default was never exercised, which is why nobody noticed its principal clauses cannot match.
  **Acceptance:** tests for distinct IPv4 buckets, IPv6, and a malformed `remote_ip` that must not raise.

  **Done:** Default key func tests: distinct IPv4 buckets, IPv6, malformed remote_ip. `:inet.ntoa/1` `{:error, :einval}` now goes through Principal.client_ip/1 instead of raising.
- [x] **S-H1 — enforce `scope:` outside tools, or reject it at compile time.**
  `ConduitMcp.Component` documents `:scope` as a general component option (`component.ex:76`), but the scope map is built from tools only (`endpoint.ex:106`, `:457-464`) and the handler consults it only on `tools/call` (`handler.ex:266`). `handle_resource_read/4` (`:307`) and `handle_prompt_get/4` (`:334`) have **no authorization hook at all**. The DSL matches: `scope/1` (`dsl.ex:224-228`) unconditionally writes `@mcp_current_tool_scope` with no assertion it is inside a `tool` block, and `build_scope_map/1` (`:1336-1343`) folds over tools only. `use ConduitMcp.Component, type: :resource, scope: "admin:read"` compiles clean, warns nothing, and enforces nothing.
  **Change:** build the scope map from all component/DSL declaration types and add the authorization hook to `handle_resource_read/4` and `handle_prompt_get/4`, mirroring `check_tool_scope`. If full enforcement is deferred, `scope:` on a non-tool **must** raise at compile time — a silently ignored authorization control is worse than an unsupported one.
  **Acceptance:** a scoped resource and a scoped prompt both deny a principal lacking the scope, fail closed with no principal, and are covered in `oauth_scope_test.exs` alongside the existing tool cases.

  **Done:** Scope map built from tools, prompts and resources (templates included) in both authoring modes, in dispatch order; hooks added to resource read, prompt get, subscribe, unsubscribe and completion. DSL `scope/1` raises outside a declaration and for an empty/non-binary value.
---

## Phase 3 — Authorization

- [x] **RC4 — scope, guard, cap, and sweep cancellation.**
  `cancellation.ex:58-61` keys the table on the raw client-chosen JSON-RPC id with no session, connection, or principal component, inserting unconditionally with no cap (`:62`), reachable unauthenticated via `handler.ex:194-199`. JSON-RPC ids are client-generated and conventionally small integers, so `POST {"method":"notifications/cancelled","params":{"requestId":"1"}}` sets a flag every concurrent client's request id `1` observes through `cancelled?(conn)` (`:88`, fed from `assigns[:mcp_request_id]` at `handler.ex:103`) — looping `1..1000` aborts every in-flight tool call on the node. Same missing-owner-scoping class as the Tasks IDOR fixed in `379fbc4`, in the subsystem that fix did not touch. Rows are removed only by `clear/1` for the id currently being served (`handler.ex:107-111`), so an id that never matches is retained forever; `cleanup/1` exists (`cancellation.ex:128`) and **nothing calls it** — `application.ex:31-52` wires no janitor — and there is no cap. The client-supplied `reason` is unvalidated up to the 1 MB body limit, so one POST plants a megabyte permanently. Enabler: `MessageRateLimit` exempts notifications (`message_rate_limit.ex:142-143` branch, `:204-207` predicate), so the flood is never throttled. The moduledoc's "bounded by the rate of in-flight cancellations" (`:41-42`) is false. Co-located: `to_string(request_id)` (`:60`) raises `Protocol.UndefinedError` on a non-scalar id, and `handle_notification/2` is dispatched from a `cond` (`handler.ex:73-84`) with no `try/rescue` — unlike `handle_method/3` (`:106-112`) — so `{"requestId":{}}` is an unrescued 500 with `[:conduit_mcp, :request, :stop]` never emitted (`:88-97` unreachable): invisible to metrics while filling the log.
  **Change:** `cancel/3` with a guard rejecting non-string/non-integer ids, a key of `{session_or_principal, id}` from `conn.private[:mcp_session_id]` or a `Tasks.owner/1`-style principal, a `@max_rows` check, and `truncate/1` on `reason` — threaded through `cancelled?/1` (already receives the `conn`) and `clear/2`. Start a janitor from `application.ex:31` (`Session.Janitor` already dispatches to any module exporting `cleanup/1`, `session/janitor.ex:71`). Stop exempting `notifications/cancelled` from the message rate limiter. Correct the moduledoc.
  **Acceptance:** client A cancelling id `1` does not affect client B's id `1`. `{"requestId":{}}` returns a JSON-RPC error, not a 500, and emits `:stop`. Rows past the cap are rejected; the janitor evicts stale rows.

  **Done:** cancel/3 with a string|integer guard, key `{scope, id}` (session -> principal -> client IP), per-scope quota (256) plus global cap on an `ordered_set`, reason via ConduitMcp.Reflect, janitor from application.ex, `notifications/cancelled` no longer rate-limit-exempt. `{}` requestId returns invalid_params and still emits `:stop`.
- [x] **RC8 — make task authorization a query predicate.**
  `Tasks.list/2` copies the whole table then filters for authorization in Elixir: `tasks/ets_store.ex:149-160` does `:ets.foldl(fn {_id, task}, acc -> [task | acc] end, [], @table)` (`:153`) and `tasks.ex:149` applies `Enum.filter(&authorized?(&1, owner))` afterwards. `authorized?/2` is default-open (`tasks.ex:192-199`: `authorized?(_task, nil), do: true`, and `"owner" => nil -> true`). Every `tasks/list` deep-copies up to 10 000 task maps (`tasks/ets_store.ex:28`) into the caller's heap, filters twice, then `JSON.encode!`s the survivors into one response (`streamable_http.ex:336`); `handler.ex:566-570` exposes no `limit`/`cursor`, so the response is unbounded. Authorization is opt-in by accident: `create/2` — the arity every example uses — never stamps an owner (`tasks.ex:71-75`, `:72`), so `tasks/get`, `tasks/result`, and `tasks/list` hand those tasks to **any** caller. The `379fbc4` IDOR fix only engages when the application remembers to pass `Tasks.owner(conn)`.
  **Change:** change the `Tasks.Store.list/1` contract to accept `:owner`, `:status`, `:limit` and express all three as an `:ets.select/3` match spec so the scan stays in the C layer and only matching rows are copied; `Tasks.list/2` passes `owner:` instead of post-filtering; `handle_tasks_list/3` reads a client `"limit"` clamped to a server maximum. Add opt-in `config :conduit_mcp, :tasks_require_owner, true` for unowned-row semantics so the public API stays stable.
  **Acceptance:** a `nil` owner no longer matches rows it does not own. `tasks/list` with a status filter matching nothing does not copy the table. Response respects the clamped limit. Unowned rows are inaccessible with `:tasks_require_owner` set.

  **Done:** Store `list/1` takes `:owner`/`:status`/`:limit` as one `:ets.select/3` match spec (every `map_get` behind `is_map_key`); facade passes owner down and re-checks; `nil` owner matches only unowned rows; `:tasks_require_owner`; handler clamps `"limit"` to `:tasks_list_max_limit` (100).
---

## Phase 4 — Transport parity

- [x] **RC3 — extract `ConduitMcp.Transport.Shared` (all duplicated plumbing).**
  `Transport.SSE` and `Transport.StreamableHTTP` copy ~120 lines instead of sharing a base module, and the copies diverged. `sse.ex:71-81` calls `Plugs.Auth` unconditionally; `streamable_http.ex:100-121` branches on `strategy == :oauth` (`:108`, dispatch `:112-118`). `Plugs.Auth` has no `:oauth` clause, so SSE lands on the catch-all (`plugs/auth.ex:164-167`) → 401 "Server configuration error" plus a `Logger.error` **per request**. Both transports auto-extract `auth:` from `__endpoint_config__/0` (`sse.ex:122-130`, `streamable_http.ex:249-257`) and `guides/authentication.md:69-111` documents `:oauth` as transport-level with no note that it is StreamableHTTP-only. SSE also has no `/.well-known/oauth-protected-resource` (present at `streamable_http.ex:361-381`), so RFC 9728 discovery fails. Both re-run `Plug.init/1` on **every request** — the one thing `init/1` exists to avoid (`streamable_http.ex:112`, `:128`, `:138`; `sse.ex:79`, `:89`, `:99`); `OAuth.init/1` does 4 `Keyword` lookups, builds a 9-key map and calls `resolve_algorithms/3` (`plugs/oauth.ex:70-99`), and `call/2` re-derives the whole config per request although `init/1` returns `opts` untouched. Zero coverage explains the miss: `streamable_http.ex:112-115` and the whole `:361-377` route have zero hits; `sse.ex:79`, `:89` zero hits; no test configures `auth: [strategy: :oauth]` on a transport and `Transport.SSE` has no auth or rate-limit test at all.
  **Change:** extract `ConduitMcp.Transport.Shared` owning every duplicated function, resolving each plug **in `init/1`** and storing `{mod, opts}` so `call/2` becomes `mod.call(conn, opts)`.
  *Divergence-bearing (these caused the bug):* `authenticate/2`, `rate_limit/2`, `message_rate_limit/2`, `extract_config/2`, `warn_if_origins_unset/2` (currently reached cross-module at `sse.ex:113` into `@doc false` `streamable_http.ex:230-232`), and the OAuth metadata route.
  *Identical copies:* `add_cors_headers/2` (`streamable_http.ex:88-98` vs `sse.ex:59-69`, identical including the comment), POST body dispatch (`:309-352` vs `:198-227`), `get "/health"` (`:354-358` vs `:233-237`), and the `options _` / `match _` catch-alls (`:290-292`, `:382-384` vs `:163-165`, `:240-242`).
  Also settle the feature gaps that exist only because they were never copied back: the `mcp-protocol-version` response header (`streamable_http.ex:387`) and session handling (`:145-212`) are StreamableHTTP-only. Decide per feature whether SSE should have it or whether its absence is intentional for a legacy transport — and **document the decision either way**, since undocumented asymmetry is exactly what produced the `:oauth` bug.
  **Acceptance:** `strategy: :oauth` works identically on both transports. `/.well-known/oauth-protected-resource` served by both. `Plug.init/1` runs once per transport, not per request. **No function body exists in both transports.** Each remaining asymmetry carries a one-line moduledoc rationale. New tests exercise auth + rate limiting on `Transport.SSE`.
  **Note:** scoped up from the original 6-function split at your direction — the full extraction lands here rather than half in P2, removing the duplication pattern in one pass. Expect a larger diff in this phase; review it separately from Phases 2–3.

  **Done:** ConduitMcp.Transport.Shared owns the pipeline, init/1, call/2, all plug functions and the shared routes via `use`/`shared_routes()`. No function body exists in both transports. Plugs resolved once in init/1. RFC 9728 metadata served by both and exempted from auth. `mcp-protocol-version` now on both; sessions documented as StreamableHTTP-only.
- [x] **RC9 — one source of not-found semantics.**
  Each authoring mode hand-writes its own not-found responses and they disagree. **Resources:** DSL returns `-32601` (`dsl.ex:1314`, and the templated-miss path `:1502`), manual returns `-32601` (`server.ex:255`), Endpoint returns `-32002` in all three paths (`endpoint.ex:182`, `:396`, `:407`) — and the library's own core agrees with Endpoint (`handler.ex:575`), with `errors.ex:39` defining `-32002` as "resource URI not found" against `-32601` "method does not exist". **Tools:** proven by `mix run` against a two-line `use ConduitMcp.Endpoint` — an unknown tool returns `-32601 "Tool not found"` in manual/DSL but `-32602 "Parameter validation failed"` in Endpoint+Component, with the real message buried in `data.errors`. It survived because `endpoint_integration_test.exs:204-213` asserts only truthy `response["error"]`. Cross-mode behavioural equivalence is the stated premise of `guides/choosing_a_mode.md`.
  **Change:** route all three modes through `Handler`'s codes — `-32002` for a resource miss at `dsl.ex:1314`, `:1502`, `server.ex:255`; in `endpoint.ex`, resolve the tool name **before** parameter validation so an unknown tool takes the existing `-32601` path. Replace the truthy assertion at `endpoint_integration_test.exs:204-213` with the exact code.
  **Acceptance:** identical MCP requests return identical error codes across all three modes, pinned by test. Both changes recorded in `CHANGELOG.md` as behaviour fixes (`-32601` for a missing resource is a spec deviation, not a contract worth preserving).

  **Done:** Unknown tool/prompt -> -32602 with a top-level message; missing resource -> -32002; all three modes agree (verified by probe). Fixed a DSL static-only-resources FunctionClauseError that returned -32603. endpoint_integration_test.exs pins exact codes.
---

## Phase 5 — Availability & exposure

- [x] **RC6 — single-flight and cooldown the JWKS refresh.**
  Every cache miss is an immediate independent outbound fetch. `fetch_keys/1` (`jwks.ex:80-92`) is a bare `:ets.lookup` + TTL compare followed by `fetch_and_cache/2` (`:157-171`) with no lock or dedup; `fetch_key/2` (`:94-105`) calls `refresh_keys/1` on any unknown `kid`, and `refresh_keys/1` (`:114-117`) calls `fetch_and_cache/2` **directly**, bypassing `get_cached/2` and the TTL. Every authenticated request runs this path (`plugs/oauth.ex:127`). At TTL lapse with 500 rps, 500 concurrent requests all fetch, each blocking a Bandit process up to 15 s (`jwks.ex:75-76`); IdPs rate-limit JWKS endpoints, so a routine expiry or cold start becomes a total auth outage. Worse, `fetch_signing_key/2` (`plugs/oauth.ex:186-194`) runs **before** any signature check on the unverified header (`:125-127`), so `Bearer <garbage with random kid>` in a loop drives one outbound request to the operator's IdP per request at no attacker cost, with no negative cache and no minimum refresh interval — and each attempt overwrites the cache row with a fresh `cached_at` (`jwks.ex:164`), resetting the stale-serving window that exists to survive an AS outage. Plug-level rate limiting cannot fix this: the fetch precedes auth. Adjudicated **HIGH** (SecAudit rated MEDIUM on amplification factor; process exhaustion arrives before bandwidth does).
  **Change:** rewrite `fetch_and_cache/2` + `refresh_keys/1` using the cache table as the coordination surface — `:ets.insert_new/2` on a `{:refresh_lock, jwks_uri}` row as a single-flight lock (losers call the existing `serve_stale/3` at `:230`, which already fails closed), a `{:last_refresh, jwks_uri}` cooldown row consulted by `refresh_keys/1`, and a lock-age guard so a crashed holder cannot wedge it.
  **Acceptance:** N concurrent cold-cache requests produce exactly one outbound fetch. A loop of random `kid`s produces at most one fetch per cooldown window and does not reset `cached_at`. Unknown `kid` fails with `:not_found` against the cached set.

  **Done:** `:ets.insert_new/2` refresh lock with a lock-age guard; losers wait for the cache then fall back to serve_stale/3; `{:last_refresh, uri}` cooldown consulted by refresh_keys/1 without touching `cached_at`.
- [x] **RC11 — bound the JWKS body at the source, and fix the `req` floor.**
  `@max_body_bytes` (`jwks.ex:68`) is enforced on the already-buffered, already-decompressed body — `decode_jwks/2` guards `byte_size(body)` at `:210-213` after `Req.get/2` returned a complete binary (`:195-213`), and `decode_body: false` (`:77`) does not disable decompression. The module's own docs admit it (`:52-57`) and require `req >= 0.6.1`, while `mix.exs:66` declares `{:req, "~> 0.5", optional: true}` — the security floor exists only in prose. A multi-gigabyte JWKS response (compromised IdP, hijacked DNS, wrong URL) exhausts the VM before the guard runs; there is also no pool/queue timeout, so a slow endpoint holds a connection the full 15 s. This repo's own lock is `req 0.7.2` (`mix.lock:36`), so version exposure is downstream-only.
  **Change:** stream with a `Req` `into:` collector accumulating `byte_size` and aborting past `@max_body_bytes` (returning `{:error, :jwks_too_large}`), plus `pool_timeout`. Set `mix.exs:66` to `{:req, "~> 0.6.1 or ~> 0.7", optional: true}` — adjudicated over the alternative `"~> 0.6 and >= 0.6.1"`, which resolves to `< 0.7.0` and would **exclude the version this repo itself locks**. Delete the stale `{:req, "~> 0.6"}` snippet at `jwks.ex:58`.
  **Acceptance:** an oversized *compressed* response is rejected without buffering it. `mix deps.get` still resolves 0.7.2.

  **Done:** Streaming `into:` collector aborts past @max_body_bytes with `compressed: false`; `{:req, "~> 0.6.1 or ~> 0.7"}`; stale snippet removed. `pool_timeout` deliberately unset (moved between req 0.6/0.7; Finch's default is the same value).
- [x] **T-M1 — test the JWKS scheme guard and transport-error path.**
  `jwks.ex:190-191` (`{:error, :invalid_jwks_uri}` — the SSRF/LFI guard) and `:204-206` have zero hits. `jwks_test.exs` is otherwise thorough (redirects, oversized bodies, invalid key sets, stale fallback, `:stale_max_age`, kid rollover, TTL refetch, concurrency) and tests `http://` rejection at `:49`, but never a non-HTTP scheme — `URI.parse("file:///etc/passwd")` falls to `:190`. Transport failure (DNS, connection refused) is unexercised, so its interaction with the stale-cache fallback is unverified; only HTTP 500 is tested (`:94-119`).
  **Acceptance:** `file://`, `ftp://`, and scheme-less URIs rejected; a transport error with a warm stale cache serves stale, and with a cold cache fails closed.

  **Done:** `file://`, `ftp://`, `gopher://` and scheme-less URIs rejected; transport error serves stale with a warm cache and fails closed with a cold one.
- [x] **RC12 — bound the SSE keep-alive loop.**
  `keep_alive_loop/1` (`sse.ex:286-303`) is a selective `receive` matching only `{:plug_conn, :sent}` with an `after` timeout, inside a route (`:168-181`) that pins one Bandit process, socket, and `Plug.Conn` per connection with no cap, no idle timeout, and no maximum lifetime. Any other message — monitor `:DOWN`s, `:system` messages, stray `send/2` — is never matched and never removed, and because the clause has a non-matching pattern plus an `after`, **every** 15 s tick rescans the whole accumulated mailbox: a monotonic leak with O(n) per-tick rescan over a multi-day connection. The only exit is a failed `chunk/2`, detected at most once per 15 s, so a client that opens connections and never reads accumulates processes and FDs. Never observed: `sse_test.exs:66-94` sends `{:started, :ok}` **before** `SSE.call/2`, so the "handshake" assertion proves only that the task was scheduled; the whole test is a 200 ms `refute_receive`, and coveralls confirms `sse.ex:294-300` has **zero hits**. The `Task.async` is never awaited.
  **Change:** catch-all `_msg -> keep_alive_loop(conn, started_at)` clause; `@max_connection_lifetime` threaded through the recursion; `keep_alive_interval` read from `init/1` opts (this is what makes the loop testable); an `:ets.update_counter` connection gate rejecting past `:max_sse_connections` with 503. Document `Transport.SSE` as legacy in favour of `StreamableHTTP`.
  **Acceptance:** a foreign message sent to the connection process does not accumulate. With an injected short interval, a test asserts the first emitted keepalive chunk (replacing the 200 ms `refute_receive`) and `sse.ex:294-300` gains hits.

  **Done:** Catch-all `_msg` clause drains the mailbox; `:max_connection_lifetime` threaded through the recursion; `:keep_alive_interval` from init/1; `:ets.update_counter` connection gate returning 503 past `:max_connections`.
- [x] **S-H2 — fix the shipped CORS/Origin defaults.**
  `cors_origin` defaults to `"*"` (`streamable_http.ex:254`) and `add_cors_headers/2` emits `access-control-allow-origin` unconditionally on every response (`:94-97`); Origin validation is a no-op unless `:allowed_origins` is set, with only a startup log warning (`origin_validation.ex:37-40`, `streamable_http.ex:233-241`). A page on `https://evil.example` sending a `content-type: application/json` POST triggers a preflight that `options _` (`:290`) answers 200 with `ACAO: *` and `Allow-Headers: content-type, authorization` (`:256`); the browser then sends the POST and, because `ACAO: *` is present, the page **reads the response**. No DNS rebinding required.
  **Change:** default to same-origin (or require an explicit `cors_origin` opt-in) and make an unset `:allowed_origins` fail closed for `Origin`-bearing requests rather than log-and-allow. Breaking default change — `CHANGELOG.md` entry with the one-line opt-out.
  **Acceptance:** a cross-origin POST is not readable by the calling page under default config; explicitly configured origins still work.

  **Done:** `:cors_origin` unset emits no CORS headers at all; unset `:allowed_origins` fails closed for Origin-bearing requests. A list `:cors_origin` raises at init/1.
- [x] **S-L2 — honour the documented `:allowed_origins` shapes.**
  Documented to accept a regex or bare string (`streamable_http.ex:22-23`, `sse.ex:19-21`) but the plug's `cond` handles only `nil | "*" | list` (`origin_validation.ex:37-53`); a `%Regex{}` or bare string hits the catch-all and **403s every request carrying an `Origin`**. Fails closed, so availability not exposure.
  **Change:** handle `%Regex{}` and bare string, or narrow the docs to `list`. Prefer implementing — both are documented public config.
  **Acceptance:** each documented shape is covered by a test.

  **Done:** OriginValidation handles list, bare string, `Regex` and `"*"`; unsupported values fail closed. Moduledoc corrected: Origin validation is not DNS-rebinding protection.
---

## Phase 6 — Small correctness defects

- [x] **A-L1 — `Protocol`'s two stale public surfaces.**
  (a) The moduledoc advertises `server_error/0` (`protocol.ex:27`) but the `defdelegate` block (`:96-104`) omits it, so `ConduitMcp.Protocol.server_error()` raises `UndefinedFunctionError`. (b) `methods/0` (`:107-133`) is a second, incomplete copy of the routing table — the real one is the `case` at `handler.ex:122-195`, which routes six methods `methods/0` does not know: `resources/templates/list` (`:131`), `tasks/get` (`:155`), `tasks/cancel` (`:158`), `tasks/result` (`:161`), `tasks/list` (`:164`), `notifications/cancelled` (`:194`). Its only caller is its own test (`protocol_test.exs:61`).
  **Change:** add the missing `defdelegate`; derive `methods/0` from the handler's table or delete it (public API — deprecate rather than remove if kept).
  **Acceptance:** `Protocol.server_error()` returns; `methods/0` and the handler cannot disagree.

  **Done:** `server_error/0` defdelegate added; `methods/0` delegates to ConduitMcp.Handler's dispatch table, which now drives routing, so the two cannot disagree.
- [x] **T-M3 — a typo'd DSL validation option must not silently disable validation.**
  `schema_converter.ex:207-211` (`Logger.warning("Unknown validation option ignored: ...")`) has zero hits, so `field(:name, :string, min_lenght: 3)` yields a compile-time warning and **no validation at all** with nothing pinning the footgun. Same module, also uncovered: `:232-233` — the entire error-reporting purpose of `validate_schema/1`, documented as "used during compile time to catch schema generation errors" (`:216-217`), while only its `:ok` path is tested (`validation_test.exs:299`); and `compile_validation_schema/1` (`:88-95`, both clauses) is a public function with **no test caller at all**.
  **Change:** raise at compile time on an unknown validation option rather than warning — a silently dropped constraint is a security control that vanished. Add tests for `validate_schema/1`'s error return and both `compile_validation_schema/1` clauses.
  **Acceptance:** a typo'd option fails the build; the error path is covered.

  **Done:** Unknown validation option raises ArgumentError at compile time with a 'did you mean' suggestion; validate_schema/1 error path and both compile_validation_schema/1 clauses covered.
- [x] **RC13 — one boundary helper for reflected text.**
  The codebase has a truncation convention — `String.slice(to_string(method), 0, 200)` (`handler.ex:168-172`) — that adjacent paths do not follow, and no path strips control characters. `client_version` is echoed untruncated into both the error message and the log (`handler.ex:219`, `:226`), so a 1 MB `protocolVersion` (inside the `length: 1_000_000` parser cap, `streamable_http.ex:81`) is reflected in full and logged; a non-string `protocolVersion` such as `{}` makes the interpolation raise and the `rescue` at `:174-182` converts it into a misleading "Internal server error" instead of `invalid_request`. `task_not_found/2` reflects raw `taskId` the same way (`:572-577`). Proven: `method => "tools/call\x00\x01\x02"` returns `message: <<"Method not found: tools/call", 0, 1, 2>>` — control bytes verbatim to the client and to `Logger`. Consumer-supplied auth failure reasons reach logs *and* every attached telemetry handler verbatim (`plugs/auth.ex:194`, `:189-192`; re-logged at `telemetry.ex:218` and `plugs/oauth.ex:333`), so the idiomatic-looking `{:error, {:invalid_token, token}}` writes the presented credential to the log. `handler.ex:212` logs the entire client-controlled `clientInfo` map as metadata. The library never logs an `Authorization` header itself — this is a leak *channel*, not a leak.
  **Change:** one helper applying `to_string/1`, a length clamp, and control-character stripping, used at `handler.ex:219`, `:226`, `:171`, `:572-577`, `:212`, `plugs/auth.ex:194`. Telemetry metadata carries a coarse atom (`:invalid_credential`); document that the `:verify` contract's returned reason must not embed the credential. Reject a non-binary `protocolVersion` up front with `invalid_params`.
  **Acceptance:** control bytes and oversized values neither reach the client nor the log. `protocolVersion: {}` returns `invalid_request`, not "Internal server error".

  **Done:** New ConduitMcp.Reflect (to_string + control-char strip + clamp) used for method names, protocolVersion, taskId, cancellation reasons and auth failure reasons. Telemetry carries `:invalid_credential`. Non-binary protocolVersion -> invalid_params.
- [x] **T-M8 — pin the malformed-JSON-RPC contracts.**
  Three tests assert only `assert is_map(response)` (`security_test.exs:126-128`, `:137-138`, `:106-108`), which passes for `%{}`, for a *success* response, and for any regression short of a raise — this is what concealed RC13. The sibling 12 lines above pins the contract properly (`:116`), so it is local inconsistency, not house style.
  **Acceptance:** each asserts the exact code and message shape.

  **Done:** security_test.exs asserts exact codes and messages for control-character, nil, non-string method, non-string protocolVersion and oversized taskId.
---

## Phase 7 — Close the error-path test gaps

- [x] **T-M2 — four untested validation rejection branches**, asymmetric in exactly the way that hides sign errors: non-map params/args (`validation.ex:75-84`, `:116-125`); `max_length` violation (`:597-603` — `min_length` **is** covered); the non-numeric range bypass where a string value silently passes a `min:`/`max:` constraint (`:537`, `:560`); boolean coercion where only `"true"` is tested while `"false"`/`"1"`/`"0"`/non-coercible are not (`:677`, `:684-688`) — inverting `"0" -> false` turns every `"0"` flag into `true` and ships green.
  **Done:** Non-map params/args, max_length on tools and prompts, non-numeric range bypass, and every boolean coercion spelling including non-coercible.
- [x] **T-M4 — restore `Req.Test` private mode.** `oauth/jwks_test.exs:12-28` flips `Req.Test` to shared mode globally; `on_exit` restores `:req, :default_options` but never private mode, though `Req.Test.set_req_test_to_private/1` exists (`deps/req/lib/req/test.ex:633`). The safety argument is a comment, not an invariant.
  **Done:** `Req.Test.set_req_test_to_private/1` in on_exit alongside the default_options reset.
- [x] **T-M5 — snapshot, don't clobber, the validation config.** `endpoint_integration_test.exs:215-222` does `on_exit(fn -> update_validation_config([]) end)` instead of snapshotting, unlike both siblings mutating the same global (`endpoint_test.exs:557-558`, `validation_test.exs:207-208`). Harmless only because there is no `config/` directory. `update_validation_config/1` also writes `:persistent_term` (`application.ex:26`), so the clobber outlives the test and affects every later sync module in seed-dependent order.
  **Done:** Snapshots the prior `:validation` config instead of clobbering it with [].
- [x] **T-M6 — `on_exit` the global default-logger handler.** `"conduit-mcp-default-logger"` (`telemetry.ex:502`) is attached with no `on_exit` in two tests (`telemetry_test.exs:271-286`), the second detaching only on the happy path. A leak makes the third test **fail** (`detach_default_handlers/0` returns `:ok` instead of `{:error, :not_found}`) — order-dependent, reporting the wrong test — and a leaked handler fires for every subsequent `[:conduit_mcp, *]` event while dot-dereferencing metadata (`:562-604`).
  **Done:** `on_exit` detaches 'conduit-mcp-default-logger' for every test in the describe block.
- [x] **T-M7 — make the janitor tests deterministic.** Both depend on a wall-clock tick (`session/janitor_test.exs:53-61`, `tasks/janitor_test.exs:39-46`): a 50 ms timer inside a 500 ms `assert_receive`, assuming the *first* observed tick removes the backdated row. Thin on a loaded CI runner, and `mix coveralls` adds `:cover` overhead. The deterministic idiom already exists 21 lines below in the same file (`session/janitor_test.exs:102-108`: `send(pid, :cleanup)` + `:sys.get_state(pid)` as a barrier). Start with `interval: 60_000` and drive exactly one tick — also removes ~1 s from the serial phase.
  **Done:** Both janitors start with `interval: 60_000` and are driven by one `send(pid, :cleanup)` + `:sys.get_state/1` barrier.
- [x] **T-L1 — make the property generators reachable.** Three of five properties cannot reach the input space they claim (`protocol_property_test.exs:7-17`, `:44-59`): `string(:alphanumeric)` cannot practically generate the keys `"jsonrpc"`/`"method"`/`"id"`, so every generated map takes the same fall-through and `valid_request?`/`valid_notification?`'s `true` branch is never reached; `:alphanumeric` excludes `/`, so no real MCP method name is generated and only `method_not_found` is exercised. The two `success_response`/`error_response` properties (`:19-42`) are sound. Add two high-value invariants: string-key closure at every depth (the repo's central documented convention, enforced nowhere) and validation idempotence.
  **Done:** Generators build protocol-shaped maps from the real key set and MCP method names containing `/`; added string-key-closure and validation-idempotence properties.
- [x] **T-L2 — make `:conduit_mcp_tasks` ownership explicit.** The table is wiped wholesale from an `async: true` module and the comment asserting sole ownership is wrong (`handler_test.exs:1025-1033`, module async at line 2): there are **four** consumers (`handler_test.exs:893`, `tasks_test.exs:7-8`, `tasks/janitor_test.exs:8-9`, `tasks/store_dispatch_test.exs` via `Tasks.create/2`), the table is owned by the supervised `Tasks.EtsStore.Owner` (`application.ex:39`) and global for the run. Safety comes only from ExUnit's phase split — the other three are `async: false` — and nothing encodes that. Flipping `tasks_test.exs` to async (it looks async-safe) makes `:ets.delete_all_objects` race. Encode the constraint or remove the coupling.
  **Done:** `tasks/*` tests extracted to ConduitMcp.HandlerTasksTest (async: false), with the invariant that every module touching `:conduit_mcp_tasks` must be async: false written down.
- [x] **T-L3 — test `Plugs.Auth`'s uncovered branches**, the only four uncovered lines in a 90.9% module: lowercase `bearer` (`plugs/auth.ex:150-154` — matters for HTTP/2 clients that lowercase header values), the missing-header 401, and the deprecated `:custom` strategy plus its delegation (`:158-162`). `:custom` is a documented public strategy with a deprecation path and zero tests.
  **Done:** Lowercase `bearer` for both strategies, all three missing-header 401s, deprecated `:custom` delegation + warning, unknown strategy and invalid verify return.
- [x] **T-L4 — test the handler's task and callback-contract error branches:** `handler.ex:527` and `:540` ("Missing taskId" for two of three `tasks/*` methods — only `tasks/get` is covered at `handler_test.exs:929`); `:550` (`tasks/result` for a **failed** task's error payload; only completed and working are tested at `:955`, `:975`); and `:593-594`, the guard against a server module returning neither `{:ok, map}` nor `{:error, map}`. For a library whose entire contract is "callbacks return `{:ok, map()} | {:error, map()}`", that contract's enforcement has no test.

  **Done:** Missing taskId for tasks/cancel and tasks/result, failed-task `tasks/result` payload, task_not_ready, and three callback-contract violations.
---

## Phase 8 — Verify & release

- [x] `mix compile --warnings-as-errors` clean
  **Done:** clean.
- [x] `mix format --check-formatted` clean
  **Done:** clean.
- [x] `mix credo --strict` clean
  **Done:** clean, 1147 mods/funs, 0 issues.
- [x] `mix dialyzer` 0 errors
  **Done:** 0 errors (two pattern_match_cov warnings introduced during the work were fixed, not skipped).
- [x] `mix sobelow --exit medium` clean (re-verify the two `.sobelow-conf` suppressions are still genuine false positives)
  **Done:** clean. Re-verified: Traversal.FileModule is still a genuine false positive (3 `File.read!(unquote(view_path))` sites in DSL-generated code, path from the compile-time `view` literal). DOS.StringToAtom is no longer detected at all, so the stale skip was removed from .sobelow-conf.
- [x] `mix test` green; `MIX_ENV=test mix coveralls` ≥ 86% with `plugs/oauth.ex` materially above 76.0%
  **Done:** 958 tests green (4 doctests, 9 properties). coveralls 90.0% total; plugs/oauth.ex 86.3% (was 76.0%). (930 / 89.8% before the second review round.)
- [x] Phase 0's bare-consumer CI job green
  **Done:** green locally via .github/scripts/bare_consumer_check.sh.
- [x] `mix hex.build` tarball contains no `mix/tasks/`
  **Done:** 60 files, 0 matches for mix/tasks.
- [x] `CHANGELOG.md`: RC9 error codes and S-H2 CORS default flagged as behaviour changes with opt-outs
  **Done:** both in a 'Breaking changes' section with one-line opt-outs, alongside the fail-closed :allowed_origins default and the tasks/* authorization change.
- [x] Re-run `/phx:audit --focus=security` and confirm the authorization findings are closed
  **Done:** two parallel security-reviewer passes over the diff instead of a full re-audit. RC8 CLOSED; RC4/RC7/S-H1/S-H2/S-L2 came back PARTIALLY CLOSED with 7 concrete findings. Six were code defects and are fixed (see below); two are accepted, documented residuals.

---

## Finding coverage (Iron Law #5 — all 50 accounted for)

**P1 owns (31):** RC1, RC2, RC3 (full extraction), RC4, RC5, RC6, RC7, RC8, RC9, RC10, RC11, RC12, RC13, S-H1, S-H2, S-L2, A-L1, T-H1, T-M1, T-M2, T-M3, T-M4, T-M5, T-M6, T-M7, T-M8, T-L1, T-L2, T-L3, T-L4, T-L5

**P2 `hardening-p2-structural` owns (9):** RC14, RC15, A-M1, A-M2, A-M3, A-M4, A-M5, S-L1, S-L3

**P3 `hardening-p3-performance` owns (9):** P-M1, P-M2, P-M3, P-L1, P-L2, D-M1, D-M2, D-M3, D-L1

**Deferred, no task — awaiting your call (1):** D-L2 (nine deps behind, **zero major gaps**; every existing `~>` already admits every update except sobelow's, so this is a routine `mix deps.update` with no `mix.exs` change — not plan-worthy unless you want it pinned to a release).

---

## Post-implementation security review (2026-08-24)

Two `security-reviewer` passes over the working tree, one on RC4/RC7/RC8/S-H1
and one on S-H2/S-L2 plus the transport pipeline. RC8 verified CLOSED
(match-spec guards valid, store and facade agree on all six matrix cells,
custom-store re-filter present). The rest returned defects, all in code this
plan added:

**Fixed:**

- **Templated-resource scope scanned in the reverse of dispatch order.** A
  prepending `Enum.reduce` in `DSL.build_scope_map/2` and
  `Endpoint.component_scopes/2` reversed the scoped-template list, so with two
  overlapping templates the *weaker* scope was enforced while the *stronger*
  template's handler ran. Both now `Enum.flat_map`, preserving declaration
  order. Pinned by `oauth_scope_test.exs` "overlapping templated resources".
- **`scope ""` compiled clean and authorized everyone.** It splits to `[]` and
  `Enum.all?([], _)` is true. `ConduitMcp.Component` already rejected it; the
  DSL did not. Both now share `ConduitMcp.DSL.__validate_scope__!/2`, validated
  at `@before_compile` (the macro only sees AST).
- **`resources/subscribe`, `resources/unsubscribe` and `completion/complete`
  had no scope hook.** Subscribing delivers a scoped resource's change
  notifications and completion enumerates its argument values. All three now
  gate on the referenced resource's or prompt's scope.
- **`Plugs.OAuth` wrote the raw `sub` claim as the principal id.** A verified
  token with no `sub` (routine for client-credentials grants) produced
  `%{id: nil}` — an *authenticated* principal that every consumer reads as
  anonymous, so RC8's fix was bypassed for that population (tasks created
  unowned and world-readable). Now resolved from `:subject_claims`
  (default `["sub", "client_id"]`, integers coerced) and **rejected with 401**
  when none is present. `Principal.rate_limit_key/1` also no longer raises on a
  non-binary id.
- **The cancellation row cap was global, so one unauthenticated client could
  deny cancellation to every other client.** Added a per-scope quota
  (`:cancellations_max_rows_per_scope`, default 256) on an `ordered_set`, so the
  count is a bounded range scan; the global cap remains as a backstop.
- **`:cors_origin` was unvalidated at `init/1`.** `:allowed_origins` accepts a
  list and is documented two bullets above it, so passing a list was a natural
  mistake that produced a `FunctionClauseError` on every request instead of a
  boot-time error. Now raises in `Shared.init/2`.
- **`OriginValidation`'s moduledoc claimed DNS-rebinding coverage it does not
  provide.** After a rebind the attacker's page is *same-origin*, and browsers
  send no `Origin` on a same-origin GET, so the header-less path applies and the
  allowlist never runs. Corrected, with the actual control (`Host` validation,
  not implemented here) and the mitigations named. This is exactly the
  "documentation asserts an invariant the code does not hold" class the plan set
  out to eliminate.

**Accepted residuals, documented in the code:**

- With neither sessions nor auth, the cancellation scope degrades to the client
  IP, so clients behind one NAT share a namespace. Inherent to a stateless
  unauthenticated transport; the moduledoc carries a warning pointing at
  `:session` / `:auth`.
- `:tasks_require_owner` defaults to false and `Tasks.create/2` leaves a task
  unowned, so an unstamped task stays world-readable. Deliberate: the plan
  specified opt-in so the public API stays stable. The matrix is documented on
  `ConduitMcp.Tasks.get/2`.

## Parallel specialist review (2026-08-24, second round)

Five agents: requirements, Elixir idioms, test quality, OTP/concurrency,
security (already run above). **Requirements: 36 MET / 0 PARTIAL / 0 UNMET**,
all 10 Phase 8 gate items met. The other three found **13 real defects in code
this plan added** — all fixed, all pinned by a test.

**One blocker, reachable unauthenticated on both transports (P0):**

- **`Reflect.text/2` raised on any multibyte value.** It byte-clamps at
  `max * 4` and then runs a `/u` regex; the clamp cuts mid-codepoint and `:re`
  *raises* on invalid UTF-8. The handler's rescue reflects the method name
  again, so it raised a second time from inside the rescue: no JSON-RPC
  response, no `:stop` telemetry, a bare adapter 500. A 300-character `€`
  method name reproduced it. `String.replace_invalid/2` between the clamp and
  the regex; boundary walked 195–215 for 3- and 4-byte codepoints in the test.
  This is RC13's own acceptance criterion inverted, and it shipped in the fix.

**Two more that would have broken production traffic:**

- **RC12's mailbox drain ate Bandit's HTTP/2 control frames.** Under h2 the
  Plug runs inside `Bandit.HTTP2.StreamProcess`, and the connection process
  delivers `{:bandit, {:send_window_update, _}}` and `{:bandit, {:rst_stream,
  _}}` to that same mailbox for `chunk/2` to read back selectively. The
  catch-all consumed both: `EventSource.close()` over h2 sends RST_STREAM, not
  a TCP close, so the connection slot RC12 added would have been held for the
  full one-hour lifetime, and lost window credit ends in `FLOW_CONTROL_ERROR`.
  The clause is now guarded to leave `{:bandit, _}` in the mailbox.
- **The supervised `Owner` Agents could crash-loop the consumer's
  application.** `:ets.new/2` raises when the name is taken, which happens
  whenever anything calls `ensure_table/0` between an Owner's exit and its
  restart — a janitor tick is enough. Three failures in five seconds take down
  `ConduitMcp.Supervisor`. All five now share `ConduitMcp.EtsOwner`, which logs
  and degrades to the pre-supervision behaviour.

**The rest:** the cancellation janitor reported evictions under
`[:conduit_mcp, :session, :cleanup]` (and double-published the count);
`function_exported?/3` without `Code.ensure_loaded?/1` silently idles a janitor
under interactive code loading; `true` for `:session_janitor` raised
`CaseClauseError` at boot; `handle_notification/3` was still a hand-written
`case` while `methods/0` published `@notification_methods` (A-L1's drift, closed
for requests only); scope collection lost the map's accidental de-duplication,
so two same-named scoped components emit a "clause cannot match" warning against
*generated* code; `Tasks.list(limit: :infinity)` returned `[]`;
`Principal.put/2` did not normalise `:id`, so a non-scalar id violated `id/1`'s
`@spec` and made `rate_limit_key/1` raise inside the request pipeline.

**Test-quality findings, all fixed:** the idempotence property was a tautology
(driven at a server with no schema, so it asserted `params == params` through
the identity function — moved to `ValidationTest`, which owns the validation
config, and pointed at a coercing schema); manual mode's `-32002` was pinned
nowhere, because `TestServer` overrides every not-found callback, so reverting
`server.ex` would have left the suite green; two `refute errors == []` and two
bare-401 OAuth assertions did not check *which* branch rejected; an `async:
true` module wiped the global cancellation table; the mailbox-drain test slept
once instead of polling and sent a bare `:DOWN` atom rather than a monitor
tuple; telemetry handler ids came from a 27-bit `phash2`.

**One reviewer suggestion rejected:** gating the JWKS TTL-miss path on the
refresh cooldown. The cooldown would override the operator's explicit
`:cache_ttl`, and checking it before the lock preempts the single-flight wait —
a request arriving after the winner recorded `:last_refresh` but before it
published keys would fail instead of waiting. The pile-up it guards against is
already bounded: exactly one process fetches, the rest wait, and the winner
releases the lock as soon as it finishes. Reason recorded at the call site.

**Gates after the review round:** 958 tests (was 930), coverage **90.0%** (was
89.8%), format / `--warnings-as-errors` / `credo --strict` / dialyzer 0 /
sobelow / bare-consumer / hex tarball all clean.

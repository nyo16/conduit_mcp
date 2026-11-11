# 0.11.1 hardening

**Source:** `.claude/audit/summaries/consolidated.md` (audit 2026-11-10, 113 findings) and the per-track
reports in `.claude/audit/reports/`. Finding IDs (D1, SEC-H1, PERF-H1, C1 …) are the audit's; evidence lives there.
**Scope (set by the user, 2026-11-10):** 24 findings in full, 2 in part, 87 deferred. The list is at the end.
**Target:** branch `hardening/0.11.1` from `master` (`6cebe80`), released as 0.11.1.
**Baseline to preserve (verified 2026-11-10):** compile `--warnings-as-errors` (dev + test, and on Elixir 1.18.3 / OTP 27.2) ·
format · `credo --strict` 0 issues · dialyzer 0 on the CI toolchain · sobelow no findings · `mix docs` 0 warnings ·
2425 tests green on seeds 1–4 · coverage 90.4 % (floor 86) · bare-consumer check.
**Baseline to change:** `mix hex.audit` exits 1 today; it must exit 0 after Phase 1.

## Shape of the release

0.11.0 is on Hex. Its dependency requirements admit 23 advisories, and consumers resolve against the published
package, so nothing protects them until 0.11.1 ships. Phases 1 to 3 hold the three HIGH findings. Phases 4 to 6
are the items pulled in on top; they are independent of each other.

**Cut line.** If Phases 4 to 6 run long, 0.11.1 can ship with Phases 0 to 3, tasks 7.1 and 7.2, and Phase 8, and
the rest becomes 0.11.2. That is the user's call; do not make it silently.

## Decisions

| # | Decision | Status |
|---|---|---|
| 1 | SEC-H1: `auth: {:client_credentials, ...}` without `:expected_issuers` raises at config time. No opt-out, because accepting any issuer is the vulnerability | Confirmed by the user |
| 2 | C1: move `Plug.Parsers` below `:authenticate` and `:rate_limit` | Taken |
| 3 | Failed-authentication throttle: opt-in `rate_limit: [before_auth: true]`, which runs the existing limiter before `:authenticate`. Default stays `false` because the documented per-user `key_func` needs the principal | Taken; alternatives in the scratchpad |
| 4 | Dependency floors follow the commented security-floor style already in `mix.exs` | Taken |
| 5 | Every `uses:` in every workflow is pinned to a commit SHA, including the new audit workflow | Taken |
| 6 | The application starts a tasks janitor by default. `ConduitMcp.Tasks.Janitor` stays: it is documented public API and hosts may supervise it | Taken |
| 7 | PERF-M7: both generators emit a precompiled `%NimbleOptions{}`. A manual server that returns a bare keyword schema keeps compiling it per call; caching it would put a `:persistent_term.put` on the request path | Taken |
| 8 | `:strict_mode` and `session: [ttl:]` are removed from the docs. A `:ttl` key under `:session` logs a warning at boot instead of raising, because the key was copied from the docs | Taken |
| 9 | `publish` gets `environment: hex-release` in the workflow. The environment's reviewers and the `v*` tag ruleset are GitHub settings only the user can change | Taken |

## CHANGELOG policy

New `## [0.11.1] - <date>` section above `[0.11.0]`, same structure as 0.11.0. Each breaking bullet names its
opt-out or says why it has none.

- `### Security`: the dependency floors (each package and its advisory range), SEC-H1, SEC-M1, the JWKS private
  members.
- `### Breaking changes`: SEC-H1 (no opt-out). The parse order, for a `key_func` that reads `conn.body_params`
  (use `:message_rate_limit`). The tasks janitor (opt-out: `config :conduit_mcp, :tasks_janitor, false`).
- `### Added`: `:max_body_bytes`, `rate_limit: [before_auth: true]`, `:tasks_janitor`.
- `### Changed`: precompiled validation schemas, the extension-store update, `scripts/release.sh` no longer
  publishes, CI changes.
- `### Removed`: `:strict_mode` and `session: [ttl:]` from the docs (they never did anything).

## Sequencing constraints (do not reorder)

1. **Phase 1 first.** Every later phase is verified on the new lock. If Bandit 1.14.1 breaks streaming
   (task 1.4), stop and report.
2. **2.1 before 2.2, 3.1 before 3.2, 4.1 before 4.2.** Each is the red test or repro for the fix that follows.
3. **3.5 after 3.2.** Both edit the plug list in `Shared.__using__/1`.
4. **5.1 before 6.3.** Both edit `test/conduit_mcp/oauth/jwks_test.exs`.
5. **7.3 after 7.2.** The new workflow is pinned in the same pass as `ci.yml`.
6. **Phase 8 last.** The CHANGELOG describes finished behaviour.

## Convention checks for every task

- Optional deps stay gated: `if Code.ensure_loaded?(Dep)` plus an `OptionalDeps.*!/0` check at init.
- Secrets travel as `%ConduitMcp.Client.Secret{}`; nothing new may `inspect/1` a config or option list.
- Options are validated at `init/1` / `child_spec/1` / boot and raise naming the key. No per-request validation.
- ETS owners stay create-and-idle `ConduitMcp.EtsOwner` with `:public` tables. No `handle_call` gateway.
- `ConduitMcp.Telemetry.events/0` is the single source of truth: an event's metadata keys change there first.
- Every reproduced defect gets a regression test that fails before the fix. Run it red first.
- No `Process.sleep` in tests; timeouts ≥ 200 ms unless the timeout is what the test exercises.
- Real-socket tests: Bandit on `port: 0`, `ip: :loopback`, tagged `:integration`.
- New public options appear in the module docs and the matching guide. `mix docs` stays warning-free.

---

## Phase 0 — Branch

- [x] **0.1 — create `hardening/0.11.1` from `master`.** Confirm `git status --short` is empty and
  `mix deps.get` leaves `mix.lock` unchanged (local `deps/` was stale before the audit).

---

## Phase 1 — Dependency floors [deps]

Findings: D1 (HIGH), D2 (floor), D3, D4, D5, D10, D11 (`plug_crypto` only). Correlations C2, C14, C19, C22.

- [x] **1.1 — raise the floors in `mix.exs`.** Exact text for E1–E5 is in `.claude/audit/reports/deps-audit.md`
  ("The `mix.exs` edits"); copy the comments from there.
  - E1: `{:bandit, "~> 1.14 and >= 1.14.1"}`, replacing the `>= 1.13.1` entry and its comment.
  - E2: `{:jose, "~> 1.11 and >= 1.11.13", optional: true}`.
  - E3: `{:jsv, "~> 0.26 and >= 0.26.2", optional: true}`.
  - E4: new `{:plug_crypto, "~> 2.2 and >= 2.2.1"}` after the plug entry. `lib/` calls `Plug.Crypto.secure_compare/2`
    directly (`plugs/auth.ex`, `client/oauth/callback.ex`), so this is a real dependency, not only a floor.
  - E5: new `{:ssl_verify_fun, "~> 1.1 and >= 1.1.8", optional: true}` after the prom_ex entry.
  - D10, same hunk:
    - hpax: Bandit 1.14 and Mint 1.11 both require `hpax ~> 1.1`, so the `>= 1.0.4` floor can no longer bind.
      Remove the entry and its comment.
    - mint: the comment says "Not used directly". It is (`client/oauth/http.ex` calls `Mint.HTTP1`). Reword to
      "used directly by the OAuth client's pinned-address connection, and as Finch's stack".
    - req: the comment claims `"~> 0.6 and >= 0.6.1"` would exclude 0.7.x. It would not. State the real reason for
      the union or use the equivalent simpler form; do not change which versions are admitted.

  **Acceptance:** `mix deps.get` resolves; the three corrected comments are true against `mix hex.info <pkg>`.

- [x] **1.2 — keep the restated constraints in step (C22).** (req restated as `"~> 0.6 and >= 0.6.1"` too:
  README, `guides/authentication.md`, `@req_deps`.)
  - `lib/conduit_mcp/optional_deps.ex`: `@joken_deps` (`{:jose, "~> 1.11"}`) and `@jsv_deps` (`{:jsv, "~> 0.26"}`)
    take the new requirement strings. They appear in `OptionalDependencyError` messages, so check the tests that
    match on them.
  - `README.md` optional-dependency table: the `:jose` and `:jsv` rows.

  **Acceptance:** no stale jose or jsv requirement string in `lib/`, `README.md` or `guides/`.

- [x] **1.3 — update the lock.** `mix deps.update bandit jose jsv plug_crypto ssl_verify_fun`.
  `~> 0.26 and >= 0.26.2` admits jsv 0.27.0, so the lock will probably move there. The deps auditor inspected the
  0.27.0 tarball (the three functions the adapter calls exist) but did not run it.

  **Acceptance:** `mix hex.audit` exits 0; `mix deps.audit` clean; `mix deps.unlock --check-unused` exits 0;
  `git diff mix.lock` touches only those five packages and their own dependencies (list them in the scratchpad).

- [x] **1.4 — prove Bandit 1.14.1 is compatible.** [test] Item 2 resets (scratchpad); the user accepted 1.14.1 and
  asked for it to be documented (`guides/protocol_eras.md`, "Under HTTP/2"). 413 test:
  `test/conduit_mcp/transport/body_limit_test.exs`. Seeds 1–3: 2429 green. Bandit 1.14.0 is not a drop-in. Its CHANGELOG lists three
  changes that touch assumptions in `lib/`; none has been tested.
  1. *"`read_body` can return more than `:length` bytes."* The transports rely on `length: 1_000_000`, and no test
     covers the oversize path. Add an `:integration` test in `test/conduit_mcp/transport/` that POSTs a body just
     over the limit over a real socket and asserts 413 and that no handler ran.
  2. *"Reset an HTTP/2 stream with ENHANCE_YOUR_CALM when it has 100 unread messages."*
     `ConduitMcp.Transport.SSEStream.await/5` deliberately leaves `{:bandit, _}` messages in the mailbox between
     ticks. Spike: over HTTP/2, hold a streamed `tools/call` and a `subscriptions/listen` stream open while the
     peer sends more than 100 frames that reach the stream process (WINDOW_UPDATE is the likely one). Use the
     Finch/Mint HTTP/2 client already in the test deps. Record what arrives and whether the stream is reset.
     **If it is reset, stop and report with the repro.** Do not drain or discard `{:bandit, _}` messages as a fix:
     Bandit reads them itself on the next adapter call.
  3. *Defaults `max_concurrent_streams` 500 and `max_header_list_size` 262144.* The transports' `:max_streams`
     default is 1 000. Check whether any test or guide assumes more than 500 streams on one connection; note the
     result in the scratchpad and in the guide if it matters to users.

  Then run the whole suite: `mix test --seed 1`, `--seed 2`, `--seed 3`.

  **Acceptance:** 3 green seeds; the 413 test passes; the spike result is in the scratchpad with the frame counts.

- [x] **1.5 — bare-consumer check on the new floors.** Run `.github/scripts/bare_consumer_check.sh`. (exit 0)
  It builds a consumer with no optional deps, so it exercises E1 and E4 only.

  **Acceptance:** script exits 0.

---

## Phase 2 — SEC-H1: bind `client_credentials` to an issuer allowlist [security] [client]

Finding: SEC-H1 (HIGH). A malicious MCP server names its own authorization server in Protected Resource Metadata;
`Discovery.select_issuer/2` accepts any issuer when `:expected_issuers` is `nil`; `ClientCredentials.request/3`
then posts `config.credentials` to that issuer's token endpoint. The same path leaks a `private_key_jwt` assertion.

- [x] **2.1 — reproduce the leak.** [test] Reproduced (scratchpad). Throwaway script under `.claude/plans/hardening-0.11.1/research/`
  using `test/support/client/oauth_fake.ex`: an MCP fake whose PRM lists a second fake authorization server, and a
  client configured with `{:client_credentials, client_id:, client_secret:}` and no `:expected_issuers`. Show that
  the second server's `/token` receives the client's `Authorization: Basic` header or `client_secret` form field.

  **Acceptance:** the scratchpad records whether the leak reproduces as traced. If it does not, stop and report.

- [x] **2.2 — raise at config time.** Red first; `cond` in `credentials/1`. `ConduitMcp.Client.OAuth.Config.credentials/1`: for
  `{:client_credentials, _id}`, after the existing `auth_method == :none` check, return an error when
  `valid[:expected_issuers] in [nil, []]`: "auth: {:client_credentials, ...} needs :expected_issuers: the client's
  credentials are sent to the authorization server the MCP server names". The message names the key and carries
  no option values. Update the `:expected_issuers` option doc: "`nil` accepts any" is no longer true for this grant.

  **Acceptance (tests in `test/conduit_mcp/client/oauth/flow_test.exs`, "client credentials"):**
  - `Config.new!` with `grant: :client_credentials`, credentials and no `:expected_issuers` raises
    `ArgumentError` matching `~r/expected_issuers/`. Same for `expected_issuers: []`. **Red before the fix.**
  - With `expected_issuers: [real_issuer]` and PRM naming a second authorization server, the request fails with
    `:issuer_not_allowed` and the second server's `/token` saw zero requests. One case for `client_secret`, one
    for `private_key`.

- [x] **2.3 — update existing client-credentials configs in tests.** They all omit `:expected_issuers`:
  `test/conduit_mcp/client/secret_scan_test.exs` (`client_credentials/2`), `client/token_leak_test.exs`,
  `client/oauth/connection_test.exs` (two configs), `client/oauth/flow_test.exs` (`cc_config/2` and the two
  `assert_raise` cases, whose order of checks may change).

  **Acceptance:** each passes `expected_issuers: [fake.issuer]`; no assertion other than the config changed.

- [x] **2.4 — correct the docs.** [docs] (`mix docs` checked at the final gate)
  - `guides/client_oauth.md`, "Machine to machine": add `expected_issuers:` to both examples and a row to the
    option table, marked required for this grant.
  - Same guide, security table, "Issuer" row: "credentials are bound to their issuer" was false for this grant.
    State what binds each kind (`pre_registered` by key, `client_credentials` by `:expected_issuers`).
  - `ConduitMcp.Client.OAuth.ClientCredentials` moduledoc example and its sentence about discovery.

  **Acceptance:** `mix docs` 0 warnings; every `{:client_credentials,` example in `lib/`, `guides/` and
  `README.md` sets `expected_issuers`.

---

## Phase 3 — Transport pipeline: parse after authentication, optional pre-auth limiting [transport]

Findings: PERF-H1 (HIGH), SEC-M2, ARCH-12 (body-cap half). Correlations C1, C2. Today `transport/shared.ex` runs
`Plug.Parsers` (1 MB), then `:authenticate`, then `:rate_limit`. A rejected 734 KB body costs 5.29 ms against
10.2 µs, and a failed authentication never reaches the limiter.

- [x] **3.1 — red tests for the order.** [test] (16 red before 3.2, incl. 3.5's) In `test/conduit_mcp/transport/auth_integration_test.exs` and
  `rate_limit_integration_test.exs`, for both `StreamableHTTP` and `SSE`:
  - bearer auth configured, no credential, body is invalid JSON → **401** (today 400).
  - bearer auth configured, no credential, body over the limit → **401** (today 413).
  - rate-limit backend that always denies, body is invalid JSON → **429** (today 400).
  - authenticated and allowed, body is invalid JSON → 400; valid body → handled as before.
  - `:message_rate_limit` still sees the parsed body after the move (one case: a counted method is denied by an
    always-deny message backend).

  **Acceptance:** the first three fail against the current code.

- [x] **3.2 — move the parser and make its limit an option.** (`Shared.parse_body/1`, `:body_parsers` private)
  - In `Shared.__using__/1`: remove `plug(Plug.Parsers, …)` from its current place; add `plug(:parse_body)` after
    `plug(:rate_limit)` and before `plug(:classify_era)`. `:classify_era`, `:message_rate_limit` and the handlers
    read `conn.body_params`, so the parser must stay ahead of them.
  - `Shared.parse_body/1` calls `Plug.Parsers.call/2` with options built **once** in `Shared.init/2`
    (`Plug.Parsers.init(parsers: [:json], json_decoder: JSON, length: max_body_bytes)`) and carried in
    `:shared_private` like the resolved plugs.
  - New transport option `:max_body_bytes`, default `1_000_000`, validated in `Shared.init/2` as a positive
    integer; anything else raises `ArgumentError` naming the key. Follow `stream_private/1`.
  - Watch: `Plug.Router.forward/2` escapes init options at compile time (see the comment on
    `Plugs.RateLimit.default_key_func/1`). The stored parser options must survive `Macro.escape/1`; the existing
    `forward` tests cover this.
  - Nothing in `lib/` between `:match` and the parser reads `conn.params`, `conn.query_params` or
    `conn.body_params` (checked). A host `key_func` that reads `conn.body_params` now sees
    `%Plug.Conn.Unfetched{}`; that is the CHANGELOG note.

  **Acceptance:** the 3.1 tests pass; `max_body_bytes: 10` rejects an 11-byte body with 413 after authentication;
  `max_body_bytes: 0`, `-1` and `"1"` raise at `init/1`; the transport suite is otherwise unchanged.

- [x] **3.3 — correct the docs the move makes wrong.** [docs] (also README "limits raw connections")
  - `ConduitMcp.Plugs.RateLimit` moduledoc, "Default key": it says the plug "bounds raw connections including
    unauthenticated ones". By default a request that fails authentication never reaches it. Say so, and point to
    `before_auth: true` (task 3.5).
  - Both transports' option lists and `guides/rate_limiting.md`: document `:max_body_bytes` and the order
    (authenticate → rate limit → parse → classify era → message rate limit).
  - `CLAUDE.md` "Request Flow" line: add the parse step in its real position.

  **Acceptance:** `mix docs` 0 warnings; no doc claims that failed authentications are rate-limited by default.

- [x] **3.4 — measure.** (8.0 µs vs 8.3 µs after; scratchpad) Re-run the PERF-H1 comparison with a throwaway script (`Plug.Test` through
  `StreamableHTTP.call/2`, logger at `:warning`, drain the `Plug.Test` messages after each call): unauthenticated
  and rate-limited rejections with a small body and a 734 KB body. Delete the script afterwards.

  **Acceptance:** the large-body rejection is within 2× of the small-body one (was about 520×). Numbers go in the
  scratchpad and the CHANGELOG entry.

- [x] **3.5 — opt-in limiting before authentication (SEC-M2).** New key on the existing option:
  `rate_limit: [backend: …, before_auth: true]`. With it, the same `ConduitMcp.Plugs.RateLimit` instance runs
  before `:authenticate` instead of after, so failed authentications are counted and throttled.
  - `Shared.init/2` validates `:before_auth` as a boolean (default `false`) and stores the resolved plug under one
    of two private keys; the plug list gains `plug(:rate_limit_before_auth)` ahead of `plug(:authenticate)`.
    Exactly one of the two positions is active.
  - `Plugs.RateLimit.init/1` already ignores unknown keys; confirm, and confirm the Endpoint's declarative
    `rate_limit` config passes the key through `__endpoint_config__/0`.
  - Docs (`Plugs.RateLimit` moduledoc, `guides/rate_limiting.md`): with `before_auth: true` no principal is
    assigned yet, so `&ConduitMcp.Principal.rate_limit_key/1` falls back to the per-address bucket. Per-user
    limits then belong in `:message_rate_limit`.

  **Acceptance (tests in `rate_limit_integration_test.exs`, recording backend):**
  - `before_auth: true`, bearer auth, wrong token, always-deny backend → 429, and the auth `verify` was never
    called.
  - `before_auth: true`, allow backend, wrong token → 401 and exactly one `hit/3`.
  - default (`false`): wrong token → 401 and zero `hit/3` (today's behaviour, pinned).
  - `before_auth: :yes` raises at `init/1`.

---

## Phase 4 — SEC-M1: keep plain-string credentials out of logs [security] [client]

Finding: SEC-M1 (MEDIUM). Correlations C18, C25. `env:` and `headers:` values given as plain strings stay plain
in start arguments, in `Hub.Manager` state and in config error messages. That supervisor reports print them is
inferred in the audit, not observed.

- [x] **4.1 — red test.** [test] (red on logs, Hub.Manager status, 7 config errors; scratchpad) Extend `test/conduit_mcp/client/secret_scan_test.exs`: start a stdio client with
  a plain `env:` value and an HTTP client with a plain `headers:` value, each a recognisable marker; kill the
  connection; assert the marker is absent from the captured log, from `:sys.get_status/1` of the connection and of
  `Hub.Manager`, and from the message of a deliberately malformed config.

  **Acceptance:** the scratchpad records which of the four surfaces actually leak today (this settles the
  audit's `[INFERENCE]`). At least one assertion is red before 4.2.

- [x] **4.2 — wrap the values.** (no other reader needed a change; client suite green) `Stdio.validate_env/1` and `StreamableHTTP.validate_headers/1` return
  `{name, Secret.new(value)}` for plain strings. `Stdio.child_env/3` and `Client.HTTP.expose/1` already expose
  secrets at the spawn and at the wire. Grep every other reader of the validated `env` and `headers` (hub config
  merging, cache credential identity, telemetry allowlist, tests comparing validated options) and adjust.

  **Acceptance:** the env and header assertions of 4.1 pass; the stdio and HTTP client suites are otherwise unchanged.

- [x] **4.3 — `format_status/1` on `Hub.Manager`.** (also redacts an `{:add, id, config}` message) Replace `:config` with `:redacted` in the reported state,
  as `Client.Connection`, `TokenStore.ETS` and the stdio port owner already do.

  **Acceptance:** the `Hub.Manager` assertion of 4.1 passes.

- [x] **4.4 — config errors and `Inspect`.** (`Client.Config.describe/1`; `@derive {Inspect, except: …}`)
  - Stop inspecting whole option terms in error messages: `client/config.ex` ("options must be a keyword list",
    "expected the transport options to be a keyword list", "expected {module, keyword_opts}") and
    `client/hub/config.ex` ("Hub options must be a keyword list", "options for hub server … must be a keyword
    list", both `validate_servers` messages). Name the key and describe the shape received, not its contents.
  - `Inspect` implementations for `ConduitMcp.Client.Config` and `ConduitMcp.Client.Hub.Config` that omit the
    transport options and `:servers`.

  **Acceptance:** the malformed-config assertion of 4.1 passes; existing tests that match these messages are
  updated to the new wording and still identify the failing key.

---

## Phase 5 — Small server fixes

- [x] **5.1 — D2: drop private JWK members before a JWKS key is stored.** [security] (`public_only/1`)
  `ConduitMcp.OAuth.KeyProvider.JWKS.decode_jwks/2`: for keys with `kty` in `RSA`, `EC`, `OKP`, drop
  `d p q dp dq qi oth`. A verifier never needs them, and an RSA key with `d` and no CRT values is what jose
  factors on parse (EEF-CVE-2026-65631). Leave other key types untouched.

  **Acceptance:** a `jwks_test.exs` case serves an RSA key that carries `d`; the cached key has no private
  member and a token signed with that key still verifies.

- [x] **5.2 — PERF-M5: bind the key in the extension store's compare-and-swap.** [otp/ets] (244.6 → 0.64 µs)
  `ConduitMcp.Ext.Tasks.EtsStore.swap/3` puts the key in a guard, so every update scans the table under its lock
  (230 µs at 10 000 rows against 1.0 µs). Use the match head
  `{{task_id, :"$2"}, [{:"=:=", :"$2", {:const, old}}], [{{{:const, task_id}, {:const, new}}}]}` and add
  `write_concurrency: true` to `table_opts/0`. Use `true`, not `:auto`: `:auto` turns on decentralized counters,
  which slows the `:ets.info(:size)` cap check (PERF-L2).

  **Acceptance:** the existing store tests pass, including the one that proves a superset map does not match;
  a new case shows two processes swapping different tasks both succeed; a throwaway measurement at 10 000 rows
  goes in the scratchpad.

- [x] **5.3 — PERF-M7: precompile the validation schemas.** (`SchemaBuilder.dual/1`; deleted the two endpoint tests that pinned a keyword-list tuple) Both generators emit the clean schema as a keyword
  list, so `NimbleOptions.validate/2` compiles and meta-validates it on every `tools/call` and `prompts/get`
  (20 to 51 % of the handler). Emit `NimbleOptions.new!(clean_schema)` as the second tuple element in
  `DSL.SchemaBuilder.generate_validation_lookup_functions/2` and in `Endpoint`'s
  `generate_tool_validation_clauses/1` and `generate_prompt_validation_clauses/1`.
  `Validation.validate_with_schema/3` hands that element to `NimbleOptions.validate/2`, which accepts the struct.
  - Grep every other reader of the tuple's second element (in `validation.ex` and in tests) for code that
    treats it as a keyword list.
  - `nimble_options` is pinned to exactly 1.1.1, so the struct embedded in a consumer's compiled server matches
    the library that reads it.
  - Decision 7: a manual server's bare schema is not cached.

  **Acceptance:** the suite passes unchanged; `mix bench validation` before and after goes in the scratchpad,
  with the 20-parameter case moving toward the auditor's precompiled figure (15 312 ns → about 2 688 ns for the
  validate step).

- [x] **5.4 — ARCH-09: start a tasks janitor.** [otp] (also dropped the now-redundant janitor children from both task examples) The default store's cap counts terminal rows, and nothing
  sweeps them unless the host adds a janitor.
  - `Application.tasks_children/0` adds `janitor(:tasks_janitor, defaults, ConduitMcp.Tasks.Janitor.Default)`
    with `store: ConduitMcp.Tasks`, `ttl: :timer.hours(1)`, `interval: :timer.minutes(5)` (today's
    `Tasks.Janitor` defaults), `name: ConduitMcp.Tasks.Janitor.Default`,
    `telemetry_event: [:conduit_mcp, :tasks, :cleanup]`, `noun: "terminal tasks"`. The key accepts `true`,
    `false` or a keyword list, like the other two janitor keys.
  - The registered name must differ from `ConduitMcp.Tasks.Janitor`, which a host's own child uses by default.
  - Watch: `Telemetry.events/0` lists no metadata keys for `[:conduit_mcp, :tasks, :cleanup]`, while
    `Session.Janitor` emits `%{store: store}`. Give the event one shape: update `events/0`, its moduledoc
    section and `ConduitMcp.Tasks.Janitor`'s own emit, and check `ConduitMcp.PromEx`.
  - Docs: `ConduitMcp.Application`, `ConduitMcp.Tasks.Janitor` (say the application now starts one),
    `CLAUDE.md` (the child list, and "both janitor keys" becomes three).

  **Acceptance:** a default boot lists the new child; `config :conduit_mcp, :tasks_janitor, false` omits it; an
  invalid value raises at boot naming the key (test through `Application.janitor/3`, as the existing janitor
  tests do); the telemetry contract test passes.

- [x] **5.5 — SEC-M7: owned tasks in the legacy examples.** [docs] (oban example lock moved bandit/plug_crypto to the new floors so it compiles; its `test/telemetry_test.exs` setup still calls `create/2` — a test, not an example of creating a client's task) `Tasks.create/2` stores no owner, and an
  unowned task is readable and cancellable by every caller unless `:tasks_require_owner` is set.
  Change to `ConduitMcp.Tasks.create(task_id, meta, ConduitMcp.Tasks.owner(conn))` in the `task/2` `@doc` example
  in `lib/conduit_mcp/dsl/helpers.ex`, `examples/oban_tasks_server/lib/oban_tasks_server/server.ex` and
  `examples/async_tasks_server/server.ex`, and recommend `config :conduit_mcp, :tasks_require_owner, true` beside
  each.

  **Acceptance:** no two-argument `Tasks.create(` remains in `lib/` docs, `guides/` or `examples/`; the examples
  still compile.

- [x] **5.6 — T15, ARCH-29: remove options that nothing reads.** [docs] (also `Session.Store` moduledoc and an `Application` comment)
  - `:strict_mode`: remove from the `ConduitMcp.Validation` moduledoc, `README.md`, and the two tests that set it
    (`test/conduit_mcp/endpoint_test.exs`, `endpoint_integration_test.exs`).
  - `session: [ttl: …]`: remove from the examples in `ConduitMcp.Session` and `ConduitMcp.Session.EtsStore`;
    point to `config :conduit_mcp, :session_janitor, ttl: …`. In `StreamableHTTP.validate_session_config!/1`, log
    one warning at init when `:ttl` is present, naming the key that does work.

  **Acceptance:** `grep -rn strict_mode lib README.md guides test` shows only the unrelated OpenAI adapter helper;
  a test captures the `:ttl` warning; `mix docs` 0 warnings.

---

## Phase 6 — Tests on security paths [test]

- [x] **6.1 — T1: reach the OAuth plug's own `nbf` and issuer checks.** (`validate_claims/2` now `@doc false` public; coveralls.json: 417 → 3 hits, 420 → 1, 426 → 1) `validate_nbf/1` and the mismatch branch
  of `validate_issuer/2` in `lib/conduit_mcp/plugs/oauth.ex` have 0 hits: the tests named for them are rejected
  earlier by Joken. Add an accept case (`nbf` one minute in the past → 200) and cases that reach
  `validate_claims/2` with a future `nbf`, a malformed `nbf` and a wrong `iss`. If Joken always rejects those
  first, expose `validate_claims/2` as `@doc false` and call it directly.

  **Acceptance:** `mix coveralls.json` shows hits on all three clauses.

- [x] **6.2 — T6: exercise the loopback one-shot guard.** (mutation check: guard → `if true` fails the new test and the old one; restored) The test "serve exactly one callback" accepts either
  outcome and passes with the guard removed. Call `ConduitMcp.Client.OAuth.Loopback.Plug.call/2` twice with the
  same options through `Plug.Test`: 200 then 410, and exactly one `{ref, :callback, _}` message. Add a
  `GET /other` → 404 case and an `?error=access_denied` case asserting the "not granted" page.

  **Acceptance:** removing the `:atomics.compare_exchange/4` guard locally makes the new test fail (mutation
  check; restore it afterwards).

- [x] **6.3 — T7: remove the six finite `Process.sleep` calls.** (gate message is `{:fetching, pid}` as in the file; seeds 1–3 and `--max-cases 4` green)
  - `test/conduit_mcp/oauth/jwks_test.exs` (two): reuse the gate already in the file (the stub sends
    `{:holding, self()}` and blocks on `receive :publish`; assert `Task.yield(late, 200) == nil`; then publish).
  - `test/conduit_mcp/transport/sse_test.exs` (four, in `drained?/2`, `queue_settles_at/3`, `slots_reach?/2`):
    replace with `ConduitMcp.Test.Client.Harness.eventually/2`.

  **Acceptance:** no finite `Process.sleep` in any `test/**/*_test.exs`; both files green on seeds 1 to 3 and
  under `--max-cases 4`.

---

## Phase 7 — Release gating and CI [ci]

Findings: D6, D7, D8, SEC-M5, SEC-L3. Correlations C12, C13, C14, C15.

- [x] **7.1 — one publisher (D7).** (steps 1/4–4/4; Actions URL from `git remote get-url origin`) `scripts/release.sh` pushes the tag, which makes CI's `publish` job run
  `mix hex.publish`, and then publishes again locally past every CI gate except `mix test` and `mix hex.build`.
  End the script after the tag push: remove the publish prompt and the local `mix hex.publish`, renumber the
  steps, and print the repository's Actions URL. Keep the pre-checks and the tag rollback on a failed push.

  **Acceptance:** `grep -n 'hex.publish' scripts/release.sh` is empty; `bash -n scripts/release.sh` passes.

- [x] **7.2 — scheduled advisory audit (D6).** (YAML parses; `mix hex.audit` 0, `mix deps.audit` clean)
  - New `.github/workflows/audit.yml`: `on: {schedule: [{cron: "17 5 * * *"}], workflow_dispatch: {}}`,
    `permissions: contents: read`, the same `ELIXIR_VERSION` / `OTP_VERSION` as `ci.yml`, steps
    `mix deps.get`, `mix hex.audit`, `mix deps.audit`.
  - `ci.yml`, `audit` job: rename the step "Check for retired packages" to "Check for advisories and retired
    packages". `mix hex.audit` is the step that reports advisories; `mix deps.audit` saw 0 of the 23.

  **Acceptance:** both workflow files parse as YAML; the new job's commands exit 0 locally on the new lock.

- [x] **7.3 — pin actions by SHA (SEC-M5, D8).** (no `uses:` without a SHA; tag → SHA in the scratchpad) Every `uses:` in `ci.yml` and `audit.yml`
  (`actions/checkout`, `erlef/setup-beam`, `actions/cache`) becomes a 40-character commit SHA with a `# vX.Y.Z`
  comment. Resolve each with `git ls-remote https://github.com/<owner>/<repo> 'refs/tags/v*'` and take the newest
  tag on the major already in use. Add `.github/dependabot.yml` with a weekly `github-actions` entry so the pins
  move.

  **Acceptance:** `grep -n 'uses:' .github/workflows/*.yml` shows no line without a 40-character SHA; the
  scratchpad lists tag → SHA for each action.

- [x] **7.4 — the publish job (SEC-L3, D8, SEC-M5).** (the specified grep matched three lines; fixed here and in `release.sh`, see scratchpad)
  - Replace the `sed` that rewrites `@version` from the tag. Instead read the committed version and fail when the
    tag differs: compare `${GITHUB_REF#refs/tags/v}` with the version from `mix.exs` (the same `grep` and `cut`
    `release.sh` uses), `exit 1` on mismatch. No tag text is ever written into a file that `mix` evaluates.
  - Add `environment: hex-release` to the `publish` job.

  **Acceptance:** the workflow parses; a dry run of the comparison in a shell passes for `v0.11.1` and fails for
  `v0.11.2` and for `v0.11.1#{1}`.

---

## Phase 8 — Release preparation [docs]

- [x] **8.1 — fix the Dialyzer recipe in `CLAUDE.md`.** (`MIX_BUILD_PATH="$PWD/_build/ci_118_dev"`; passed verbatim on 1.18.3/27.2) `MIX_BUILD_PATH=/tmp/cm_build_118_dev` fails on macOS now
  that `abnf_parsec` is in the tree: `/tmp` is a symlink and Mix's relative `priv` link dangles. Use a build path
  that is not behind a symlink (`/private/tmp/...` works on macOS; a directory under `_build/` works everywhere)
  and say why in one sentence.

  **Acceptance:** the documented command, run verbatim under Elixir 1.18.3 / OTP 27.2, reaches "done (passed
  successfully)".

- [x] **8.2 — CHANGELOG and version.** (also CLAUDE.md child list, janitor keys and test count) `## [0.11.1]` per the policy above; `@version "0.11.1"` in `mix.exs`; the
  compare link at the bottom of `CHANGELOG.md`. The README install line stays `~> 0.11`.

- [x] **8.3 — full gate.** (all green; scratchpad "Final gate") All on the new lock:
  - `mix compile --warnings-as-errors` and `MIX_ENV=test mix compile --warnings-as-errors`
  - `mix format --check-formatted`, `mix credo --strict`
  - `mix test` on seeds 1, 2, 3; `MIX_ENV=test mix coveralls` ≥ 86 % (expect about 90 %)
  - `mix sobelow --config`, `mix hex.audit` (**exit 0**), `mix deps.audit`, `mix deps.unlock --check-unused`
  - `mix docs` 0 warnings; `mix hex.build`
  - `.github/scripts/bare_consumer_check.sh`
  - CI toolchain (Elixir 1.18.3 / OTP 27.2): `mix compile --warnings-as-errors` and `mix dialyzer` with the
    recipe from 8.1, 0 errors

  **Acceptance:** every line green; results recorded in the scratchpad.

---

## For the user (not agent tasks)

- Check whether the `audit` job on GitHub is already red. `gh` is not authenticated in the agent's environment.
- Create the `hex-release` environment with required reviewers, and a ruleset restricting who can create `v*`
  tags. Without them, task 7.4's `environment:` line protects nothing.
- Decide whether SEC-H1 warrants a security advisory for 0.11.0, and whether 0.11.0 should be retired on Hex once
  0.11.1 is out.
- Tag and publish. After 7.1 the tag push is the only publish path, and after 7.4 the tag must equal `@version`.

## Risks

- **Scope.** The plan grew from 19 to 35 tasks. The security release now waits on client config changes, two
  code generators and CI work. The cut line above exists for this.
- **Bandit 1.14.1 may reset long-lived HTTP/2 streams** (task 1.4, item 2). This is the one item that can block
  the release. If it does, the choice is between a streaming fix and shipping the other floors with Bandit left
  at a floor that still carries advisories.
- **jsv will probably lock to 0.27.0**, which nobody has run. If the suite fails on it, cap the requirement at
  `"~> 0.26.2"` for this release and note it.
- **Three breaking changes in a patch release:** SEC-H1 (hosts using `client_credentials` fail at boot until they
  add the option), the parse order (a `key_func` that reads the body), and the tasks janitor (terminal tasks are
  swept after one hour by default where they used to live until restart).
- **Wrapping every header and env value in `Secret`** (4.2) changes what validated client options look like.
  Anything that compares or encodes them breaks loudly (JSON-encoding a `Secret` raises), which is the intent,
  but it may reach further than the two transports.
- **Precompiled schemas** (5.3) change the second element of the tuple that `__validation_schema_for_tool__/1`
  returns. The function is `@doc false`, but a host that calls it sees a struct where a keyword list was.
- **Optional floors (E2, E3, E5) bind for a consumer only if Mix applies them through the optional entry.** This
  was already inferred, not proven, for mint and hpax (D17, deferred).

## Findings covered

| | IDs |
|---|---|
| In full (24) | D1, D2, D3, D4, D5, D6, D7, D8, D10 · SEC-H1, SEC-M1, SEC-M2, SEC-M5, SEC-M7, SEC-L3 · PERF-H1, PERF-M5, PERF-M7 · ARCH-09, ARCH-29 · T1, T6, T7, T15 |
| In part (2) | ARCH-12 (`:max_body_bytes` added; `Plug.Logger` still forced) · D11 (`plug_crypto` declared; `:telemetry`, `:crypto`, `thousand_island` still undeclared) |

SEC-M2 counts as covered because the limiter can now run before authentication; it is opt-in, so by default a
failed authentication is still not rate-limited. SEC-M5's reviewers and tag ruleset are the user's GitHub settings.

## Deferred (87 findings; confirmed by the user's selection, 2026-11-10)

Some already have tasks in `hardening-p2-structural` and `hardening-p3-performance` (written against the August
audit; their line numbers are stale).

**Next batch**
- Security: SEC-M3, SEC-M4, SEC-M6, SEC-L1, SEC-L2, SEC-L4 to SEC-L15.
- Performance: PERF-M1 to PERF-M4, PERF-M6, PERF-M8 to PERF-M11, PERF-L1 to PERF-L11.
  (P3 covers PERF-L6 as P-L1 and PERF-L11 as P-M1.)
- Architecture: ARCH-08, and the rest of ARCH-12.
- Tests: T2 to T5, T8 to T14, T16 to T20.
- Dependencies: D9, D12, D13, D14, D15, D16, D17, D18, and the rest of D11.
  (P3 covers D9 as D-M1, D12 as D-M3, D13 as D-L1.)

**Structural (fold into P2)**
- ARCH-01 to ARCH-07, ARCH-10, ARCH-11, ARCH-13 to ARCH-28.
  (P2 covers ARCH-04 as A-M2/A-M3, ARCH-07 as A-M1, ARCH-19 as RC15 and A-M5.)

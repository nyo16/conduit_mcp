# 0.11.1 review fixes

**Source:** `.claude/plans/hardening-0.11.1/reviews/hardening-0.11.1-triage.md` (16 findings, all approved by the user
2026-11-10; 0 skipped, 0 deferred). Per-agent evidence: `.claude/plans/hardening-0.11.1/reviews/*.md`.
**Branch:** `hardening/0.11.1` (uncommitted work from `.claude/plans/hardening-0.11.1/plan.md`). Same release, 0.11.1.
**Baseline to keep:** compile `--warnings-as-errors` (dev, test, Elixir 1.18.3/OTP 27.2) · format · credo `--strict` 0 ·
Dialyzer 0 on 1.18.3/27.2 (`MIX_BUILD_PATH="$PWD/_build/ci_118_dev" MIX_ENV=dev mix dialyzer`) · 2470 tests green on
seeds 1–3 · coverage ≥ 90 % · `mix docs` 0 warnings · bare-consumer check · `mix hex.audit` exit 0.

## Finding → task map

| Finding | Task |
|---|---|
| W3 precompiled schema unpinned | 4.1 |
| W4 Phoenix `forward` caveat | 2.1 |
| W5 tasks janitor vs a host's longer TTL | 2.2 |
| W6 `HEX_API_KEY` scope | 5.1 |
| W7 secret-scan restart barrier | 4.2 |
| W8 SEC-M1 gaps | 1.1 |
| W9 test gaps | 4.3 |
| S1 hand-built `%OAuth.Config{}` bypass | 1.2 |
| S2 strip JWK private members in the plug | 1.3 |
| S3 `before_auth` `key_func` doc | 2.3 |
| S4 publish job hardening | 5.2 |
| S5 `release.sh` token in URL | 5.3 |
| S6 rescue a store's cleanup | 3.1 |
| S7 wording nits | 2.4 |
| S8 weak concurrency tests | 4.4 |
| S9 `validate_claims/2` public for tests | 1.4 |

## Decisions (user, 2026-11-10)

| # | Decision |
|---|---|
| 1 | W3: restore shape tests: `{keyword, %NimbleOptions{}}` for an Endpoint and a DSL server; a keyword list for an unknown param type |
| 2 | S9: move the plug's own claim checks into an internal module both the plug and the tests call |
| 3 | S6: rescue and log in `ConduitMcp.Session.Janitor`; the janitor keeps its schedule |
| 4 | W6: document only (the setting is GitHub's) |

## Conventions for every task

- Red test first for every behaviour change; run it red, then fix.
- No new `inspect/1` of an option or config term; Secrets stay `%ConduitMcp.Client.Secret{}`.
- No `Process.sleep` in tests; timeouts ≥ 200 ms unless the timeout is under test; real-socket tests `:integration`.
- Per task: `mix compile --warnings-as-errors`. Per phase: affected tests + `mix credo --strict`.

---

## Phase 1 — Credential and claim hardening [security]

- [x] **1.1 — SEC-M1 gaps (W8).** Done — red on all three, then green. `:sys.get_status/1` returns the caller's raw
  `:sys` debug list verbatim (`sys.erl` `get_status/5`), so `format_status/1` can only govern the formatted part: the
  test asserts on that (5th status element), and a mutation (`:log` not replaced) turns it red. Also took 2.4's
  `describe/1` bitstring clause.
  - `lib/conduit_mcp/client/oauth/config.ex:342`: `new(other)` returns
    `"expected OAuth options as a keyword list, got #{ConduitMcp.Client.Config.describe(other)}"`.
  - `lib/conduit_mcp/client/config.ex:471`: `@derive {Inspect, except: [:transport, :assigns]}` (the connection's
    `format_status/1` already treats `:assigns` as host data).
  - `lib/conduit_mcp/client/hub/manager.ex:67`: `format_status/1` also replaces `:log` with `[]`, as
    `TokenStore.ETS` does.

  **Acceptance:** extend the SEC-M1 test in `test/conduit_mcp/client/secret_scan_test.exs`: an `OAuth.Config.new/1`
  with a map holding the header marker returns an error without it; `inspect/1` of a client config whose
  `:assigns` holds the marker omits it; `:sys.get_status/1` of a hub manager after `:sys.log(manager, true)` and a
  call carries no marker. Red before the fix.

- [x] **1.2 — hand-built `%OAuth.Config{}` (S1).** Done — `missing_issuers/0` shared; the transport's
  `{:oauth, %Config{}}` clause now runs `Config.new/1`. `client/oauth/config.ex:331`: `new(%__MODULE__{grant:
  :client_credentials, expected_issuers: issuers})` when `issuers in [nil, []]` returns the same error as
  `credentials/1`; any other struct passes as today. Keep the message in one function used by both paths.

  **Acceptance:** `test/conduit_mcp/client/oauth/flow_test.exs` "client credentials": a struct built from a valid
  config with `expected_issuers: nil` is rejected by `Config.new/1` and by `Client.child_spec/1` (transport
  `auth: {:oauth, config_struct}` or the path that accepts a struct; check which one does). Red first.

- [x] **1.3 — strip private JWK members in the OAuth plug (S2).** Done — end-to-end red: a Static RSA JWK with a
  malformed `p` raised `CaseClauseError` in jose (not rescued); now verifies. Plus `public_key/1` on RSA/EC/OKP/oct.
  - Move `public_only/1` and `@private_members` from `OAuth.KeyProvider.JWKS` to `ConduitMcp.OAuth.KeyProvider`
    as `@doc false public_key/1` (compiled unconditionally: it is a map operation, no Req or Joken).
  - `JWKS.decode_jwks/2` calls it; `Plugs.OAuth.fetch_signing_key/2` maps the provider's key through it before
    `create_signer/2`. `oct` keys are untouched (their `k` is the secret the HS signer needs).

  **Acceptance:** `test/conduit_mcp/plugs/oauth_test.exs`: a Static key provider holding a full private RSA JWK
  still verifies a token, and the signer is built from the public members only (assert via a custom key provider
  that records nothing; or assert `KeyProvider.public_key/1` on RSA/EC/OKP/oct directly plus one end-to-end token).
  The existing JWKS test stays green.

- [x] **1.4 — claims module (S9).** Done — `lib/conduit_mcp/plugs/oauth/claims.ex`; bare-consumer check OK.
  - New `ConduitMcp.Plugs.OAuth.Claims` (`@moduledoc false`, not behind the Joken guard: pure map checks) with
    `validate(claims, issuer, audience) :: {:ok, map()} | {:error, atom()}` holding `validate_exp`, `validate_nbf`,
    `validate_issuer`, `validate_audience` from `lib/conduit_mcp/plugs/oauth.ex:395-440`.
  - `Plugs.OAuth` calls it; `validate_claims/2` and its `@doc false` disappear from the plug.
  - `test/conduit_mcp/plugs/oauth_test.exs`: the direct test calls `Claims.validate/3`.

  **Acceptance:** OAuth plug suite green; `MIX_ENV=test mix coveralls.json` shows hits on the future-`nbf`,
  malformed-`nbf` and wrong-`iss` clauses (now in `claims.ex`); bare-consumer check passes (the module compiles
  without Joken).

## Phase 2 — Documentation [docs]

- [x] **2.1 — Phoenix `forward` (W4).** `README.md:288-297` "Phoenix Integration", `guides/rate_limiting.md`
  _Done — throwaway Plug.Builder check: plug above Plug.Parsers → no token 401 body unread, token + 2 KB over a
  100-byte limit 413; below → 401 body read, 200 (limit ignored). Script deleted; docs 0 warnings._
  "Request order", both transport moduledocs (`:max_body_bytes`). Say that a Phoenix endpoint's `Plug.Parsers` (8 MB
  default) runs before the router, so under `forward` the body is read before authentication and
  `:max_body_bytes` has no effect. Show the fix: a small plug placed **above** `plug Plug.Parsers` in the endpoint
  that matches the MCP path prefix and calls `Plug.forward/4` into the transport, then halts.

  **Acceptance:** a throwaway `Plug.Builder` pipeline (`Plug.Parsers` 8 MB, then the documented forwarding plug
  above it) shows an unauthenticated over-limit body answered 401 with the body unread; and with the plug placed
  below `Plug.Parsers`, the parser runs first. Script deleted afterwards; `mix docs` 0 warnings.

- [x] **2.2 — tasks janitor vs a host's longer TTL (W5).** `CHANGELOG.md` breaking bullet "The application starts a
  tasks janitor", `ConduitMcp.Tasks.Janitor` moduledoc, `ConduitMcp.Application` moduledoc: the shortest sweep wins,
  so a host that runs its own `ConduitMcp.Tasks.Janitor` with a longer `ttl` must set
  `config :conduit_mcp, :tasks_janitor, ttl: ...` or `false`.

- [x] **2.3 — `before_auth` `key_func` (S3).** `ConduitMcp.Plugs.RateLimit` moduledoc "Failed authentications" and
  `guides/rate_limiting.md` `:before_auth` row: before authentication nothing about the caller is verified, so a
  `key_func` must not key on a value the caller asserts (a header, a claimed user id): anyone could fill a victim's
  bucket. Key on the client address (the default).

- [x] **2.4 — wording nits (S7).** _Done — checked: before parsing `conn.params` is `%{}` (path params only),
  `query_params` and `body_params` unfetched; CHANGELOG states it and points to `fetch_query_params/1`._
  - `lib/conduit_mcp/client/config.ex:616`: `describe/1` gets `is_bitstring/1` → "a bitstring" before the last clause.
  - `lib/conduit_mcp/transport/streamable_http.ex` `warn_session_ttl` comment: "at `init/1` (boot, or compile time
    under `Plug.Router.forward/2`)".
  - `CHANGELOG.md` parse-order bullet: a `key_func` also sees unparsed `conn.params` (`%Plug.Conn.Unfetched{}` body
    part) — query params are still fetched by `Plug.Router`? **Check** what `conn.params` holds before
    `:parse_body` and state it exactly.

## Phase 3 — Janitor resilience [otp]

- [x] **3.1 — rescue a store's cleanup (S6).** `lib/conduit_mcp/session/janitor.ex:96`: wrap `store.cleanup(ttl)` in
  _Done — red (janitor crashed with the store's RuntimeError), then green: raise → exit → success, same pid,
  warning names the store and kind (`raised RuntimeError` / `exited`), never the marker; no event on failure._
  `try` with `rescue` and `catch :exit` (a store backed by a GenServer or Repo can exit on timeout). On failure log
  one warning naming the store and the exception kind (never the exception's term: a store error may carry
  credentials), emit no telemetry, keep the schedule. `Telemetry.events/0` unchanged.

  **Acceptance:** `test/conduit_mcp/session/janitor_test.exs`: a store whose `cleanup/1` raises, then one that
  exits — the janitor stays alive (same pid) after a forced tick, logs the warning, emits no cleanup event, and the
  next tick runs (a store that succeeds on its second call emits `%{removed: 1}`). Red first.

## Phase 4 — Tests [test]

- [x] **4.1 — pin the precompiled schema (W3).** `test/conduit_mcp/endpoint_test.exs` "validation schema lookups":
  _Done — component names are `echo_tool` / `code_review_prompt`. Mutation (`dual/1` returns the keyword list)
  fails all three new shape tests; restored._
  restore the tool and prompt cases asserting `{full, %NimbleOptions{}}` with the expected keys in `full` and in
  `clean.schema`. `test/conduit_mcp/dsl_test.exs`: the same for a DSL tool, and extend "a param type NimbleOptions
  does not know" to assert its clean schema is a keyword list.

  **Acceptance:** mutation check: `dual/1` returning the plain keyword list fails the new assertions; restore.

- [x] **4.2 — secret-scan restart barrier (W7).** Done early: 1.1's change exposed the race
  (`await_ready` → `:not_started`). Monitor + `assert_receive :DOWN` + `eventually` new registered pid.
  `test/conduit_mcp/client/secret_scan_test.exs:211-233`: monitor each
  connection before `:sys.terminate/2`, `assert_receive {:DOWN, ...}`, then `eventually` the client's registered
  connection pid differs from the dead one before `Client.await_ready/2`.

  **Acceptance:** the test green on seeds 1–3 and under `--max-cases 4`, run 10× in a loop
  (`for i in $(seq 10); do mix test test/conduit_mcp/client/secret_scan_test.exs --seed $i; done`).

- [x] **4.3 — test gaps (W9).** _Done — all three pass first time (coverage of existing behaviour). Custom limit
  uses `max_body_bytes: 200`, not 100: a `tools/call` envelope with the test key is ~110 bytes._
  - `test/conduit_mcp/transport/rate_limit_integration_test.exs` `before_auth`: with
    `key_func: &ConduitMcp.Principal.rate_limit_key/1`, a failed and a successful authentication both hit
    `ConduitMcp.Principal.client_bucket(conn)` (no principal yet); in the default position a successful one hits
    the `"user:"` key.
  - `test/conduit_mcp/client/oauth/flow_test.exs` (or `client/config_test.exs`): `Client.child_spec/1` and
    `Hub.child_spec/1` with `transport: {StreamableHTTP, url: ..., auth: {:client_credentials, client_id:,
    client_secret:}}` and no `:expected_issuers` raise `ArgumentError` matching `~r/expected_issuers/`.
  - `test/conduit_mcp/transport/body_limit_test.exs`: a chunked (`transfer-encoding: chunked`) body over the limit
    → 413, no handler; `max_body_bytes: 100` over a real socket → a 101-byte body 413, a 100-byte body handled.

- [x] **4.4 — weak concurrency tests (S8).** _Done — test deleted; JWKS waiters proven in `await_refresh/3` via
  `:current_stacktrace` (cold-cache excludes the fetcher pid). Seeds 1–3 and `--max-cases 4` green._
  - `test/conduit_mcp/ext/tasks_test.exs:110` "concurrent updates of different tasks both land": it passes with
    PERF-M5 reverted and pins nothing a consumer sees. Delete it (the measurement stays in the scratchpad); the
    existing CAS and superset tests keep the swap's behaviour covered.
  - `test/conduit_mcp/oauth/jwks_test.exs` (stale-waiter and cold-cache tests): replace
    `Task.yield_many(..., 200)` with `eventually` that every waiter's `:current_stacktrace` contains
    `{ConduitMcp.OAuth.KeyProvider.JWKS, :await_refresh, _, _}`, so each is proven blocked on the lock before
    `:publish`; keep `refute_received {:fetching, _}`.

  **Acceptance:** both files green on seeds 1–3 and `--max-cases 4`.

## Phase 5 — CI and release [ci]

- [x] **5.1 — `HEX_API_KEY` scope (W6).** Done (ci.yml comment, release.sh header). CHANGELOG bullet in 6.1.
  Comment on the `publish` job in `.github/workflows/ci.yml` and a header
  note in `scripts/release.sh`: `HEX_API_KEY` must be a secret of the `hex-release` environment (not a repository
  secret), the environment restricted to `v*` tags with required reviewers. Add it to the CHANGELOG `### Changed`
  CI bullet.

- [x] **5.2 — publish job (S4).** Done — YAML parses, 26 `uses:` SHA-pinned; worktree dry run: master commit
  exit 0, throwaway branch commit exit 1. `ci.yml` `publish`: checkout with `persist-credentials: false` and
  `fetch-depth: 0`; a step after the tag check fails unless the tagged commit is on master:
  `git merge-base --is-ancestor "$GITHUB_SHA" origin/master`.

  **Acceptance:** YAML parses; every `uses:` still SHA-pinned; a local dry run of the ancestry check passes for a
  commit on master and fails for one that is not (a throwaway branch commit).

- [x] **5.3 — `release.sh` URL (S5).** Done — `bash -n` OK; all three inputs print `https://github.com/o/r`.
  `scripts/release.sh:79`: strip userinfo before printing
  (`https://user:token@github.com/o/r.git` → `https://github.com/o/r`), keep the `git@github.com:` rewrite.

  **Acceptance:** `bash -n` passes; the transformation run on `git@github.com:o/r.git`,
  `https://x-access-token:ghp_abc@github.com/o/r.git` and `https://github.com/o/r` prints
  `https://github.com/o/r` each time.

## Phase 6 — Verify and record [docs]

- [x] **6.1 — CHANGELOG.** `## [0.11.1]`: `### Security` bullet for 1.1–1.3 (SEC-M1 completion, struct bypass,
  JWK stripping for every key provider); `### Changed` for 3.1 (janitor survives a failing store) and 5.1/5.2.
- [x] **6.2 — full gate.** As the baseline above; record results in the scratchpad; update
  `.claude/plans/hardening-0.11.1/reviews/hardening-0.11.1-triage.md` checkboxes.

## Risks

- **1.3** moves code between a guarded module (`JWKS` compiles only with Req) and an unguarded one; the
  bare-consumer check is the proof that nothing optional leaks into `KeyProvider`.
- **1.4** renames a function tests call; nothing outside the repo calls `validate_claims/2` (it was `@doc false`
  for one day, unreleased).
- **3.1** rescuing broadly can hide a programming error in a store; the warning names the store and kind, and the
  janitor's own bugs (outside `store.cleanup/1`) still crash it.
- **4.4** deletes a test the original plan asked for; the user approved the S8 fix, and deletion is the fix that
  matches the project's test policy (a test that passes with the change reverted catches nothing).

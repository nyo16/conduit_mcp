# Review: P1 post-merge fixes (uncommitted diff on 378ab15)

**Date**: 2026-09-23
**Files Reviewed**: 50 (+2 486 / −921)
**Reviewers**: elixir-reviewer, security-analyzer, testing-reviewer, iron-law-judge, requirements-verifier (compressed by context-supervisor)
**Full detail**: `../summaries/review-consolidated.md` (evidence, code refs and fixes for every item below)

## Summary

| Severity | Count |
|----------|-------|
| Blockers | 0 |
| Warnings | 7 open (+1 resolved during review) |
| Suggestions | 10 groups |

**Verdict**: REQUIRES CHANGES. There are no blockers. However, two WARNINGs are real defects in code this diff adds: W1 is an authorization gap in the G6-S2 fix, and W2 is a telemetry-handler detach that G5-S6 made reachable. W6 and W7 are test gaps on the new scope-bypass and retry paths.

**Gates after the review-time fix (re-run by Main)**:
- `mix compile --warnings-as-errors` passes for dev and test.
- `mix format` and `mix credo --strict` are clean.
- Dialyzer reports 0 errors and sobelow passes at `--exit medium`.
- 1 016 tests pass on seed 0, seed 424242 and a random seed. A passing run prints 6 lines.
- Coverage is 90.8 %, and `mix docs` builds with 0 warnings.
- Bare-consumer check passes, and the hex tarball has no `lib/mix`.
- Smoke tests:
  - h2 repro: after 10 h2 drops, `active_connections()` is 0 and the 11th connection is admitted over both h2 and HTTP/1.1.
  - notif repro: every shape gets a JSON-RPC body back.
  - Tuple and map owners list only their own rows.

REQ rows 63 and 64 were UNCLEAR only because no reviewer re-ran these checks. Main has now run them, so both rows are satisfied.

## Requirements Coverage (from plan `hardening-p1-post-merge/plan.md`)

**Summary**: 59 MET · 2 PARTIAL · 0 UNMET · 3 UNCLEAR. After Main's re-run, rows 63 and 64 are resolved, which leaves 1 UNCLEAR.

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 4 | B1 h2 repro acceptance | UNCLEAR | The checked-in script prints only live rows. Main ran the adapted `/tmp/sse_h2_repro_sse.exs`, which also prints raw rows and the status of the 11th connection. |
| 55 | G7-S2 waiter test proves a waiter existed | PARTIAL | See W5 |
| 61 | Docs describe the end state | PARTIAL | See SG3 ("counter" wording) |
| 63 | Phase 7 gates | MET (re-run) | See the gates above |
| 64 | Phase 7 smoke tests | MET (re-run) | See the gates above |

CHANGELOG policy checks:
- W1 has a `### Fixed` line.
- W6 is a Breaking bullet with the opt-in.
- The header says "Nine" and nine bullets follow, each with an opt-out or a stated reason, so P1 #45 re-scores MET.
- The EtsOwner Added and Fixed entries agree.

## Resolved during review

### R1. Duplicate DSL tool/prompt: first-wins dispatch, last-wins validation

Flagged by IRL W-1 and ELX W1, and verified with a probe. DslScope fixed it in the `dsl.ex` `__before_compile__` (`Enum.uniq_by` into `generate_validation_lookup_functions/2`) and added regression tests under `dsl_test.exs` "duplicate declarations". The CHANGELOG line now says that dispatch, scope lookup and validation all use the first declaration.

## Warnings (7)

### 1. The `:principal_id` guard checks the strategy name, not the verification path
**File**: lib/conduit_mcp/plugs/auth.ex (`init/1`, `do_verify/2`)
**Reviewer**: security-analyzer (VERIFIED by trace)
**Issue**: Two configs pass `init/1` and then run the verifier with every user merged into `"svc"`:
- `auth: [verify: f, principal_id: "svc"]` (the default `:bearer_token` strategy)
- `strategy: :api_key` with `verify:`

**Recommendation**: allow `:principal_id` only when the static `:token` or `:api_key` is configured, and raise otherwise. Add `auth_test` cases for both configs.

### 2. A non-binary `uri` reaches `[:resource, :read]` telemetry, and the default log handler raises and detaches
**File**: lib/conduit_mcp/handler.ex (`handle_resource_read/4`), lib/conduit_mcp/telemetry.ex (default `handle_event/4`)
**Reviewer**: security-analyzer (path VERIFIED, detach INFERRED)
**Recommendation**: emit `uri` only when it is a binary (otherwise `nil`), and document the metadata type as `String.t() | nil`. Render client-sourced metadata in the default handlers through `Reflect.text/2`.

### 3. The `Tasks.Store` `list/1` @doc says a store ignoring `:owner` is "slow rather than unsafe"
**File**: lib/conduit_mcp/tasks/store.ex
**Reviewer**: elixir-reviewer (VERIFIED, PERSISTENT)
**Recommendation**: state that a store ignoring `:owner` must also ignore `:limit`. Honouring `:limit` alone truncates the caller's own rows.

### 4. `assert log == ""` in an `async: true` module
**File**: test/conduit_mcp/security_test.exs (the G5-S6 tests)
**Reviewer**: testing-reviewer (VERIFIED against the ExUnit capture_log contract)
**Recommendation**: refute the regression's own signature instead, e.g. `refute log =~ "FunctionClauseError"`.

### 5. The JWKS waiter test no longer proves a waiter existed (W4 re-opened G7-S2)
**File**: test/conduit_mcp/oauth/jwks_test.exs ("the single-flight waiter also honours :stale_max_age")
**Reviewer**: testing-reviewer + requirements-verifier (INFERRED)
**Recommendation**: add `refresh_cooldown: 0` to that test's config.

### 6. Prompt first-wins dedup (dispatch/scope) is untested
**File**: lib/conduit_mcp/dsl.ex (`first_declaration_wins/1` on prompt clauses)
**Reviewer**: testing-reviewer (INFERRED)
**Recommendation**: add a duplicate `prompt "dup"` scope/dispatch test. First check whether R1's new tests already cover it.

### 7. The EtsOwner self-scheduled retry is untested after G7-S3
**File**: test/conduit_mcp/ets_owner_test.exs, lib/conduit_mcp/ets_owner.ex (`send_after` in `init/1` and `handle_info(:reclaim, …)`)
**Reviewer**: testing-reviewer (INFERRED)
**Recommendation**: make the reclaim interval injectable and test it with a short interval. No 1 s sleeps.

## Suggestions (10 groups)

See `../summaries/review-consolidated.md` SG1–SG10:

1. **SG1**: make duplicate DSL declarations a `CompileError`, as Endpoint already does for tools and prompts. `tools/list` still lists both declarations. The last-clause claim was probed by Main (`/private/tmp/conduit_build/dslscope_matrix.exs`: generated arity-2 → `:second`), so it is verified.
2. **SG2**: SSE does an O(max) sweep on every rejected connect at the cap. Use `:ets.info(t, :size)` instead of `select_count`.
3. **SG3**: "counter" wording is left in `server.ex`, `application.ex` and `ets_owner.ex`.
4. **SG4**: the OAuth `telemetry_reason/1` has no catch-all.
5. **SG5**: `session: true` silently means off, and SSE `:max_connections` is unvalidated (a non-integer fails open). The `session: []` opt-in is untested.
6. **SG6**: JWKS issues:
   - Past `:stale_max_age`, the "refresh failed" error log fires on every request during the cooldown.
   - A cold cache with a failing IdP fetches back-to-back.
   - `refresh_keys/1` checks the cooldown before the lock.
7. **SG7**: the `reclaim/0` comments overclaim: 1-row-scope ties, and concurrent racers.
8. **SG8**: doc precision in the `requestId` @doc and the per-param `type_coercion` docs.
9. **SG9**: robustness:
   - `Cancellation.scope/1` raises on a non-binary principal id.
   - `owner_guard` uses `==` where it should use `=:=`.
   - The atomize check depends on the runtime atom table.
   - The compile time of the nested case chain is unmeasured.
10. **SG10**: test hardening (TST S1–S5 and S7–S11).

## Pre-existing (21, one line each in the consolidated file)

The most notable:
- `requestId` length is unbounded (about 256 MB per scope).
- `connection: keep-alive` on h2 SSE responses breaks strict h2 clients.
- A session is not bound to its creating principal.
- Telemetry metadata carries raw client strings.

## Mandatory Summary Table

| # | Finding | Severity | Reviewer | File | New? |
|---|---------|----------|----------|------|------|
| R1 | Duplicate decl: validation last-wins vs dispatch first-wins (fixed) | WARNING (resolved) | iron-law-judge, elixir-reviewer | lib/conduit_mcp/dsl.ex | Yes |
| 1 | `:principal_id` + `verify:` on bearer/api_key merges users | WARNING | security-analyzer | lib/conduit_mcp/plugs/auth.ex | Yes |
| 2 | Non-binary uri in telemetry detaches default logger | WARNING | security-analyzer | lib/conduit_mcp/handler.ex | Yes |
| 3 | Store list/1 doc "slow rather than unsafe" false | WARNING | elixir-reviewer | lib/conduit_mcp/tasks/store.ex | Yes (persistent) |
| 4 | `log == ""` in async test | WARNING | testing-reviewer | test/conduit_mcp/security_test.exs | Yes |
| 5 | JWKS waiter test doesn't prove waiter | WARNING | testing-reviewer, requirements-verifier | test/conduit_mcp/oauth/jwks_test.exs | Yes |
| 6 | Prompt dedup untested | WARNING | testing-reviewer | lib/conduit_mcp/dsl.ex | Yes |
| 7 | EtsOwner retry timer untested | WARNING | testing-reviewer | test/conduit_mcp/ets_owner_test.exs | Yes |
| SG1–SG10 | See consolidated file | SUGGESTION | various | various | Yes |
| — | 21 pre-existing items | — | various | various | Pre-existing |

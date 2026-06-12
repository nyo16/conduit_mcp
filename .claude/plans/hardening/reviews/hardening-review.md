# Review — feature/hardening (2026-06-11)

**Verdict: PASS WITH WARNINGS** (no blockers; 2 findings fixed in-branch, rest logged)

Agents: elixir-reviewer, security-analyzer (verification-runner skipped — gate already
green; iron-law-judge skipped — PostToolUse hooks verified every edit).

## Security verdict
- Alg-confusion: **CLOSED** — allow-list before key lookup; family re-pinning; `none`/missing
  alg rejected; implicit-HS scoped to Static oct keys only. No new holes found.
- Header injection (WWW-Authenticate, SSE endpoint event): closed.
- JWKS SSRF/DoS surface minimized (https, no redirects, timeouts, 1MB cap).

## Fixed post-review (in this branch)
1. **JWKS stale-key window bounded** — new `:stale_max_age` (default 24h); after that the
   provider fails closed so a revoked key can't validate indefinitely. +1 test (646 total).
2. **Piped `if/2`** in `static_hs_algorithms` → extracted boolean, plain `if`.

## Logged, not actioned (pre-existing or theoretical)
- `normalize_joken_error/1` matches on `inspect(reason)` strings — pre-existing, fragile
  across Joken upgrades. Follow-up candidate.
- 401 message granularity (expired/audience/issuer) is a mild claim-validation oracle —
  pre-existing; detail already in telemetry; candidate for next major.
- `initialize_request?` vs `%Plug.Conn.Unfetched{}` — unreachable in practice: `Plug.Parsers`
  415s non-JSON POSTs before `validate_session` runs.
- JWKS/session ETS tables are owned by the first-toucher process (unlike cancellation/tasks
  tables, which have supervised Owners in application.ex) — pre-existing design trade-off;
  follow-up candidate: add Owners for session + JWKS tables.
- `validate_custom_constraints` skips explicit-`nil` values (NimbleOptions catches them
  downstream with a less specific message) — pre-existing minor UX.

## Final gate (post-fix)
compile --warnings-as-errors ✅ · format ✅ · credo --strict 0 issues (66 checks) ✅ ·
**646 tests** ✅ · dialyzer 0 errors ✅ · coverage 83.5% ✅

# Whole-Codebase Review — conduit_mcp (2026-06-11)

**Verdict: PASS WITH WARNINGS**

Scope: entire library (41 lib files, 79 source files incl. tests). Agents: elixir-reviewer,
security-analyzer, testing-reviewer, iron-law-judge, verification (run by orchestrator —
agent sandboxes blocked Bash/Write; per-agent reports extracted from messages, see scratchpad).

## Verification — all green

- `mix compile --warnings-as-errors` ✅ · `mix format --check-formatted` ✅
- `mix test` ✅ 619 passed (614 tests + 5 properties), 0 failures, 2.1s
- `mix credo --strict` ✅ "no issues" — **but see W5: only 3 checks actually run**

## Warnings (9)

**W1 — ETS `ensure_table` race guards missed in two stores**
`oauth/key_provider/jwks.ex:71-77` and `session/ets_store.ex` (`ensure_table/0`) use bare
check-then-create. Concurrent cold-start requests can both pass the `:ets.whereis` check; the loser
crashes with ArgumentError (500 to client). Identical races in Tasks.EtsStore/Cancellation were fixed
in c8a41f6 with `rescue ArgumentError -> :ok`; these two were missed. Same one-line fix.

**W2 — JWKS fetch lacks transport hardening** `oauth/key_provider/jwks.ex:95-112`
`Req.get(jwks_uri)` with no HTTPS requirement, redirect limit, timeout, or body-size cap; failed
refresh silently serves stale keys. Operator-config footgun (CWE-918-adjacent).

**W3 — JWT algorithm not pinned to allow-list** `plugs/oauth.ex:174-247`
Alg derived from the JWKS key, never from an operator allow-list, and not cross-checked against the
peeked token header. Deriving from the key already blocks classic RS/HS confusion, so this is
defense-in-depth against a hostile/misconfigured JWKS — add an `:algorithms` option (CWE-347).

**W4 — Origin validation off by default** `plugs/origin_validation.ex:25-27`; transports default
`allowed_origins: nil` + `cors_origin: "*"`. MCP spec calls for Origin validation (DNS rebinding).
Missing-Origin requests always pass even with an allow-list — defensible for non-browser clients but
undocumented. Recommend secure defaults for loopback binds + a startup warning when unset.

**W5 — `.credo.exs` accidentally disables nearly all checks**
`checks: %{enabled: [...]}` *replaces* the default check set — only CyclomaticComplexity, Nesting,
and TagTODO run (3 checks on 79 files, 0.04s). The config comments show the intent was to adjust
defaults: use `checks: %{extra: [...]}` (Credo ≥1.7). Until fixed, credo green is weak evidence.

**W6 — `async: true` tests mutate global validation config**
`validation_test.exs:201` and `endpoint_test.exs:552-563` call `update_validation_config/1` under
`async: true`, restored in `after` (which doesn't run on test-process kill). Flake risk for any
concurrent test reading validation config. Fix: `async: false` or per-call config injection.

**W7 — Raw `:telemetry.attach` without `on_exit` (4 sites)**
`session/janitor_test.exs:41,:78`, `tasks/janitor_test.exs:29`, `cancellation_test.exs:78` — on
assertion timeout the handler leaks and fires into a dead PID for the rest of the run. Route through
`TelemetryTestHelper` or register `on_exit` detach.

**W8 — Custom-constraint validation halts at first error** `validation.ex:293`
`reduce_while` returns one violation per round-trip; collect all errors for better client UX.

**W9 — SSE keep-alive loop** `transport/sse.ex:255-267`
`:timer.sleep/1` blocks OTP shutdown signals for up to 15s, and held connections are unbounded
(rate limit covers request rate only). Legacy transport — lower priority.

## Persistent (known, deliberately deferred)

**P1 — Tasks lack owner scoping** `handler.ex:506-556` (CWE-639/BOLA): `tasks/list` returns all
tasks; any caller can get/result/cancel a leaked taskId. Deferred at PR #14 triage; re-scope before
tasks leave experimental status.

## Suggestions (grouped)

- `dsl.ex:1165,1172,1192,1200` — rename `_conn` → `conn` in generated clauses (functions correctly;
  underscore prefix misleads readers). *Demoted from agent BLOCKER — see False Positives.*
- `validation/schema_converter.ex:324` — `String.to_atom` → `String.to_existing_atom` + rescue
  (bounded today; cheap insurance). *(Deduped: iron-law #10 + security #8.)*
- `validation.ex:388` — `byte_size` vs `String.length` for min/max_length on UTF-8 input.
- `plugs/oauth.ex:247` — `alg_from_key(_)` silently defaults to RS256 for unknown key types; log it.
- `validation.ex:456` / `schema_builder.ex:455` / `endpoint.ex:417` — `@custom_constraint_markers`
  triplicated; centralize.
- `endpoint.ex:382` — guard `String.to_existing_atom` on regex-captured URI param names.
- CRLF/header hygiene: `plugs/oauth.ex:274-321` (resource_uri → WWW-Authenticate),
  `transport/sse.ex:237-242` (client Host echoed into endpoint event).
- `transport/streamable_http.ex:161-163` — POSTs without `Mcp-Session-Id` aren't checked to be
  `initialize`.
- Test robustness: prefer `on_exit` over `after` for global teardown (`endpoint_test.exs:552`,
  `endpoint_integration_test.exs:216`); `sse_test.exs:67` 200ms timing window; verify env restore for
  nested describe in `store_dispatch_test.exs:171`; add OAuth key-rollover/refresh tests; add
  `async: true` to `conduit_mcp_test.exs`.
- Run `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit` periodically (not run here).

## False positives removed (verified by orchestrator)

- ❌ "BLOCKER: `_conn` never bound — MFA handlers receive wrong value" (`dsl.ex:1170`): underscore-
  prefixed variables ARE bound; head and body share quote context. Confirmed by clean
  `--warnings-as-errors` compile + 619 passing tests. Kept only as a rename suggestion.
- ❌ Agent-owner processes (`cancellation.ex:162`, `tasks/ets_store.ex:183`): standard supervised
  ETS table-owner pattern — clean.
- ❌ (pre-vetted) `:ets.foldl` + `:ets.delete` interaction; `@optional_callbacks cancel: 1` idiom.

## Verdict rationale

No confirmed blockers; full verification suite green. Warnings are real but bounded: two one-line
race guards (W1), config/hardening footguns (W2-W5), and test-hygiene items (W6-W7). The persistent
tasks-authz gap remains the most significant known issue and already has a deferred-plan decision.

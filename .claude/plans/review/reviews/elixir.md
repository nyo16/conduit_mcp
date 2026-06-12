# Elixir Reviewer — Whole-Codebase Review (2026-06-11)

⚠️ EXTRACTED FROM AGENT MESSAGE (see scratchpad) — agent's Write was denied in sandbox.
Orchestrator note: finding #1 was verified against source and demoted (see consolidated review).

**Agent verdict**: Changes Requested | 2 blockers, 4 warnings, 4 suggestions (pre-filter)

## Critical Issues (as reported by agent)

**1. BLOCKER (DEMOTED → SUGGESTION after verification) — `_conn` in MFA-generated handlers**
`lib/conduit_mcp/dsl.ex:1165-1175`, `:1192-1204`: generated clauses bind `_conn` in the head and
reference `_conn` in the body. Agent claimed the conn "is never bound" — FALSE: underscore-prefixed
variables are bound in Elixir; both head and body share the same quote hygiene context. Verified by
clean `mix compile --warnings-as-errors` and 619 passing tests. Remaining value: rename `_conn` → `conn`
since underscore prefix conventionally signals "unused".

**2. BLOCKER (CONFIRMED, re-rated WARNING) — `JWKS.ensure_table/0` missing race guard**
`lib/conduit_mcp/oauth/key_provider/jwks.ex:71-77`: check-then-create with no
`rescue ArgumentError -> :ok`. Concurrent cold-cache JWKS fetches can crash a request process.
Every other ETS ensure_table (Tasks.EtsStore, Cancellation) was hardened in c8a41f6; this one was missed.

## Warnings

**3.** `validation.ex:293` — `validate_custom_constraints/2` uses `reduce_while`, halting at the first
violation; multi-field bad input returns only one error per round-trip. Use plain `reduce` to collect all.

**4.** `dsl.ex:1278-1300` — templated resource clause generation pipes a list-of-ASTs through
`Enum.find_value` via `unquote(template_clauses)`; works but opaque/fragile maintenance-wise.

**5.** `session/ets_store.ex` — `ensure_table/0` lacks the `rescue ArgumentError` guard that
Tasks.EtsStore has. Inconsistent hardening (same class as #2).

**6.** `transport/sse.ex:255` — `keep_alive_loop/1` blocks in `:timer.sleep/1` for 15s windows,
unresponsive to OTP shutdown signals. Use `Process.send_after` + `receive`. (Legacy transport, lower priority.)

## Suggestions

**7.** `validation.ex:388` — `check_min_length/4` uses `byte_size`, not `String.length`; multi-byte UTF-8
makes min_length/max_length semantics surprising.

**8.** `plugs/oauth.ex:247` — `alg_from_key(_)` silently falls back to `"RS256"` for unknown key types
(e.g., OKP/EdDSA), masking misconfiguration. Add a warning log.

**9.** `validation.ex:456`, `schema_builder.ex:455`, `endpoint.ex:417` — `@custom_constraint_markers`
list triplicated; centralize in SchemaConverter.

**10.** `endpoint.ex:382` — `String.to_existing_atom/1` on regex-captured URI param names without a
rescue guard; an unexpected capture crashes the request process.

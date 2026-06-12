# Iron Law Judge — Whole-Codebase Check (2026-06-11)

⚠️ EXTRACTED FROM AGENT MESSAGE (see scratchpad) — agent's Write was denied in sandbox.

**Files scanned**: 41 (`lib/**/*.ex`) | **Laws checked**: 10 of 22 (LiveView/Ecto/Oban laws N/A) |
**Violations**: 1 real + 1 REVIEW note

## Medium

**[#10] `String.to_atom` with potentially untrusted content — LIKELY**
`lib/conduit_mcp/validation/schema_converter.ex:324`:
`Map.get(original_params, String.to_atom(field_name))` — field_name regex-extracted from a
NimbleOptions error message. Field names are developer-defined (existing atoms), but if NimbleOptions
ever surfaces user-controlled content in error messages this becomes atom-exhaustion risk.
Fix: `String.to_existing_atom/1` + `rescue ArgumentError -> nil`.

**[#13] Agent-owner processes — REVIEW (likely CLEAN)**
`cancellation.ex:162`, `tasks/ets_store.ex:183` — `Agent` used solely to own named ETS tables across
short-lived Bandit request handlers; both supervised under `ConduitMcp.Supervisor`. Valid runtime
reason; no action expected. (Orchestrator: confirmed clean — standard ETS table-owner pattern.)

## Intentional patterns confirmed clean

- `rescue error ->` handler.ex:174 — logged top-level JSON-RPC boundary, not silent swallow
- `rescue _ ->` validation.ex:444 — guards user-supplied custom validator functions
- `rescue _ ->` plugs/oauth.ex:156 — guards `Joken.peek_header/1` raising on malformed tokens
- `rescue ArgumentError ->` server_meta.ex, cancellation.ex, tasks/ets_store.ex — intentional narrow
  ETS/persistent_term race guards (c8a41f6)
- `File.read!` dsl.ex:1262,1337 — inside quote blocks, executes at runtime in generated functions
- `Repo.*` in tasks/store.ex, plugs/auth.ex — @moduledoc example code only

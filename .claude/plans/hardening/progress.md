# Progress: hardening

**State**: WORKING
**Started**: 2026-06-11
**Plan**: .claude/plans/hardening/plan.md (18 tasks, 6 phases)
**Branch**: feature/hardening
**Cycle**: 1/10

Note: DISCOVERING/PLANNING satisfied — plan pre-exists from /phx:plan (review-sourced).
Implementation runs in main session: subagent sandboxes denied Write/Bash earlier this
session, so task routing to implementation agents is not viable.

## Task log

(populated as tasks complete)
- Phase 0 ✅ T1: credo extra: fix + 11 code fixes + 3 config exemptions (66 checks, 0 issues)
- Phase 1 ✅ T2-T7: race guards (jwks, session ets), conn rename (dsl.ex x4), collect-all
  constraint errors + test, grapheme min/max_length + test, atom-safety (schema_converter,
  endpoint atomize_uri_params), markers centralized in SchemaConverter. 621 tests pass.
- Phase 2 ✅ T8-T10: JWKS fetch hardening (+9 tests incl. rollover/T17), alg allow-list +
  family cross-check (+6 tests), header hygiene (+1 test). BONUS FIX: HS signer crash
  (oct JWK map passed where binary secret required — HS path never worked).
- Phase 3 ✅ T11-T13: origin init warning (+2 tests), require_session opt-in (+4 tests),
  SSE receive-based keepalive + base_url/Host sanitizing (+3 tests). Also fixed
  copy-paste bug: SSE server_name read endpoint :version instead of :name.
- Phase 4 ✅ T14-T16: async:false + on_exit for global-config tests, telemetry detach
  on_exit x4, store_dispatch env restore, sse window 1000ms, conduit_mcp_test async.
  Note: "cancellation cleanup telemetry" review suggestion moot — no such event exists.
- Phase 5 ✅ T18: CI already had sobelow+deps.audit+hex.audit jobs (no change needed);
  CHANGELOG updated (Security/Changed/Fixed/Deprecated/Added).

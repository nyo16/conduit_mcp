# Plan: Whole-Codebase Review Hardening

**Source:** `.claude/plans/review/reviews/whole-codebase-review.md` (2026-06-11, verdict: PASS WITH WARNINGS — 9 warnings, ~10 suggestions, 1 known-deferred)
**Approach:** convert every review finding into a task or explicit deferral. Mostly mechanical; OAuth/transport items need light design (specified inline).
**Depth:** standard. **Tags:** `[tooling]` `[core]` `[oauth]` `[transport]` `[test]` `[docs]` `[ci]`

## Completeness map (review finding → task)

| Finding | Disposition |
|---|---|
| W1 ETS race guards (jwks, session store) | T2 |
| W2 JWKS fetch hardening | T8 |
| W3 JWT alg allow-list | T9 |
| W4 Origin validation defaults | T11 |
| W5 credo config neutered | T1 |
| W6 async tests mutate global config | T14 |
| W7 telemetry attach leaks | T15 |
| W8 collect all constraint errors | T4 |
| W9 SSE keep-alive sleep | T13 |
| P1 tasks authz gap | **DEFERRED** (separate plan — prior decision, needs owner-stamping design) |
| S: `_conn` rename | T3 |
| S: `String.to_atom` schema_converter | T6 |
| S: byte_size vs String.length | T5 |
| S: alg_from_key silent RS256 | T9 (folded) |
| S: constraint-marker triplication | T7 |
| S: endpoint.ex:382 rescue guard | T6 (folded) |
| S: CRLF header hygiene (oauth + sse) | T10 (oauth), T13 (sse) |
| S: session not required non-initialize POSTs | T12 |
| S: test robustness misc | T16 |
| S: OAuth rollover test coverage | T17 |
| S: sobelow/deps.audit runs | T18 |

---

## Phase 0 — Lint layer (do FIRST: it gates all later verification) `[tooling]`

### T1 — Fix `.credo.exs` so default checks actually run (W5)
File: `.credo.exs`
- [x] Change `checks: %{enabled: [...]}` → `checks: %{extra: [...]}` keeping the 4 existing customizations (CyclomaticComplexity max 20, Nesting max 4, ExpensiveEmptyEnumCheck disabled, TagTODO exit_status 0). `extra:` adjusts defaults; `enabled:` replaces the whole suite (the current bug).
- [x] Run `mix credo --strict` — 66 checks ran, 135 findings triaged: fixed 11 code issues (5 alias ordering, 3 explicit try→implicit, predicate rename `is_initialize_response?`→`initialize_response?`, apply credo-disable w/ optional-dep justification); config-exempted 3 intentional patterns w/ comments (AliasUsage house style, LargeNumbers only_greater_than 99_999 for JSON-RPC codes, MissedMetadataKeyInLoggerConfig library posture).
- [x] Acceptance: full default suite runs, exit 0. ✅ 619 tests pass.

## Phase 1 — Core correctness `[core]`

### T2 — Race-proof remaining `ensure_table/0` (W1)
Files: `lib/conduit_mcp/oauth/key_provider/jwks.ex:71-77`, `lib/conduit_mcp/session/ets_store.ex` (`ensure_table/0`)
- [x] Mirror the c8a41f6 pattern from `tasks/ets_store.ex`: wrap the `:ets.new` in `rescue ArgumentError -> :ok` (narrow, intentional — Iron-Law-exempt).
- [x] No behavior change otherwise; tables/options unchanged.

### T3 — Rename `_conn` → `conn` in DSL-generated clauses
File: `lib/conduit_mcp/dsl.ex:1165-1175`, `:1192-1204` (4 quote sites in `generate_tool_clauses/1`, `generate_prompt_clauses/1`)
- [x] Rename head + body references. Functionally identical (underscored vars are bound); fixes the misleading "unused" signal. Confirm `mix compile --warnings-as-errors` stays clean.

### T4 — Collect ALL custom-constraint errors (W8)
File: `lib/conduit_mcp/validation.ex:293` (`validate_custom_constraints/2`)
- [x] Replace `reduce_while` (halt-on-first) with `Enum.reduce` accumulating a violations list; return all errors joined/listed in the JSON-RPC error data.
- [x] Update any tests asserting single-error responses; add a test with two invalid fields asserting both appear.
- [x] Keep string-keyed response maps (project convention).

### T5 — Grapheme semantics for min/max_length
File: `lib/conduit_mcp/validation.ex:388` (`check_min_length/4` and the max counterpart)
- [x] `byte_size/1` → `String.length/1` for string values.
- [x] Add UTF-8 test (e.g. `"héllo"` with `min_length: 5` passes).
- [x] CHANGELOG note — user-visible behavior change for multi-byte input.

### T6 — Atom-safety guards
Files: `lib/conduit_mcp/validation/schema_converter.ex:324`, `lib/conduit_mcp/endpoint.ex:382`
- [x] `schema_converter.ex:324`: `String.to_atom` → `String.to_existing_atom` wrapped `rescue ArgumentError -> nil` (field names are developer-defined atoms; nil falls through to existing not-found handling).
- [x] `endpoint.ex:382`: wrap the `String.to_existing_atom` on regex-captured URI params with rescue → treat as no-match (return the existing unknown-resource error) instead of crashing the request process.

### T7 — Centralize `@custom_constraint_markers`
Files: `lib/conduit_mcp/validation.ex:456`, `lib/conduit_mcp/dsl/schema_builder.ex:455`, `lib/conduit_mcp/endpoint.ex:417`
- [x] Single source in `ConduitMcp.Validation.SchemaConverter` (e.g. `def custom_constraint_markers, do: [...]` or a shared module attribute via function); other three call it.
- [x] Pure refactor — no behavior change; full test suite is the gate.

## Phase 2 — OAuth/JWKS hardening `[oauth]`

### T8 — Harden JWKS HTTP fetch (W2)
File: `lib/conduit_mcp/oauth/key_provider/jwks.ex:95-112`
- [x] `Req.get(jwks_uri, connect_options: [timeout: 5_000], receive_timeout: 10_000, max_redirects: 0, retry: false)` (confirm option names against the pinned Req version).
- [x] Enforce `https://` scheme on `jwks_uri` at fetch (or plug init): allow `http://` only with explicit `allow_insecure_jwks: true` (dev/test); otherwise `{:error, :insecure_jwks_uri}` + `Logger.error`.
- [x] Cap response size (Req `:max_body` if available at pinned version, else check `byte_size` of raw body before decode; 1MB cap matches transport convention).
- [x] Keep stale-cache-on-failure behavior but `Logger.warning` when serving stale keys after a failed refresh.
- [x] Tests via `Req.Test` stubs: timeout path, redirect rejected, http rejected, stale-serve warning.

### T9 — JWT algorithm allow-list + header cross-check (W3 + alg_from_key fallback)
File: `lib/conduit_mcp/plugs/oauth.ex:100, :174-247`
- [x] New plug option `:algorithms` (list of strings). Default: `~w(RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512)`; when a static `oct` key is configured, implicitly include its HS alg so existing HMAC setups don't break.
- [x] Validation order: peeked header `alg` ∉ allow-list → reject before key lookup; resolved signer alg must equal header alg → otherwise reject. Generic 401 (no oracle detail in response; detail to Logger).
- [x] `alg_from_key(_)` unknown key type: replace silent `"RS256"` fallback with `{:error, :unsupported_key_type}` + `Logger.warning` naming the `kty`.
- [x] Tests: disallowed alg rejected, header/key alg mismatch rejected, HS flow still works with static oct key, unknown kty errors cleanly.
- [x] CHANGELOG: new option; default allow-list could affect exotic-alg users — document escape hatch.

### T10 — WWW-Authenticate header hygiene
File: `lib/conduit_mcp/plugs/oauth.ex:274-321`
- [x] Sanitize values interpolated into the `WWW-Authenticate` header (strip `\r`/`\n`, escape `"`), or build `resource_uri` strictly from validated config. Add a test with a CRLF-bearing value asserting a clean header.

## Phase 3 — Transport posture `[transport]`

### T11 — Origin validation visibility (W4) — no default flip
Files: `lib/conduit_mcp/plugs/origin_validation.ex`, `lib/conduit_mcp/transport/streamable_http.ex`, `lib/conduit_mcp/transport/sse.ex`, README/guides
- [x] `Logger.warning` once at plug/transport init when `allowed_origins` is unset: name the DNS-rebinding risk + the option to set.
- [x] Document: why missing-Origin requests pass (non-browser MCP clients), and recommend `allowed_origins` for any loopback/dev deployment per MCP spec.
- [x] Defer flipping the default to secure (breaking) → next major; note in CHANGELOG "deprecation: unset allowed_origins will become an error".

### T12 — Opt-in session enforcement
File: `lib/conduit_mcp/transport/streamable_http.ex:161-163`
- [x] New transport option `require_session: true` (default `false`): non-`initialize` POSTs without `Mcp-Session-Id` → HTTP 400 with JSON-RPC error (match the spec's session-required semantics; reuse `ConduitMcp.Errors` codes).
- [x] `initialize` and notifications-before-session per spec still pass. Tests for both modes.

### T13 — SSE keep-alive responsiveness + endpoint URL (W9 + Host echo)
File: `lib/conduit_mcp/transport/sse.ex:237-242, :255-267`
- [x] Replace `:timer.sleep(@interval)` with `receive do ... after @interval -> ...` so shutdown/exit messages interrupt the 15s window; handle `{:plug_conn, :sent}`/EXIT messages gracefully.
- [x] Endpoint event URL: prefer a configured `:base_url` option; fall back to request Host but strip CR/LF and validate against `Plug.Conn` host (defense vs header smuggling).
- [x] Doc note: connection caps are a deployment concern (proxy/load balancer); rate-limit plug covers request rate only.

## Phase 4 — Test hygiene `[test]`

### T14 — Stop global-config mutation under `async: true` (W6)
Files: `test/conduit_mcp/validation_test.exs` (line 2, ~201), `test/conduit_mcp/endpoint_test.exs:552-563`
- [x] Simplest safe fix: `async: false` on both modules + replace `after` cleanup with `on_exit` (survives test-process kill).
- [x] (Optional, if cheap) thread per-call validation config through instead — only if it doesn't ripple through public API.

### T15 — Telemetry handler cleanup (W7)
Files: `test/conduit_mcp/session/janitor_test.exs:41,:78`, `test/conduit_mcp/tasks/janitor_test.exs:29`, `test/conduit_mcp/cancellation_test.exs:78`
- [x] Route through `TelemetryTestHelper.attach_event_handlers/2`, or add `on_exit(fn -> :telemetry.detach(id) end)` immediately after each raw attach.

### T16 — Misc test robustness
- [x] `test/conduit_mcp/endpoint_integration_test.exs:216` — `after` → `on_exit` for global teardown.
- [x] `test/conduit_mcp/transport/sse_test.exs:67` — raise the 200ms silence window to 1000ms (or add a sync primitive).
- [x] `test/conduit_mcp/tasks/store_dispatch_test.exs:171` — explicit save/restore of `:tasks_store` env in the nested describe `setup` (don't rely on outer-setup assumption).
- [x] `test/conduit_mcp_test.exs` — add `async: true`.
- [x] `test/conduit_mcp/cancellation_test.exs` — assert telemetry emission in the cleanup describe (consistency with cancel/2 block).
- [x] `test/conduit_mcp/session/janitor_test.exs:77` — widen/replace the 200ms `refute_receive` wall-clock coupling if flaky locally; otherwise leave with a comment.

### T17 — OAuth key-rollover coverage
File: `test/conduit_mcp/oauth_test.exs` (+ new `key_provider/jwks_test.exs` if cleaner)
- [x] JWKS provider: kid miss triggers refresh; TTL expiry refetches; fetch failure serves stale + warns (pairs with T8's stubs).

## Phase 5 — CI & docs `[ci]` `[docs]`

### T18 — Supply-chain checks + CHANGELOG
- [x] Add `mix hex.audit` and `mix deps.audit` (add `mix_audit` dep if absent) to CI workflow. (Skip sobelow — Phoenix-specific, this is a Plug library.)
- [x] CHANGELOG entries: T5 length semantics, T9 `:algorithms` option, T11 deprecation note, T12 `require_session` option, T8 JWKS hardening.

---

## Verification (after each phase; all must pass)
- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix credo --strict` (now meaningful, post-T1)
- [x] `mix test`
- [x] `mix dialyzer` once after Phase 2 (new error tuples in oauth/jwks paths)

## Deferred (explicit)
- **P1 tasks authz gap** (`handler.ex:506-556`) — separate `/phx:plan` for owner-stamping design (prior decision at PR #14 triage; unchanged).
- SSE concurrent-connection cap as a library feature — deployment concern for now (documented in T13).
- Origin-validation secure-by-default flip — breaking; next major (deprecation note in T11).

## Risks
- **T9 is the riskiest**: a default alg allow-list can break exotic configurations. Mitigation: implicit HS inclusion for static oct keys, `:algorithms` escape hatch, CHANGELOG. Test the static-key (HS) path explicitly.
- **T5 and T4 change user-visible validation behavior** (length semantics; multi-error responses). Both are arguably bugfixes; call them out in CHANGELOG and keep response shape string-keyed.
- **T1 may surface a batch of new credo findings** of unknown size — timebox: fix trivial, config-exempt intentional patterns with comments, don't refactor for credo's sake.
- Everything else is mechanical/low-risk.

## Iron Law compliance
- Only narrow `rescue ArgumentError` added (T2, T6) — intentional race/existence guards, mirroring c8a41f6.
- No new processes, no `Process.sleep` (T13 removes a blocking sleep); string-keyed MCP responses preserved (T4).
- No new deps except optional `mix_audit` (CI-only, T18).

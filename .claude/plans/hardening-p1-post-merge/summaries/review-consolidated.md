# Consolidated Summary: hardening-p1-post-merge review

**Strategy**: Compress (priority: BLOCKER/WARNING keep all; SUGGESTION grouped)
**Input**: 5 files (elixir.md, security.md, testing.md, iron-laws.md, requirements.md), ~21k tokens
**Output**: ~7k tokens (~65% reduction)

Reviewer keys: **ELX** elixir-reviewer · **SEC** security-analyzer · **TST** testing-reviewer · **IRL** iron-law-judge · **REQ** requirements-verifier.
Evidence: **VERIFIED** means a reviewer traced the source, read the dependency source, or ran a probe. **INFERRED** means reasoned but not executed. None of the reviewers except REQ, plus DslScope's probe, ran any code.

## Verdict

- **BLOCKERs: 0.** No reviewer found one.
- **Open WARNINGs: 7**: 2 security, 1 docs, 4 tests. **1 WARNING RESOLVED DURING REVIEW.**
- **Requirements**: **59 MET · 2 PARTIAL · 0 UNMET · 3 UNCLEAR** (REQ).
- Fix verdicts: every targeted fix was judged correct (B1, W1–W6, W3 mirror, G1, G4, G5-S1/S2/S3/S6/S7, G6-S1/S4/S6) with these exceptions:
  - **G6-S2** is incomplete (W1 below).
  - First-wins dedup had a validation mismatch (R1, now fixed).
  - **G7-S2** is PARTIAL (W5 below).
- ⚠️ **ACTION FOR MAIN**: DslScope changed `dsl.ex` and `dsl_test.exs` after compile, credo, dialyzer and the 3-seed suite had already run. **All Phase 7 gates must be re-run** (IRL). REQ row 63 (Phase 7 gates) is also UNCLEAR, because the result was reported by the orchestrator and not re-run by any reviewer.

---

## Resolved during review

### R1. Duplicate DSL tool/prompt names: dispatch/scope first-wins, validation last-wins, so the running handler is validated against the other declaration's schema. **RESOLVED DURING REVIEW**
- **Raised by**: IRL W-1 (kept per deconfliction), ELX W1, TST (persistent item), REQ row 60 follow-up. **VERIFIED** by DslScope probe `/private/tmp/conduit_build/dslscope_validation_probe.exs`.
- **Files**:
  - `lib/conduit_mcp/dsl.ex` `first_declaration_wins/1` (used by `generate_tool_clauses/1` and `generate_prompt_clauses/1`), new in this diff.
  - `lib/conduit_mcp/dsl/schema_builder.ex:442-460` / `:445-493`: `compile_{tool,prompt}_validation_schemas/1` use `Map.put` over declaration order, so the last declaration wins.
- **Evidence**: the probe declared tool `"dup"` twice, first with `param :n, :integer, max: 10`, second without. `n: 99` reached the **first** handler and was accepted. The prompt case was the same: `code: "toolong"` was accepted despite `max_length: 3`. The diff introduced this. Before it, dispatch and validation were both last-wins. This is a validation bypass: a security control present in source and absent at runtime.
- ELX note: the plan's follow-up rationale targeted the wrong mechanism. Validation is one clause over a last-wins map, not duplicate clause heads.
- **Fix applied (DslScope)**:
  - `dsl.ex` `__before_compile__` (~lines 1251-1260) now passes `Enum.uniq_by(reversed_tools/prompts, &to_string(&1.name))` into `generate_validation_lookup_functions/2`.
  - Regression tests are in `test/conduit_mcp/dsl_test.exs` `describe "duplicate declarations"` (red before the fix, green after, per DslScope).
- **Still open**: `tools/list` / `prompts/list` still advertise both declarations. See SG1.

---

## Open WARNINGs

### W1. G6-S2 `:principal_id` guard keys on the strategy name, not on the verification path. `verify:` with the default or `:api_key` strategy still merges all users into one principal. SEC · VERIFIED
- **File**: `lib/conduit_mcp/plugs/auth.ex:127-135` (`init/1` guard), `:286-315` (`do_verify/2`), `:264-270` (`build_principal/3`). Moduledoc `:25-31`.
- **Evidence**:
  - `init/1` raises only for `strategy in [:function, :custom]`.
  - `do_verify/2` dispatches on which keys are set. The static clauses require `token`/`api_key` to be non-nil. Otherwise `%{verify: fun}` runs for any strategy.
  - Two configs pass `init/1` and then merge every user into `"svc"` through `opts.principal_id || derive_id(user) || credential_id(...)`:
    - `auth: [verify: &MyApp.verify/1, principal_id: "svc"]` (default `:bearer_token`)
    - `auth: [strategy: :api_key, verify: &MyApp.lookup_key/1, principal_id: "svc"]`
  - The consequences are shared task ownership (users can read, cancel and fetch each other's task results), one rate-limit bucket, and one cancellation scope (`"principal:svc"`).
  - The moduledoc invites this config ("`:principal_id` is for the static `:bearer_token`/`:api_key` strategies").
- **Fix**: allow `:principal_id` only when the static secret is configured: `(strategy == :bearer_token and opts[:token] != nil) or (strategy == :api_key and opts[:api_key] != nil)`. Otherwise raise `ArgumentError`. Change the moduledoc to "requires `:token` / `:api_key`". Add `auth_test.exs` cases for both configs: either init raises, or two users yield two different `Principal.id/1` values.

### W2. G5-S6 lets a non-binary `uri` reach `[:conduit_mcp, :resource, :read]` telemetry. The library's default log handler raises on it, and `:telemetry` detaches the handler for all events. SEC · code path VERIFIED, handler detach INFERRED
- **File**:
  - `lib/conduit_mcp/handler.ex:459-492` (`handle_resource_read/4` emits `uri: uri` unconditionally at `:486`)
  - `lib/conduit_mcp/telemetry.ex:546-553` (default `handle_event/4` interpolates `"Resource read: uri=#{metadata.uri}"`)
  - `telemetry.ex:91` documents `:uri` as `String.t`
- **Evidence**:
  - Before the diff, `"uri": {}` raised inside the scope lookup and was rescued at `handler.ex:201`, so telemetry never fired.
  - Now `authorize_resource/3` returns `{:error, :invalid_uri}`, execution continues, and telemetry emits `%{uri: %{}}`.
  - With `:debug` enabled (the dev default), `"#{%{}}"` raises `Protocol.UndefinedError`, and `:telemetry` detaches the id `"conduit-mcp-default-logger"`, which covers every event it was attached to.
  - Result: one request (unauthenticated if `:auth` is unset) silently turns off the operator's logging. Operator handlers written against the documented `String.t` break the same way.
  - A sibling already exists [INFERRED]: `tools/call` with a non-binary `name` emits `tool_name` on the unknown-tool path (`handler.ex:437-446`).
- **Fix**:
  - Emit `uri: if(is_binary(uri), do: uri)` (or `Reflect.text(uri)`) and document the type as `String.t() | nil`.
  - Make the default handlers render client-sourced metadata (`uri`, `tool_name`, `prompt_name`, `method`) with `Reflect.text/2`. This also closes the `\n` log-forging hole.

### W3. `Tasks.Store` `list/1` `@doc` claims a store that ignores `:owner` is "slow rather than unsafe". ELX · VERIFIED · PERSISTENT (prior S3, doc half)
- **File**: `lib/conduit_mcp/tasks/store.ex:141-150` (changed in the diff), `tasks.ex:169-175`.
- **Evidence**: `Tasks.list/2` passes `:limit` to the store and filters afterwards. A store that honours `:limit` but ignores `:owner` returns the first N rows of *anyone*. The owner re-check then leaves the caller with fewer rows, or none, even though more exist. The facade cannot repair that.
- **Fix**: change the doc to "a store that ignores `:owner` must also ignore `:limit`; honouring `:limit` alone truncates the caller's own rows before the facade's owner re-check." The alternative is to withhold `:limit` from stores that don't declare owner support, but the doc fix is enough.

### W4. `assert log == ""` in an `async: true` module is flaky by ExUnit's own contract. TST · VERIFIED
- **File**: `test/conduit_mcp/security_test.exs:357`, `:372` (G5-S6 tests). The module is `async: true` (`:2`).
- **Evidence**: `scoped_request/2` wraps the request in `capture_log([level: :error], …)`. ExUnit 1.20.2 `capture_log.ex:64-67` warns that async tests capture other tests' messages and recommends `=~`. Concurrent modules log at `:error` routinely (handler rescues, crash tools in `handler_test`), so a failure would point at the wrong test.
- **Fix**: assert on the regression's own signature (`refute log =~ "FunctionClauseError"`, `refute log =~ "Regex"`, or the rescue message). The `-32602` assertion already carries the main guarantee.

### W5. W4 re-opened G7-S2: the JWKS waiter test no longer proves a waiter existed. TST W2 + REQ row 55 (PARTIAL) · INFERRED (traced, not probed)
- **File**: `test/conduit_mcp/oauth/jwks_test.exs:217-258` ("the single-flight waiter also honours :stale_max_age"), assertion at `:251-253`. Code at `jwks.ex:163-164`, `:280`.
- **Evidence**:
  - The config sets no `:refresh_cooldown`, so it defaults to 30 s.
  - The winner writes `{:last_refresh, uri}` in `store_fetch/2`. Any task that runs after the lock is released takes `fetch_on_miss/2` branch 2 (row present and cooling down) and goes to `serve_stale/4`, which fails closed without fetching.
  - So `refute_received :outbound_fetch` holds whether the tasks waited on the lock or were serialised behind it. Under serialisation (slow runner, coveralls), the bug this test names passes: `await_refresh/3` reading the cache without the age check.
- **Fix**: add `refresh_cooldown: 0` to the test config. Serialised tasks would then fetch and fail the `refute_received`, while genuine waiters still fail closed through `await_refresh/3 → serve_stale`.

### W6. First-declaration-wins dedup for DSL *prompts* (dispatch and scope) has no test. TST W3 · INFERRED
- **File**: `lib/conduit_mcp/dsl.ex:1644` (`|> first_declaration_wins()` on the prompt clauses). The only existing test is `test/conduit_mcp/oauth_scope_test.exs:572-697`, which covers tools, DSL static resources and Endpoint static resources.
- **Evidence**: deleting the pipe at `:1644` leaves the suite green. A second `prompt "dup"` with a weaker scope would then run behind the first one's scope check. This is a scope bypass per the Implementation notes.
- **Fix**:
  - Add two `prompt "dup"` declarations to `dsl_source`: first scoped `"first:scope"`, second `"second:scope"`, with different bodies.
  - Assert `__scope_for_prompt__("dup") == "first:scope"`, the prompt scope clause count == 1, and that `handle_get_prompt/3` returns the first body.
- ⚠️ The inputs don't say whether DslScope's new `dsl_test.exs` "duplicate declarations" tests (R1) cover prompt dispatch and scope, or only validation. Check before writing a new test.

### W7. `EtsOwner`'s self-scheduled retry is now untested; the G7-S3 determinism fix removed that coverage. TST W4 · INFERRED
- **File**: `test/conduit_mcp/ets_owner_test.exs:71-109`. Code at `lib/conduit_mcp/ets_owner.ex:85` (`Process.send_after` in `init/1`) and `:99` (reschedule in `handle_info(:reclaim, :taken)`).
- **Evidence**: the test now sends `:reclaim` itself and uses `:sys.get_state/1` as a barrier. Deleting either `send_after` still passes the suite. The "retries every 1000 ms" in the moduledoc and the CHANGELOG is therefore unpinned, although the retry is the fix for an owner that "would idle forever owning nothing".
- **Fix**: make the interval injectable (`start_link/4` opts `reclaim_interval:`, default 1 000). Test with 10 ms and a short ownership deadline. Alternatively, add a test that a second lost race re-arms the timer. Do not re-introduce a 1 s sleep.

---

## SUGGESTIONs (grouped)

### SG1. Duplicate declarations: make them a `CompileError`; `tools/list` still lists both. IRL S-1 (kept), ELX W1 option 1 + S9, REQ row 60 · VERIFIED (listing) / INFERRED (rationale)
- `tool_schemas` / `prompt_schemas` (`dsl.ex:1244-1247`) are built from **all** declarations. Clients therefore see two `"dup"` tools with different `inputSchema`s, and one of those schemas is never served.
- Endpoint already raises (`endpoint.ex:305-311` `validate_no_name_conflicts!/3`). The DSL instead keeps 3–4 dedup sites that must agree (dispatch, scope, validation, listing), in `first_declaration_wins/1`, `scoped_names/1`, `readable_resources/1` and the new `uniq_by`.
- **Fix**: raise in `@before_compile` for a duplicate DSL tool name, prompt name or resource URI. Add the missing resource-URI check to Endpoint too. Then delete the dedup sites and their comments. This is acceptable because the behaviour is unreleased (design choice, REVIEW).
- ELX S9 (UNVERIFIED): the comments in `first_declaration_wins/1`, `endpoint.ex:103-107` and the CHANGELOG say "adjacent generated clauses resolve to the *last*". That contradicts Erlang first-match semantics, and ELX could not run `/private/tmp/conduit_build/dslscope_matrix.exs`. If the claim is true, report it upstream and cite the issue. If not, fix the three comments and the CHANGELOG. Making duplicates a CompileError removes the need for the claim.

### SG2. SSE work per `GET /sse`, mostly at the cap. IRL S-3 (kept) + S-2, ELX S8, SEC S4 · VERIFIED (trace) / INFERRED (cost)
- **File**: `lib/conduit_mcp/transport/sse.ex:285, 300-326` (`__acquire_slot__/2`, `count_slots/1`, `sweep_dead_slots/1`).
- **Sweep on every rejected connect**: at the cap with every slot alive, each rejected `GET /sse` runs insert, `select_count`, `select` of up to `max` pids, `Process.alive?/1` on each, and a second `select_count`. That is about 3n operations, n ≤ `max_connections` (default 1 000). It is bounded and costs tens of µs, but an attacker can drive it: auth runs first, but the default config has no auth.
  - **Fix (optional)**: skip the sweep if a sweep ran within ~1 s and freed nothing (a `{:last_sweep, t}` row), or document the O(max) cost on the reject path. Either way, no new process (Iron Law).
- **O(n) `select_count` on every connect** (IRL S-2, VERIFIED): after B1 every row in `:conduit_mcp_sse_connections` is a slot row (the only write is at `sse.ex:301`), so `:ets.info(table, :size)` gives the same count in O(1).
  - `:ets.info/2` returns `:undefined` for a missing table, so the fail-closed path needs an `is_integer/1` check.
  - If a `:last_sweep` row is added, the count becomes `size - 1`.
- B1 itself was confirmed correct by ELX, SEC, IRL and REQ.

### SG3. "Counter" wording left in published HexDocs after B1. IRL S-4, REQ row 61 (PARTIAL), TST (persistent) · VERIFIED
- `lib/conduit_mcp/server.ex:24` "the SSE concurrent-stream counter" (in the diff)
- `lib/conduit_mcp/application.ex:16-17` "owns the concurrent-stream counter" (not in the diff)
- `lib/conduit_mcp/ets_owner.ex:8` "`ConduitMcp.Transport.SSE`'s connection counter" (not in the diff)
- **Fix**: "the SSE slot table (one row per live stream)". `SSE.Owner`'s own moduledoc (`sse.ex:364-372`) is already correct.

### SG4. OAuth `telemetry_reason/1` has no catch-all. SEC S5, TST (persistent), REQ row 52 · VERIFIED exhaustive today / INFERRED future risk
- **File**: `lib/conduit_mcp/plugs/oauth.ex:520-525` (called at `:273`).
- Every current `{:error, reason}` producer is mapped, and no header text reaches the metadata (SEC, IRL). A reason added later would raise `FunctionClauseError` on an unauthenticated request: a 500 instead of a 401. It fails closed, but noisily.
- **Fix**: add a final `defp telemetry_reason(_), do: :invalid_signature` (or a documented `:other`), plus a test asserting every emitted reason is in `@telemetry_reasons`.

### SG5. `session: true` (or a map) silently means no sessions. IRL S-6 (kept), ELX S3, TST S6 · VERIFIED
- **File**: `lib/conduit_mcp/transport/streamable_http.ex:104-113, 192-199` (the `is_list(session_config)` gate).
- After W6, `session: true` disables sessions and `require_session` without any signal. The cancellation scope then falls back to `"ip:"`, a documented isolation effect. G4 set the rule that misconfiguration should raise at boot.
- **Fix**: in `Shared.init/2` (or `__transport_private__/1`), accept `nil | false | keyword()` and raise an `ArgumentError` that names `session: []`.
- Same place (ELX S3, SEC pre-existing): validate SSE `:max_connections` as an integer. `"10"` or `:infinity` compares greater than any count in term order, so the cap silently fails **open**.
- TST S6: the documented opt-in `session: []` (CHANGELOG, README) has no test. A mutant treating `[]` as "off" passes the suite. Add a test, and pin whatever `session: true` ends up doing.

### SG6. JWKS cooldown and logging edges. SEC S1 + S2, ELX S4 · VERIFIED (trace)
- **Error-level log flood past `:stale_max_age`** (SEC S1.2, ELX S4): in `jwks.ex:453-476` `serve_stale/4`, the beyond-max-age branch ignores `context` and always logs `Logger.error("JWKS refresh failed … exceed stale_max_age; failing closed")`.
  - On the cooldown paths no refresh was attempted, so the message is false.
  - `authenticate` runs before `rate_limit`, so this is one `[error]` line per unauthenticated JWT request for the whole cooldown window.
  - It also returns a misleading reason: `:refresh_cooldown`, or `:not_found` → `:key_not_found`.
  - Still better than before the diff, which fetched on every such request.
  - **Fix**: honour `context == :cooldown` in the fail-closed branch too (log at `:debug`, or once per window).
- **Cold cache with a failing IdP** (SEC S1.1): `fetch_on_miss/2` branch 3 (`jwks.ex:157-169`) fetches back-to-back, serialised by the lock but not spaced, so up to 1 fetch per RTT, driven by any well-formed JWT header. This is documented behaviour.
  - **Fix**: with no row and `cooling_down?/2` true, return `{:error, :refresh_cooldown}` (optionally with a shorter cold cooldown, 1–5 s).
- **`refresh_keys/1` checks the cooldown before the lock** (SEC S2, `jwks.ex:195-208`): pre-existing, but it now contradicts the invariant stated at `:141-156`. During a rotation, new-`kid` tokens that arrive mid-refresh get the old set and a 401 instead of waiting (availability only).
  - **Fix**: check `:ets.member(@table, {:refresh_lock, jwks_uri})` first and route to `fetch_and_cache/2`.
- **Comment wording** (ELX S4): the `fetch_on_miss/2` comment says the check-1/check-2 window is "the outage behaviour anyway". With a healthy IdP it serves the TTL-expired set for about a microsecond. Reword to "…serves the previous key set, bounded by `:stale_max_age`".

### SG7. `Cancellation.reclaim/0` comments overclaim. ELX S5, SEC S3 · VERIFIED (ELX) / INFERRED (SEC)
- **File**: `lib/conduit_mcp/cancellation.ex:336-362` (comment above `reclaim/0`) and the moduledoc (`:68-80`).
- "a well-behaved caller is never the one that pays" (ELX) is false when every scope holds one row. All scopes then tie at size 1, eviction falls to age order, and the oldest well-behaved scopes pay. Reword to "…a caller holding fewer rows than the largest scopes is evicted only after them".
- "frees more rows than needed, never fewer" (SEC) is false under concurrency. k racers take identical snapshots and delete the same `batch` keys, so they do k scans and free about one batch. It stays bounded. Correct the comment, and optionally single-flight `reclaim/0` with an `:ets.insert_new` lock row (the JWKS pattern). Losers skip the reclaim.

### SG8. Doc precision. IRL S-5, ELX S2 · VERIFIED
- `lib/conduit_mcp/handler.ex:74-76` `handle_request/3` `@doc` says "`requestId` is not a string or an integer → `-32602`". But `Cancellation.cancel(nil, _, _)` returns `:ok`, so a missing or `null` id is ignored (IRL S-5; ELX found the three error cases otherwise consistent). Reword to "present and neither a string nor an integer (a missing or `null` id is ignored)".
- The per-param `type_coercion:` option is documented only in the `SchemaConverter`/`Validation` moduledocs. Add a bullet to the DSL `param` docs (`dsl.ex:415-424`) and to `component/schema.ex:38-47`. The `strip_markers/1` `@doc` (~`schema_converter.ex:316-325`) also omits `:type_coercion`, which is stripped at line 313 (ELX S2).

### SG9. Robustness edges. SEC S6 + S7, ELX S6 + S1
- **`Cancellation.scope/1` raises on a non-binary principal id** (SEC S6, INFERRED). At `cancellation.ex:143-148`, `"principal:" <> id` raises `ArgumentError` for a non-binary id. It is called from the `after` block of every request with an id (`handler.ex:135`). A custom plug assigning `%{id: 123}` without going through `Principal.put/2` gets a 500 on every request. This is new with G5-S7.
  - **Fix**: `principal_id when is_binary(principal_id) <- Principal.id(conn)`, or run `derive_id/1` inside `Principal.id/1`.
- **`EtsStore.owner_guard/1` uses `==` while the facade uses a pinned match** (ELX S6, INFERRED). `tasks/ets_store.ex:219-220` versus `tasks.ex:240-243`. For numeric owners, `1 == 1.0` holds in the store but `^1` does not match `1.0` in the facade, so the store's `:limit` counts rows the facade then drops. This only affects a custom `:task_owner_fun`.
  - **Fix**: use `:"=:="`.
- **Endpoint `:atomize` depends on the runtime atom table** (SEC S7, INFERRED, theoretical). `endpoint.ex:372-398, 421-425` and `dsl.ex:1551-1580` evaluate `String.to_existing_atom/1` twice. If an atom appears between the scope check and dispatch (lazy module load, never client input), the scope check can skip a template that dispatch then runs.
  - **Fix**: param names are compile-time literals, so compute atomizability per template at compile time.
- **G5-S1 nested `case` chain inlines all templated handlers into one function N levels deep** (ELX S1, INFERRED). See `generate_templated_resource_clauses/1` / `generate_templated_resource_match/2`. It is correct and lazy, but compile time is unmeasured for hundreds of templates, and stack traces are hard to read.
  - **Fix**: a flat shape (one `defp __read_template__(index, …)` per template plus `Enum.find_value/2` over `[{template, index}]`), or a ~200-template compile-time bench.

### SG10. Test hardening (TST S1–S5, S7–S11; S6 is in SG5)
- **Tests that don't prove what they claim**:
  - **S1** JWKS stale-serve tests (`jwks_test.exs:131-144`, `:165-177`): add `send(parent, :outbound_fetch)` in the stub plus `assert_received`, so each proves a refresh was attempted.
  - **S4** W3 "void" test (`oauth_scope_test.exs:480-489`) accepts any error. Add `assert __scope_for_resource__("void://1") == nil` and `refute message =~ "Insufficient scope"`.
  - **S9** the fail-closed comment (`sse_test.exs:199-209`, `sse.ex:309-312`) overstates how reachable the path is: `ensure_connections_table/0` recreates the table first, so the rescue is reachable only if the table vanishes between `whereis` and `insert`.
- **Coverage gaps**:
  - **S5** W5 spill-over into the next-largest scope is untested (`cancellation_test.exs:236-276`). Suggested seeding: hog 3 rows, 2 scopes × 10 rows, batch 5.
  - **S8** match-spec-special owner atoms (`:_`, `:"$1"`) have no case in `tasks_test.exs:267-286`.
- **Async and determinism**:
  - **S3** `Code.put_compiler_option(:debug_info, true)` is set from an async module (`oauth_scope_test.exs:563-570`). Move that describe to an `async: false` module or record the invariant in a comment.
  - **S7** use `<=` instead of `==` for the W6 table-size assertion (`streamable_http_test.exs:152`), because the Janitor can sweep between the two reads.
- **Cosmetic**:
  - **S2** in the W10 gzip test, note that each Req guard alone keeps the bytes intact, so the test fails only if both are removed (VERIFIED against `deps/req/lib/req/steps.ex:1126-1139`).
  - **S10** delete the redundant `@tag :capture_log` at `oauth_scope_test.exs:480`.
  - **S11** the `slots_reach?/2` sleep-poll (`sse_test.exs:846-858`) is acceptable (deadline-bounded, no signal available). Keep it.
- TST confirmed that all deleted or rewritten tests lost no coverage. W11 test 1 passing on the old code is accepted as documented.

---

## Requirements (REQ)

**Summary**: 59 MET · 2 PARTIAL · 0 UNMET · 3 UNCLEAR. The probe run (`ets_owner_test`, `sse_test`, `jwks_test`) gave 72 passed in 4.8 s.

| Row | Requirement | Status | Note |
|---|---|---|---|
| 4 | B1 h2 repro: `active_connections() == 0` after 10 h2 drops, 11th admitted | UNCLEAR | `research/sse_h2_repro.exs` only prints `active_connections/0`, which now counts *live* rows, so it reads 0 even when dead rows remain. The script as checked in (`max_connections: 1000`) never tests admission of the 11th. Row 3 covers admission at the unit level. |
| 55 | G7-S2: waiter test asserts a waiter existed | PARTIAL | = W5 |
| 61 | Docs describe the end state | PARTIAL | = SG3 ("counter" in server.ex, application.ex, ets_owner.ex) |
| 63 | Phase 7 gates (compile, format, credo, dialyzer, sobelow, 3 seeds, coverage ≥ 90.2, docs) | UNCLEAR | Orchestrator-reported (1 014 tests, 90.7 %), not re-run. ⚠️ Now stale: the tree changed after R1. |
| 64 | Phase 7 smoke tests (h2, notifications, tuple-owner repros) | UNCLEAR | Claimed in the Implementation notes; no output in the diff. Unit equivalents are MET (rows 3, 10, 13). |

Also noted: row 52 (G6-S6) is MET, but exhaustiveness is INFERRED (see SG4). Row 60's stated follow-up is resolved by R1.

---

## Pre-existing (not introduced by this diff, one line each)

- `validation.ex:87-93,120-126`: the non-map `arguments` error echoes the raw value (up to 1 MB) into `data.errors[].value` unclamped. Use `Reflect.text/2` or report the type. (IRL pre-existing, kept per deconfliction; ELX raised it as S7.)
- `validation.ex:638`: bare `rescue _ ->` around a user `:validator` hides the author's `KeyError`/`UndefinedFunctionError`. (IRL)
- `plugs/oauth.ex:286-288`: `peek_header/1` has a bare `rescue _ ->`. (IRL)
- `principal.ex:201`: `scalar("")` is accepted as an identity, so `%{id: ""}` merges callers. OAuth `scalar_claim/1` rejects `""`. (IRL)
- `plugs/auth.ex:252`: `Logger.error("Invalid verify function return: #{inspect(other)}")` is unclamped. (IRL)
- `plugs/auth.ex:277-280`: `"static:<digest>"` is an unsalted SHA-256 prefix in rate-limit and cancellation telemetry, so low-entropy tokens can be dictionary-reversed from metrics. (SEC)
- `cancellation.ex:168-190`: `requestId` length is unbounded (256 × ~1 MB per scope). IPv6 gets one `"ip:"` scope per address. Clamp ids (≤ 256 bytes) and aggregate IPv6 to /64. SEC says "worth promoting". (SEC)
- `plugs/message_rate_limit.ex:193`: `"method=#{method}"` with raw client JSON: a map raises (500 instead of 429), and `\n` forges log lines. (SEC)
- `plugs/origin_validation.ex:96`: the raw `Origin` header goes into Logger metadata unclamped. (SEC)
- `transport/sse.ex:95,293`: `:max_connections` is unvalidated; a non-integer disables the cap (see SG5). (SEC, ELX)
- `transport/sse.ex:354-363`: with the Owner degraded, the fallback table is owned by a stream process. Its exit loses all slot rows, so the cap can be exceeded. (SEC)
- `transport/sse.ex:122`: `connection: keep-alive` on an h2 response. (IRL)
- `transport/sse.ex:108-120`: the 406/503 bodies are atom-keyed maps (plain HTTP errors, harmless). (IRL)
- `transport/streamable_http.ex:140-150`: a session is not bound to its creating principal. A known session id selects that session's cancellation scope. (SEC)
- `handler.ex` `dispatch_callback/3`: `{:error, :atom}` from a handler raises on `error["code"]` and becomes -32603. (ELX)
- `handler.ex` telemetry metadata carries raw `method`/`tool_name`/`uri`/`prompt_name`, giving unbounded cardinality (PERSISTENT, round 3; related to W2). (IRL)
- `tasks.ex:114,145`: `function_exported?/3` without `Code.ensure_loaded?/1` (PERSISTENT, round 3). (IRL)
- `dsl.ex:1838`: `template_regex/2` does `:persistent_term.put/2` on a request-path cache miss (normally pre-seeded by `@on_load`). (IRL)
- `validation.ex:163`: the `update_validation_config/1` `@doc` sits under a `# Private functions` banner. (ELX)
- `dsl/schema_builder.ex:11`: the moduledoc narrates "The module now generates…". (ELX)
- Round-3 G5-S3 "stores truncating their own rows" cannot be fixed in the facade, so it stays PERSISTENT (the doc half is W3). (ELX)

Manual tools SEC recommends: `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`.

---

## Coverage

| File | Represented | Key items |
|---|---|---|
| elixir.md | Yes | 14: R1 (W1), W3 (W2), SG1 (S9), SG2 (S8), SG5 (S3), SG6 (S4), SG7 (S5), SG8 (S2), SG9 (S1, S6), pre-existing ×4 (S7 moved there per deconfliction) |
| security.md | Yes | 16: W1, W2, SG2 (S4), SG4 (S5), SG6 (S1, S2), SG7 (S3), SG9 (S6, S7), pre-existing ×7 |
| testing.md | Yes | 18: W4–W7 (W1–W4), R1 (persistent), SG3, SG4, SG5 (S6), SG10 (S1–S5, S7–S11) |
| iron-laws.md | Yes | 17: R1 (W-1), SG1 (S-1), SG2 (S-2, S-3), SG3 (S-4), SG8 (S-5), SG5 (S-6), pre-existing ×10, Phase 7 re-run action |
| requirements.md | Yes | 8: summary line, rows 4/55/61/63/64, row 52 (SG4), row 60 (R1/SG1) |

No coverage gaps: all 5 input files are represented.

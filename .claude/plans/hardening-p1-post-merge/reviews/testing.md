# Test Review: hardening-p1-post-merge (uncommitted diff, `test/**` + `test/test_helper.exs`)

**Method and limits.** Read-only, and I had no shell, so I could not run `git diff HEAD` or `mix test`. I reviewed the current tree of every changed test file against the plan, the scratchpad and the Implementation notes. I traced each new test against the production code it guards.
- **VERIFIED** means I read the library or dependency source that decides the outcome, for example `deps/req/lib/req/steps.ex` or the ExUnit 1.20.2 `capture_log.ex`.
- **INFERRED** means a mutation traced by hand and not run.
- Deletions were identified from the plan's S10/S11 items and the current tree, not from the diff.

| Severity | Count |
|---|---|
| BLOCKER | 0 |
| WARNING | 4 |
| SUGGESTION | 11 |

## Summary

The red-before-fix discipline mostly holds. The following regression tests fail on the code they replace (traced):
- B1 (killed stream frees its slot)
- W12 (503 path keeps no row)
- W1 (non-map `params`, at both layers)
- W2 (tuple and map owners)
- W3 (DSL and Endpoint, including the atomize skip)
- G5-S1 (it has a positive control)
- G5-S6
- W4 cooldown counting, 50 calls → 1 fetch, plus the `:stale_max_age` tail
- G6-S4 (no warning)
- W11 test 2
- G1 (`-32000`)
- G5-S2/S3, G6-S1/S2/S6
- W6
- the allowed-origins init tests

W9 and S8/S9 now assert observable behaviour. The handler cap test is async-safe: it uses a unique session scope, leaves the global config alone, the per-scope quota rejects before the global cap, and `on_exit` cleans its rows.

The four warnings are narrower problems:
- one flaky log assertion in an `async: true` module;
- one earlier test-quality fix (S2) that W4 silently re-opened;
- one security-relevant de-duplication path with no test;
- one coverage loss introduced by the G7-S3 determinism fix.

## Iron Law Violations

None blocking.
- `sse_test.exs:846-858`: the new `slots_reach?/2` is a bounded `Process.sleep(10)` poll. It is justified in place: `SSE.call/2` blocks and gives the caller no signal. It is deadline-bounded, so it cannot flake into a pass. See S11.

## Issues Found

### Critical
None.

### Warnings

- [ ] **W1 — `assert log == ""` in an `async: true` module is flaky by ExUnit's own contract** (VERIFIED)
  - **Where:** `test/conduit_mcp/security_test.exs:357` and `:372` (G5-S6 tests). Module is `use ExUnit.Case, async: true` (`:2`).
  - **Evidence:** `scoped_request/2` uses `ExUnit.CaptureLog.capture_log([level: :error], …)`, then `assert log == ""`. ExUnit 1.20.2 `capture_log.ex:64-67` says: *"when the `async` is set to `true` … messages from other tests might be captured. This is OK as long you consider such cases in your assertions, typically by using the `=~/2` operator to perform partial matches."* Concurrent async modules log at `:error` routinely: handler rescue paths, the crash tools in `handler_test`, and Reflect-clamped protocol errors. Any of them landing inside the capture window fails this test on an unrelated seed.
  - **Why it matters:** it produces an intermittent red run that points at the wrong test. That is the class of failure `capture_log: true` (G8) was meant to make rare.
  - **Fix:** assert on the specific signature of the regression rather than on silence. For example `refute log =~ "Regex"`, `refute log =~ "FunctionClauseError"`, or the handler's rescue message text. The `-32602` assertion already carries the main guarantee.

- [ ] **W2 — W4 re-opened G7-S2: the waiter test no longer proves a waiter existed** (INFERRED, traced)
  - **Where:** `test/conduit_mcp/oauth/jwks_test.exs:217-258`, "the single-flight waiter also honours :stale_max_age".
  - **Evidence:** `config = [jwks_uri: uri, cache_ttl: 1, stale_max_age: 1_000]` sets no `:refresh_cooldown`, so it is 30 s. The winner writes `{:last_refresh, uri}` in `store_fetch/2` (`jwks.ex:280`). A task that runs *after* the winner released the lock takes `fetch_on_miss/2`'s second branch, `:ets.member(@table, uri) and cooling_down?` (`jwks.ex:163-164`). That branch calls `serve_stale/4`, which fails closed with no fetch.
    - So `refute_received :outbound_fetch` (`:252`) holds whether the three tasks waited on the lock or were serialized behind it and cooldown-served.
    - The comment "The other three waited on the lock rather than fetching themselves" is no longer what the assertion proves.
    - Under serialization (a slow runner, or coveralls), the bug this test names passes: `await_refresh/3` reading the cache without the age check.
  - **Fix:** add `refresh_cooldown: 0` to `config`. Serialized tasks would then each fetch, and `refute_received` would fail. Genuine waiters still fail closed through `await_refresh/3 → serve_stale`, so the test's intent is unchanged.

- [ ] **W3 — first-declaration-wins de-duplication for DSL *prompts* has no test** (INFERRED)
  - **Where:** `lib/conduit_mcp/dsl.ex:1644` (`|> first_declaration_wins()` on the prompt clauses). The only test is `test/conduit_mcp/oauth_scope_test.exs:572-697`, which covers tools, DSL static resources and Endpoint static resources.
  - **Evidence:** the Implementation notes name this a scope bypass: on Elixir 1.20/OTP 29, adjacent generated duplicate heads resolve to the *last* clause, while `__scope_for_prompt__/1` keeps the first. The notes also list prompts as de-duplicated. Nothing asserts `scope_clause_count(bin, :__scope_for_prompt__) == 1`, or that `handle_get_prompt(conn, "dup", _)` runs the first declaration. Deleting the pipe at `dsl.ex:1644` leaves the suite green, and a second `prompt "dup"` with a weaker scope would then run behind the first one's scope.
  - **Fix:** add two `prompt "dup"` declarations to `dsl_source` in the same test: first scoped `"first:scope"`, second `"second:scope"` with different message text. Assert `__scope_for_prompt__("dup") == "first:scope"`, the prompt clause count is 1, and `handle_get_prompt/3` returns the first body.

- [ ] **W4 — the Owner's self-scheduled retry is now untested (coverage removed by G7-S3)** (INFERRED)
  - **Where:** `test/conduit_mcp/ets_owner_test.exs:71-109`.
  - **Evidence:** the test now drives `send(owner_pid, :reclaim)` itself and uses `:sys.get_state/1` as the barrier. That is deterministic, as the plan asked. But nothing else in the suite observes `Process.send_after(self(), :reclaim, @reclaim_interval)` in `init/1` (`ets_owner.ex:85`) or the reschedule in `handle_info(:reclaim, :taken)` (`:99`). Deleting either passes the whole suite. The old 1 s sleep-poll was slow, but it caught the first deletion. The moduledoc's "retries every 1000 ms", and the CHANGELOG's "retries every 1 s", are now unpinned. The retry is the fix for a one-shot degrade that "would idle forever owning nothing".
  - **Fix:** make the interval injectable. For example, have `start_link/4` take an opts keyword with `reclaim_interval:`, defaulting to 1 000, and have the test pass 10 ms and wait on ownership with a short deadline. Alternatively, keep the manual `send` test and add one test for "a second lost race re-arms the timer". Do not re-introduce a 1 s sleep.

### Suggestions

- [ ] **S1 — the stale-serve tests do not prove a refresh was attempted** (INFERRED). `jwks_test.exs:131-144` and `:165-177` now pass `refresh_cooldown: 0` so the fetch happens. However, `{:ok, @keys}` is also what the cooldown path returns with no fetch at all. Collectively the suite still pins the fetch: `:179-195` expects `{:http_error, 500}`, `:420-432` expects fresh keys. But these two titles, "a transport error serves stale…" and "…when a refresh fails", are not self-proving. Add a `send(parent, :outbound_fetch)` in the stub and `assert_received`.

- [ ] **S2 — the W10 gzip test fails only on the *double* mutation** (VERIFIED, `deps/req/lib/req/steps.ex:1126-1139`). `decompress_body/1` skips when `request.into != nil`, and it also skips unless `compressed: true`. Either guard alone keeps the gzip bytes intact, so the test fails only if both `into:` and `compressed: false` are removed. This matches the Implementation note and the test is honest. Consider stating in the test comment that each guard alone is sufficient, so a future reader does not "simplify" one away believing the test protects it.

- [ ] **S3 — a global compiler option is mutated from an `async: true` module.** `oauth_scope_test.exs:563-570`: `Code.put_compiler_option(:debug_info, true)` plus an `on_exit` restore. Compiler options are VM-global, and other async modules call `Code.compile_string/1` concurrently. The effect today is only harmless extra debug chunks, and no other test toggles the option. But the restore is last-writer-wins if one ever does. Either move the "two components sharing a name" describe to an `async: false` module, or add a comment recording the invariant.

- [ ] **S4 — the W3 "void" test accepts any error.** `oauth_scope_test.exs:480-489` asserts `refute response["result"]; assert response["error"]`. If the lookup regressed to inheriting `admin` for `void://1`, the response is "Insufficient scope" and the test still passes. The comment claims "The lookup answers `nil` for `void://…`" without pinning it. Add `assert @open_first_server.__scope_for_resource__("void://1") == nil` and `refute response["error"]["message"] =~ "Insufficient scope"`. The `doc://1` case covers the lookup in general, so this is belt-and-braces.

- [ ] **S5 — W5 spill-over is untested.** `cancellation_test.exs:236-276` covers "largest scope only" and "all 1-row scopes". It does not cover the case where the largest scope holds fewer than `batch` rows, so eviction must continue into the next-largest scope (the moduledoc's "then from the next largest", `cancellation.ex:72-73`). A mutant that takes only the largest scope's rows would pass both tests whenever that scope has ≥ `batch` rows. Example seeding: hog 3 rows, mid 2 × 10 rows, batch 5 → hog loses all 3 and the oldest 2 rows of the next scope go.

- [ ] **S6 — the W6 opt-in paths are untested.** No test exercises `session: []`, which is the one-line opt-in the CHANGELOG breaking-change bullet and README tell users to write. The `@session_opts` tests use `[store: EtsStore]`. A mutant treating `[]` as "off" (e.g. `session_config not in [nil, false, []]`) would silently break the documented migration. Separately, the Implementation note says `session: true` "no longer crashes". It now means *no sessions*, silently, which is surprising for `true`, and it is untested. Either pin it with a test or raise at `init/1` (hand-off to ElixirReview).

- [ ] **S7 — the W6 size assertion is exact equality.** `streamable_http_test.exs:152` asserts `:ets.info(:conduit_mcp_sessions, :size) == before`. The supervised `Session.Janitor.Default` could sweep a leftover stale row between the two reads. The window is tiny. `<= before` states the property ("did not grow") without that exposure.

- [ ] **S8 — the W2 owner cases skip match-spec-special atoms.** `tasks_test.exs:267-286` covers a tuple owner and a map owner. `{:const, owner}` also neutralises owners that ETS reads as match variables (`:_`, `:"$1"`). Those are reachable via a custom `:task_owner_fun`. One extra case (`Tasks.create("x", %{}, :_)` then `list([], :_)` returns exactly that row) pins the whole class.

- [ ] **S9 — misleading "reachable" claim in the fail-closed test comment.** `sse_test.exs:199-209` (and the matching rescue comment at `sse.ex:309-312`) says the missing-table case is "Reachable whenever the Owner has degraded and the table belonged to a stream process that has since exited". In that scenario, `acquire_connection_slot/1` first calls `ensure_connections_table/0` (`sse.ex:289,354-357`), which recreates the table, so the rescue is not reached. It is reachable only when the table vanishes between `whereis` and `insert`. The seam test itself is fine. The comment overstates how reachable the path is.

- [ ] **S10 — redundant tag.** `@tag :capture_log` at `oauth_scope_test.exs:480` is redundant now that `test_helper.exs:18` sets `capture_log: true` globally. Delete it so the two mechanisms do not look like they differ.

- [ ] **S11 — `slots_reach?/2` sleep-poll** (`sse_test.exs:846-858`). It is acceptable as written: deadline-bounded, and no signal is available. An alternative with no sleep would drive the killed-slot scenario through `SSE.__acquire_slot__/2` from a spawned process that blocks on `receive`. The plan's acceptance, however, demanded a real `GET /sse`, so keep it unless the poll ever shows up as slow.

### Deleted / rewritten tests (coverage check)

- **SSE "counter unreadable" route test → `__acquire_slot__/2` seam test.** The route's `false → 503` mapping is still covered by the `max_connections: 0` test (`sse_test.exs:278-291`). No `:active` writes remain (grep). No coverage lost.
- **`optional_deps_test.exs` S10 duplicate and `prom_ex_plugin!/0`.** The surviving tests cover both rejection branches and the built-ins. The function is deleted, so no coverage is lost.
- **`protocol_test.exs` S11.** The surviving "no published method reaches the rescue's internal_error" (`:103-117`) is the stronger twin.
- **`streamable_http_test.exs:95-98` (old "string or nil").** Replaced by "every documented :allowed_origins shape is accepted" (`:114-125`), which does pass `nil`.
- **`handler_tasks_test.exs` S11 duplicate.** The `Errors.task_not_ready/0` version survives (`:180-…`).
- **W11 test 1** (`cancellation_test.exs:236-256`) passes on the old `reclaim/0` too, as the Implementation notes admit. Its mutant, "evict the globally oldest", fails it. Test 2 is the red one. Accepted as documented.

### Persistent / known (not introduced here)

- **PERSISTENT (deferred in Implementation notes):** `SchemaBuilder.generate_validation_lookup_functions` still emits duplicate `__validation_schema_for_tool__/1` heads. With `tool "dup"` declared twice, dispatch runs the first declaration but validation resolves to the last. No test.
- `lib/conduit_mcp/ets_owner.ex:8`: the moduledoc still says "`ConduitMcp.Transport.SSE`'s connection counter". After B1 it is a pid-keyed slot table. The file is unchanged, so this is doc drift.
- `lib/conduit_mcp/plugs/oauth.ex:520-525`: `telemetry_reason/1` has no catch-all, and no test pins that every reason reaching `:273` is mapped. Any future unmapped reason becomes a `FunctionClauseError` on an unauthenticated request. INFERRED, and all current producers I traced are mapped. Flagged for SecurityReview/ElixirReview.

### Checked and clean (INFERRED mutation traces unless noted)

- **`sse_test.exs`, the killed stream.** The old counter code leaves the slot at 1, so the next `GET` sees 2 > 1 and gets 503: red. The new code inserts, counts 2, sweeps the dead pid, counts 1, and admits. The W12 503 test fails if the own-row delete is skipped: the test pid is alive, so the count reads `before + 1`. The async-safety comment (`:2-10`) is accurate. The only other SSE user (`message_rate_limit_integration_test`) drives `POST /message` only, and `ets_owner_test` is `async: false`.
- **`jwks_test.exs`.**
  - Cooldown counting: old code does 50 fetches. `Req.Test` shared mode and `default_options` are both restored.
  - Invented kid: the old `serve_stale/3` logged a warning, so it goes red. The module is `async: false`, so `refute log =~ "[warning]"` is safe here.
  - Mid-refresh: under a cooldown-before-lock mutant, `Task.yield(late, 100)` returns early with old keys, and `Task.await(late)` ≠ `rotated`.
  - Cold cache: fetches.
- **`cancellation_test.exs`** W11 test 2 (old code frees 1 row). G5-S7 namespace test (old code shares the quota).
- **`handler_test.exs:407-436`**: old code returns `-32603`, so red. Async-safe as described in Summary.
- **`oauth_scope_test.exs`.** W3 DSL and Endpoint are both red on old code. The atomize test's second assertion is red on old code. Endpoint prompt scope has both deny and allow. The clause-count helper excludes the variable-headed scan clause.
- **`dsl_test.exs:504-515`** G5-S1: eager evaluation sends `:second_handler_ran`, so red. It has a live positive control.
- **`session/janitor_test.exs:185-232`** W9: the throwaway `.beam` on a prepended path. The name matches `Atom.to_string/1`, so auto-load works. With `ensure_loaded?` reverted, `function_exported?` is false and there is no `{:swept, _}`.
- **`application_test.exs`** S9: uses telemetry plus row removal. No `:sys.get_state` field reads.
- **`rate_limit_test.exs`** S8: a recording backend. Repeatable, and it still guards the `:inet.ntoa` raise.
- **`tasks_test.exs`** W2 (old code raises `ArgumentError`) and G5-S3 (old code returns 3 rows).
- **`validation_test.exs`** G5-S2: both messages, both per-param overrides, and `type_coercion: false` compiles.
- **`principal_test.exs`**: the doctests match `derive_id/1` clauses, and `{:ok, true}` gets per-credential ids.
- **`auth_test.exs`** G6-S2: `:function` and `:custom` raise, static strategies don't.
- **`oauth_test.exs`** G6-S6: `<script>` alg gives `:alg_not_allowed`, with nothing header-derived in the metadata. The TelemetryTestHelper emitter filter keeps async emitters out.
- **`test_helper.exs`**: `capture_log: true` is compatible with the explicit `CaptureLog` users. The comment about the `refute_receive` count is still accurate for the barrier argument.

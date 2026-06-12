# Triage — PR #14 (pluggable `Tasks.Store` + Oban/SQLite example)

Source review: `.claude/plans/review/reviews/tasks-store-review.md`
Decision: **Fix all warnings + all suggestions as recommended.** Defer the pre-existing authz gap.
Approach guidance: *"Just fix as recommended"* — apply the review's suggested fix verbatim for each item.

## Fix Queue (15 items)

### Core library
- [ ] **W1** `tasks/ets_store.ex` — bound task growth: cap on `:ets.info(@table, :size)` and/or per-session quota; never-completing `working` rows currently never reclaimed.
- [ ] **S1** `ets_store.ex:136` + `cancellation.ex:141` — make `ensure_table/0` race-proof with `rescue ArgumentError -> :ok`.
- [ ] **S2** `tasks.ex:102` — replace `valid_transition?/2` `to_existing_atom`+`rescue` with a `@transitions` module-attribute map.
- [ ] **S3** `tasks/store.ex:130` — narrow `cleanup/1` spec to `non_neg_integer()` if Dialyzer noise appears (verify first).

### Oban example — `examples/oban_task_store.ex` (Postgres reference)
- [ ] **W2** `:132` — replace `apply(String.to_existing_atom(...), :execute, ...)` with a `case` over a fixed worker/handler allowlist.
- [ ] **W3** `:180` — make `create_with_job/3` atomic via `Ecto.Multi` + `Oban.insert/2` in one `Repo.transaction`.
- [ ] **W4** `:110` — stop status oscillation: only write `"failed"` on final attempt (`job.attempt >= job.max_attempts`) or return `{:cancel, _}` for permanent errors.
- [ ] **S4** — add `@impl true` to `MyApp.ObanTaskStore` callbacks.
- [ ] **S6** `rescuer.ex:40` — add `# Verified with oban ~> 2.18` marker + document Postgres/Lifeline upgrade path.

### Oban example — `examples/oban_tasks_server/lib/.../worker.ex` (SQLite)
- [ ] **W5** `:22` — add `def timeout(_), do: :timer.minutes(5)` and clamp client `duration_ms`.
- [ ] **W6** `:22` — add `unique: [period: 300, keys: [:task_id]]`.
- [ ] **S5** `:33` — guard `oban_job_id` stamp with `if job.attempt == 1`; soften the hard `{:ok, _} =` match so a deleted row doesn't `MatchError`-crash the job.

### Tests
- [ ] **W7** `store_dispatch_test.exs:118` — `MockStore` use `start_link`/per-test reset to avoid stale-state false positives.
- [ ] **W8** `smoke_test.exs:53` — replace `Process.sleep(2_000)` with the existing `poll_until_terminal/2`; add `@moduletag :integration` + `ExUnit.configure(exclude: [:integration])`.
- [ ] **S7** — add tests: `valid_transition?/2` coverage, error propagation through `Tasks.update/2` & `cancel/1`, `list/1` status filtering.

## Skipped (verified false positives — do not act)
- ❌ `:ets.foldl` + `:ets.delete` "UB" — safe under `foldl`'s internal `safe_fixtable`.
- ❌ `@callback cancel` + `@optional_callbacks cancel: 1` "contradiction" — correct idiomatic optional-callback declaration.

## Deferred
- 🔶 **Pre-existing authz gap** (`handler.ex:506-556`, from PR #13, out of PR #14 scope): `tasks/*` routes have no owner scoping; `tasks/list` returns all tasks; any client can cancel a leaked ID. Track as a separate `/phx:plan` (owner-stamping design) — **not** addressed in this fix pass.

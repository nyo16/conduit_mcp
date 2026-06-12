# Review: PR #14 — pluggable `Tasks.Store` + Oban/SQLite example

**Scope:** commit `0f70bfa` (`feat(tasks): pluggable Tasks.Store + Oban/SQLite example`)
**Verdict: PASS WITH WARNINGS** (core lib is sound; warnings concentrated in copy-me reference/example code + test coverage)

Agents: elixir-reviewer, oban-specialist, testing-reviewer, security-analyzer, verification-runner.
All findings re-verified against source by the orchestrator before inclusion.

---

## Verification (verification-runner): GREEN
`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` — all pass on the main library.

---

## ❌ Rejected agent findings (verified false positives — do NOT act)

1. **`:ets.foldl` + `:ets.delete` is NOT undefined behaviour.** elixir-reviewer flagged `ets_store.ex:102` and `cancellation.ex:127` as a BLOCKER. Incorrect: `:ets.foldl/3` wraps its traversal in `:ets.safe_fixtable(t, true/false)`. Under fixation, in-traversal deletes are safe — deleted rows are logically removed but physically retained until unfix, never revisited or skipped. The UB only applies to *manual* `:ets.first/:ets.next` loops without fixation. The two-pass rewrite is unnecessary. **No change needed.**

2. **`@callback cancel` + `@optional_callbacks cancel: 1` is NOT a contradiction.** elixir-reviewer flagged `store.ex:106` vs `:132` as a WARNING producing compiler warnings. Incorrect: declaring a callback via `@callback` *and* listing it in `@optional_callbacks` is the standard, idiomatic way to define an optional callback in Elixir. No warning is produced. The `function_exported?/3` dispatch in `tasks.ex:71/89` is the correct pattern. **No change needed.**

---

## ⚠️ Warnings (in-scope, worth addressing)

### Core library
- **W1 — Unbounded task growth (memory).** `tasks/ets_store.ex` has no row cap / per-owner quota, and `cleanup/1` (`:107`) deliberately never evicts `working`/`input_required` rows. A never-completing `working` task is never reclaimed → an untrusted MCP client looping a task-creating tool grows the table without bound. Consider an `:ets.info(@table, :size)` cap and/or per-session quota, plus rate-limiting on task creation. *(security-analyzer + elixir-reviewer)*

### Oban example — `examples/oban_task_store.ex` (Postgres reference, copy-me code)
- **W2 — Arbitrary module dispatch from client input.** `:132` `String.to_existing_atom("Elixir." <> handler)` then `apply(module, :execute, [args])`. (Note: `to_existing_atom` does NOT exhaust the atom table — that part of the agent claim is wrong — but dispatching `apply` on a client-derived module name is still unsafe in reference code.) Replace with a `case` over a fixed allowlist of known workers/handlers.
- **W3 — Non-atomic task + job creation (TOCTOU).** `create_with_job/3` (`:180-198`): insert task → `Oban.insert` → `get!`+`update` to link `oban_job_id`, in three separate round-trips with no transaction. A crash mid-sequence orphans the task or leaves the job unlinked (so `cancel/1` can never reach `Oban.cancel_job`). Use `Ecto.Multi` + `Oban.insert/2` in one `Repo.transaction`.
- **W4 — Task status oscillates on retry.** `perform/1` (`:110-122`) sets `"working"`, then on `{:error, _}` sets `"failed"` and returns `{:error, _}` → Oban retries → back to `"working"` → `"failed"`. Client sees flicker; final discard looks like an intermediate failure. Only write `"failed"` on the final attempt (`job.attempt >= job.max_attempts`) or return `{:cancel, _}` for permanent errors. *(The SQLite `worker.ex` avoids this correctly via a telemetry handler — good.)*

### Oban example — `examples/oban_tasks_server/lib/.../worker.ex` (SQLite, copy-me code)
- **W5 — No `timeout/1`.** `:22` — `duration_ms` is client-supplied and unbounded; `Oban.Engines.Lite` defaults to `:infinity`, so an adversarial call holds a queue slot forever. Add `def timeout(_), do: :timer.minutes(5)` and clamp `duration_ms`.
- **W6 — No `unique` constraint.** `:22` `use Oban.Worker, queue: :mcp_tasks, max_attempts: 3` — a double-submit enqueues two jobs racing the same task row. The Postgres reference sets `unique: [period: 300, keys: [:task_id]]`; the SQLite worker should too.

### Tests
- **W7 — `MockStore` uses `Agent.start/0` without reset.** `store_dispatch_test.exs:118` — `Agent.start` (not `start_link`) with no per-test reset; a leftover agent makes `start` return `{:error, {:already_started, _}}` and stale `calls` accumulate → false-positive `in` assertions. Use `start_link` (torn down on test-process exit) or reset in `setup`.
- **W8 — Example smoke test fragility.** `smoke_test.exs:53` `Process.sleep(2_000)` is non-deterministic (flaky on slow CI, wasteful on fast); the file already has a `poll_until_terminal/2` to reuse. Also no `@moduletag :integration` + `ExUnit.configure(exclude: [:integration])`, so a cold `mix test` in the example project flunks on the hardcoded port 4041.

---

## 💡 Suggestions (low priority)
- **S1** `ets_store.ex:136` `ensure_table/0` has a check-then-create TOCTOU. Extremely unlikely (the supervised `Owner` Agent creates the table before requests are served) but a `rescue ArgumentError -> :ok` makes it bulletproof. Same shape in `cancellation.ex:141`.
- **S2** `tasks.ex:102` `valid_transition?/2` uses `to_existing_atom` + `rescue` for control flow; a `@transitions` module-attribute map is simpler and atom-free. (Current code is safe, just heavier.)
- **S3** `store.ex:130` `cleanup` return type `non_neg_integer() | :ok` is an intentional union; if Dialyzer noise appears, narrow to `non_neg_integer()`.
- **S4** Postgres reference `MyApp.ObanTaskStore` has no `@impl true` on its callbacks — reference code should model the annotation so the compiler catches missing/typo'd callbacks.
- **S5** `worker.ex:33` stamps `oban_job_id` on every attempt; guard with `if job.attempt == 1` to model intent. Also note the hard `{:ok, _} = Tasks.update(...)` will `MatchError`-crash the job if the row was deleted mid-flight.
- **S6** `rescuer.ex:40` issues raw `UPDATE oban_jobs ...` against Oban's internal schema (Lite has no Lifeline) — fine, but add a `# Verified with oban ~> 2.18` marker and document the Postgres+Lifeline upgrade path.
- **S7** Missing tests for: `valid_transition?/2` (new public API, zero coverage), error propagation through `Tasks.update/2` & `Tasks.cancel/1`, and `list/1` status filtering.

---

## 🔶 Pre-existing — NOT introduced by PR #14 (flagged for follow-up)
security-analyzer surfaced these in `lib/conduit_mcp/handler.ex` (added in PR #13, outside this diff):
- **No authorization on `tasks/*` routes.** `handle_tasks_*` (`handler.ex:506-556`) act on a client-supplied `taskId` with no owner check. IDs are crypto-random/unguessable (good), **but `tasks/list` returns every task system-wide** — leaking other clients' `tool`, `args`, `result`, `metadata` — and any client can `tasks/cancel` a leaked ID. Worth a dedicated look: stamp an owner at `create`, scope get/cancel/list to it, and return identical not-found for 403/404.
- Failed-task `error`/`args` are echoed verbatim to clients (`handler.ex:541`) — consider sanitizing.

**Clean (security-analyzer confirmed):** the Ecto example pins all client values with `^` (no SQL injection), changesets `cast` properly, task IDs are 16 crypto-random bytes (non-enumerable), and runtime atom usage is compile-time-safe.

# Plan: PR #14 Review Fixes — `Tasks.Store` + Oban example

**Source:** `.claude/plans/review/reviews/review-triage.md` (15 approved items)
**Approach:** apply each review's recommended fix verbatim.
**Scope:** library core (`lib/conduit_mcp/tasks/*`, `tasks.ex`, `cancellation.ex`) + example app (`examples/`) + tests.
**Deferred (NOT in this plan):** pre-existing `tasks/*` authorization gap in `handler.ex` (PR #13) — separate `/phx:plan`.

Every approved triage item maps to a task below. Tags: `[ecto]` `[oban]` `[otp]` `[test]` `[core]` `[docs]`.

---

## ✅ STATUS: COMPLETE — all 15 tasks done (one session)

Final gate: `mix compile --warnings-as-errors` clean · `mix format --check-formatted` clean · `mix credo --strict` 0 issues (79 files) · `mix test` **619 passed** · `mix dialyzer` **0 errors** · example app `mix compile` clean, `mix test` 2 integration tests excluded.

| Task | Disposition |
|------|-------------|
| T1 ETS row cap | ✅ `@default_max_rows 10_000` + `at_capacity?/0`, `config :conduit_mcp, :tasks_max_rows` (`:infinity` disables). Test added. |
| T2 race-proof ensure_table | ✅ `rescue ArgumentError -> :ok` in ets_store + cancellation |
| T3 transitions map | ✅ `@transitions` map; rescue/atom-coercion removed |
| T4 cleanup spec narrowing | ✅ NO CHANGE — Dialyzer clean, union `non_neg_integer() \| :ok` is intentional |
| T5 allowlist dispatch | ✅ `@handlers` map replaces `to_existing_atom`+`apply` (ref + guide) |
| T6 atomic create_with_job | ✅ `Ecto.Multi` + `Oban.insert/2` (ref + guide) |
| T7 retry oscillation | ✅ failed only on final attempt (ref + guide) |
| T8 @impl true + delete/1 | ✅ added `@impl true` to all callbacks; added missing required `delete/1` |
| T9 cancel return + rescuer note | ✅ `with`-guarded cancel_job logging; rescuer version marker + upgrade-path warning |
| T10 timeout + clamp | ✅ `timeout/1` = 5 min; `duration_ms` clamped to `@max_duration_ms 60_000` |
| T11 unique constraint | ✅ `unique: [period: 300, keys: [:task_id]]` on SQLite worker |
| T12 stamp guard + soften match | ✅ stamp only on `attempt == 1`; all `{:ok, _} =` softened to `_ =` |
| T13 MockStore lifecycle | ✅ `start_supervised!` + `start_link` (no stale cross-test state) |
| T14 de-flake smoke test | ✅ `poll_until_status/3` replaces `Process.sleep`; `@moduletag :integration` + `exclude` in test_helper |
| T15 missing coverage | ✅ added: not_found propagation (update/cancel), unknown-status rejection, row-cap test. (valid_transition?/list filtering already covered in tasks_test.exs — reviewer's "zero coverage" was a scope artifact.) |

**Not committed** — changes are in the working tree pending review/commit decision.

---

## Phase 1 — Core library `[core]`

### T1 — Bound ETS task growth (W1) `[core]` ✅
File: `lib/conduit_mcp/tasks/ets_store.ex` (`create/2`, ~line 27)
- [x] Added `@default_max_rows 10_000` + `at_capacity?/0` reading `config :conduit_mcp, :tasks_max_rows` (`:infinity` disables). `create/2` returns `{:error, :task_limit_reached}` at the cap, no insert. `{:error, term()}` already fits the `create` callback spec.
- [x] Documented cap + Janitor caveat in `create/2` `@doc`.
- [x] Verified: framework request path (`tasks/get|cancel|list`) does NOT call `create` — creation is application/tool code, which receives the tuple via the `Tasks.create` facade (pass-through). No handler change needed, no crash path.
- Decision: hard cap is the minimal dependency-free defense; per-session quota deferred with the authz work (no task→owner mapping exists).

### T2 — Race-proof `ensure_table/0` (S1) `[otp]` ✅
Files: `lib/conduit_mcp/tasks/ets_store.ex`, `lib/conduit_mcp/cancellation.ex`
- [x] Wrapped both `ensure_table/0` bodies with `rescue ArgumentError -> :ok` so a lost check-then-create race (table already exists) is a no-op. Applied identically in both files.

### T3 — `valid_transition?/2` → transitions map (S2) `[core]` ✅
File: `lib/conduit_mcp/tasks.ex`
- [x] Added `@transitions` module attribute; `valid_transition?/2` is now `to in Map.get(@transitions, from, [])`. Rescue + atom coercion gone; behaviour identical. 33 affected tests pass.

### T4 — `cleanup/1` spec narrowing (S3) `[core]`
File: `lib/conduit_mcp/tasks/store.ex:130`
- [ ] Run `mix dialyzer` first. ONLY if `non_neg_integer() | :ok` produces noise, narrow to `non_neg_integer()` and update the `@callback`/`@doc`. If no Dialyzer complaint, leave as-is and check the box with a note (intentional union for native-TTL stores).

---

## Phase 2 — Postgres reference `examples/oban_task_store.ex` `[oban][ecto]`

### T5 — Replace `apply` dynamic dispatch with allowlist (W2) `[oban]`
File: `examples/oban_task_store.ex:131-134`
- [ ] Replace `String.to_existing_atom("Elixir." <> handler)` + `apply(module, :execute, [args])` with a `case` over a fixed map/allowlist of known handler modules, e.g.:
  ```elixir
  @handlers %{"slow_render" => MyApp.Handlers.SlowRender}
  defp execute_handler(handler, args) do
    case Map.fetch(@handlers, handler) do
      {:ok, mod} -> mod.execute(args)
      :error -> {:error, "unknown handler: #{handler}"}
    end
  end
  ```
- [ ] Add a short `# why` comment: never resolve a client-supplied string to a module.

### T6 — Atomic task + job creation (W3) `[ecto][oban]`
File: `examples/oban_task_store.ex:180-198` (`create_with_job/3`)
- [ ] Rewrite using `Ecto.Multi` + `Oban.insert/2` so task insert, job insert, and `oban_job_id` link commit in one transaction:
  ```elixir
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:task, McpTask.changeset(%McpTask{}, attrs))
  |> Oban.insert(:job, fn %{task: t} -> worker.new(Map.put(job_args, :task_id, t.task_id)) end)
  |> Ecto.Multi.update(:link, fn %{task: t, job: j} ->
       McpTask.changeset(t, %{oban_job_id: j.id})
     end)
  |> Repo.transaction()
  ```
- [ ] Return `{:ok, task}` / `{:error, step, reason, _}` shape consistently.
- [ ] Update `guides/oban_tasks.md` (~:153-165) to match.

### T7 — Stop task-status oscillation on retry (W4) `[oban]`
File: `examples/oban_task_store.ex:110-128` (`perform/1`)
- [ ] On `{:error, reason}`: only write `"failed"` when `job.attempt >= job.max_attempts`; otherwise leave status `"working"` and just return `{:error, reason}` so Oban retries silently. For permanent errors prefer `{:cancel, reason}`.
- [ ] Pattern-match `%Oban.Job{attempt: a, max_attempts: m, args: ...}` in `perform/1` to get the counters.
- [ ] Mirror the explanation in `guides/oban_tasks.md`.

### T8 — Add `@impl true` to store callbacks (S4) `[oban]`
File: `examples/oban_task_store.ex` (`MyApp.ObanTaskStore`: `create/2`, `get/1`, `update/2`, `cancel/1`, `list/1`, and the worker's `perform/1`)
- [ ] Add `@impl true` (Store behaviour) / `@impl Oban.Worker` so the compiler verifies the contract. Confirms no callback typos.

### T9 — Handle `Oban.cancel_job/1` result + rescuer version note (S6 + cancel return) `[oban][docs]`
Files: `examples/oban_task_store.ex:229-231`, `examples/oban_tasks_server/lib/oban_tasks_server/rescuer.ex:39`
- [ ] In `cancel/1`: `_ = Oban.cancel_job(task.oban_job_id)` with a comment, or match and `Logger.warning` on `{:error, _}`.
- [ ] In `rescuer.ex`: add `# Verified with oban ~> <pinned version> — recheck raw oban_jobs SQL on upgrade` above the `Ecto.Adapters.SQL.query!`, and a `@moduledoc` line pointing to the Postgres+`Lifeline` upgrade path. (Confirm pinned version from `examples/oban_tasks_server/mix.lock`.)

---

## Phase 3 — SQLite worker `examples/oban_tasks_server/lib/.../worker.ex` `[oban]`

### T10 — Add `timeout/1` + clamp duration (W5) `[oban]`
File: `worker.ex:22` / `render/2:44`
- [ ] Add `@impl Oban.Worker` `def timeout(_job), do: :timer.minutes(5)`.
- [ ] Clamp client `duration_ms`: `total = min(args["duration_ms"] || 1_000, 60_000)` before computing `chunk_ms`. Apply in both `render/2` and the `ask_then_render` resume path.

### T11 — Add `unique` constraint (W6) `[oban]`
File: `worker.ex:22`
- [ ] `use Oban.Worker, queue: :mcp_tasks, max_attempts: 3, unique: [period: 300, keys: [:task_id]]`.
- [ ] Verify `Oban.Engines.Lite` supports `unique` in the pinned Oban version; if not, note the limitation in a comment instead.

### T12 — Guard `oban_job_id` stamp + soften hard match (S5) `[oban]`
File: `worker.ex:30-33`
- [ ] Only stamp on first attempt: `if job.attempt == 1, do: Tasks.update(task_id, %{"oban_job_id" => job_id})`. Match `%Oban.Job{attempt: ...}` in the head.
- [ ] Soften the `{:ok, _} = Tasks.update(...)` calls throughout so a deleted/cancelled row returning `{:error, :not_found}` does not `MatchError`-crash the job — e.g. `case Tasks.update(...) do {:ok, _} -> :ok; {:error, :not_found} -> :ok end`, or treat not-found as a cancellation signal.

---

## Phase 4 — Tests `[test]`

### T13 — Fix `MockStore` lifecycle (W7) `[test]`
File: `test/conduit_mcp/tasks/store_dispatch_test.exs:118` (+ MockStore def, the `setup`)
- [ ] Change `MockStore.start()` (Agent.start) to `start_link` OR reset state at the top of `setup` (e.g. `MockStore.reset()` clearing the `calls` list). The existing `on_exit` already kills the pid; with `start_link` under the test process this is automatic.
- [ ] Confirm `calls()` assertions can't see stale cross-test state (the `{:create, ...} in calls()` checks).

### T14 — De-flake example smoke test (W8) `[test]`
File: `examples/oban_tasks_server/test/smoke_test.exs:53` + `test/test_helper.exs`
- [ ] Replace `Process.sleep(2_000)` (line 53) with a poll for `"input_required"` — generalize the existing `poll_until_terminal/2` into `poll_until_status(task_id, "input_required", max_attempts)` (100 ms interval).
- [ ] Add `@moduletag :integration` to the smoke test module; add `ExUnit.configure(exclude: [:integration])` to `examples/oban_tasks_server/test/test_helper.exs` so a cold `mix test` doesn't flunk on the hardcoded port.

### T15 — Add missing coverage (S7) `[test]`
File: `test/conduit_mcp/tasks/store_dispatch_test.exs` (+ a `tasks_test.exs` if cleaner)
- [ ] `valid_transition?/2`: allowed pairs (`working→completed`, `input_required→working`), disallowed pairs, unknown status → `false`.
- [ ] Error propagation: store returning `{:error, :not_found}` bubbles through `Tasks.update/2` and `Tasks.cancel/1`.
- [ ] `list/1` status filtering: insert mixed-status rows in `EtsStore`, assert `list(status: :working)` filters correctly.
- [ ] (If T1 lands) a test that `create/2` returns `{:error, :task_limit_reached}` at the cap.

---

## Verification (run after each phase; all must pass)
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix format --check-formatted`
- [ ] `mix credo --strict`
- [ ] `mix test`
- [ ] `cd examples/oban_tasks_server && mix compile` (example compiles)
- [ ] `cd examples/oban_tasks_server && mix test` (smoke test runs only when `:integration` included + server up — document, don't gate CI on it)
- [ ] `mix dialyzer` once after T4 to confirm no new spec warnings

## Risks / notes
- **T1 return-shape change** is the only behavior change touching the live request path — verify the handler surfaces `{:error, :task_limit_reached}` cleanly (no crash, sensible JSON-RPC error). This is the riskiest task; do it first and test it.
- **T6/T7** change example semantics users copy; keep the guide in lockstep with the code.
- **T11 `unique`** depends on Oban Lite capabilities at the pinned version — verify before committing.
- Everything else is mechanical and low-risk.

## Iron Law compliance
- No `Process.sleep` introduced (T14 removes one); no bare rescues except the deliberate `ArgumentError`-only one in T2; string keys preserved in all task maps; Oban workers keep `max_attempts` and gain `timeout`/`unique`.

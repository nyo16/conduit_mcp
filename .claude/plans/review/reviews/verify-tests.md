# Test Review: Verify Prior Fix Correctness

## Summary

All four targeted fixes are structurally correct. No Iron Law violations introduced. Three items need attention: one WARNING about row-cap test ordering sensitivity and two SUGGESTIONs.

---

## Iron Law Violations

None.

---

## Issues Found

### Warnings

- [ ] **`tasks_test.exs` line 111-131 — Row-cap test is order-sensitive with the suite `setup` clearing ETS.**
  The suite `setup` calls `:ets.delete_all_objects(:conduit_mcp_tasks)` before each test, which correctly clears rows created by prior tests. However, the cap test itself sets `tasks_max_rows: 2` via `Application.put_env` **after** the suite `setup` already ran, and the `on_exit` restores it after. The order is fine in isolation, but because the suite is `async: false` and the ETS clear happens in the outer `setup`, the cap test's two created rows (`cap-1`, `cap-2`) are cleared before the next test starts — no leakage confirmed. **However**, if any other test in the suite runs concurrently with a dirty ETS table AND the cap is still 2 during teardown race (not possible here since `async: false`), it would fail. Current `async: false` makes this safe. RESOLVED in practice; worth a comment to future maintainers.

- [ ] **`smoke_test.exs` line 116 — `poll_until/4` uses `Process.sleep(100)` internally.**
  This is an integration test polling an external HTTP server (not an internal async signal), so `Process.sleep` here is appropriate — no `assert_receive` alternative exists for HTTP polling. Iron Law #6 applies to internal async ops, not external server polling. RESOLVED / acceptable.

### Suggestions

- [ ] **`store_dispatch_test.exs` line 121 — `start_supervised!` child spec is correct but undocumented edge.**
  `start_supervised!(%{id: MockStore, start: {MockStore, :start_link, []}})` is valid — ExUnit's `start_supervised!` accepts a child spec map directly. The Agent is registered under `MockStore` (the module atom). Because the suite is `async: false`, a single named Agent is safe across tests; each `setup do` block in the nested `describe` restarts it via `start_supervised!`. The prior `Agent.start` + manual `on_exit Process.exit` pattern was fragile because `Process.exit` could fire after a subsequent test's setup already registered the name. The fix is genuinely correct. **RESOLVED.**

- [ ] **`tasks_test.exs` lines 53-55, 65-67 — `:not_found` propagation tests are meaningful.**
  Both tests call `update/2` and `cancel/1` on IDs that were never created, relying on `EtsStore.update/2` returning `{:error, :not_found}` for missing keys (confirmed at `ets_store.ex:93`). The assertions are not trivially true — they exercise real store dispatch. **RESOLVED.**

---

## Verification Results by Scope

| Item | Verdict |
|------|---------|
| `start_supervised!` with child spec map for Agent | CORRECT — tears down per-test via ExUnit supervision tree |
| No `:already_started` across `async: false` suite | CORRECT — supervised restart replaces prior instance cleanly |
| Row-cap `on_exit` restores `:tasks_max_rows` | CORRECT — nil guard handled (lines 115-119) |
| Cap test row leakage to other ETS tests | NO LEAK — outer `setup` clears ETS before each test |
| `poll_until/4` preserves `poll_until_terminal` behavior | CORRECT — same predicate `status in ~w(completed failed cancelled)`, same flunk path |
| `poll_until_status` flunks with useful message on timeout | CORRECT — `"task #{task_id} did not reach status #{inspect(status)} within budget"` |
| New assertions are meaningful (not assert-true) | CONFIRMED — all three new test bodies exercise real production paths |
| Smoke test excluded by default | CORRECT — `@moduletag :integration` + `ExUnit.configure(exclude: [:integration])` properly wires exclusion |

---

## Prior Issues Now RESOLVED

- `Agent.start` without `on_exit` cleanup → **RESOLVED** via `start_supervised!`
- `Process.sleep(2_000)` flaky timing in smoke test → **RESOLVED** via `poll_until_status` with 30-attempt budget
- Missing `:not_found` propagation coverage → **RESOLVED**
- Missing `valid_transition?` unknown-status coverage → **RESOLVED**
- Missing row-cap test → **RESOLVED**
- Missing `@moduletag :integration` exclusion → **RESOLVED**

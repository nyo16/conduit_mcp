# Verification Review — PR #14 fix pass (working tree)

**Verdict: ✅ PASS WITH WARNINGS** — all 15 fixes verified correct; every prior finding RESOLVED. No blockers. New findings are minor (2 in reference code, 1 in guide, 1 test comment).

Gate (run before review): compile `--warnings-as-errors` clean · format clean · credo `--strict` 0 issues · `mix test` **619 passed** · dialyzer **0 errors** · example app compiles, smoke test excluded.

Agents: elixir-reviewer (core), oban-specialist (example), testing-reviewer (tests).

---

## Prior findings — all RESOLVED ✅
W1 cap · W2 allowlist · W3 Ecto.Multi atomicity · W4 retry oscillation · W5 timeout · W6 unique · W7 MockStore lifecycle · W8 smoke-test sleep + S1–S7. Each confirmed correctly implemented by the responsible specialist.

## New findings (introduced/adjacent to the fixes)

### ⚠️ WARNING — `delete/1` swallows errors (I introduced this)
`examples/oban_task_store.ex` — `@repo.delete(task) && :ok`. `{:error, changeset}` is truthy, so `&&` always yields `:ok`, silently dropping a real delete failure. The Store contract is `delete/1 :: :ok`, so it's not a contract *violation*, but it hides DB errors and reads confusingly. Reference code should be clearer, e.g.:
```elixir
def delete(task_id) do
  case @repo.get(MyApp.McpTask, task_id) do
    nil -> :ok
    task ->
      case @repo.delete(task) do
        {:ok, _} -> :ok
        {:error, reason} -> require Logger; Logger.warning("delete failed: #{inspect(reason)}"); :ok
      end
  end
end
```

### ⚠️ WARNING — `Ecto.Multi` + `Oban.insert` repo coupling
`examples/oban_task_store.ex` `create_with_job/3` — atomicity holds only if Oban's configured repo is the same `@repo` running the transaction. In this example they're both `MyApp.Repo` (fine), but a one-line comment noting the requirement would prevent a copy-paste footgun.

### 💡 SUGGESTION — guide `cancel/1` return shape
`guides/oban_tasks.md` — the guide's `cancel/1` ends `@repo.update(...); :ok`, but the Store `cancel` contract is `{:ok, task} | {:error, :not_found}` (the reference `oban_task_store.ex` returns the `update/2` result correctly). Align the guide to return the update result so a copy-paste implements the behaviour correctly. (Pre-existing in the guide; surfaced now that the surrounding code was touched.)

### 💡 SUGGESTION — test comment
`test/conduit_mcp/tasks_test.exs` row-cap test relies on `async: false` (shared ETS table + app-env mutation). Safe today; a one-line comment noting the dependency would prevent a future `async: true` flip from introducing flakiness.

---

## Notes (not action items)
- Row cap is best-effort under concurrency (TOCTOU between `:ets.info/2` size check and insert) — correct for a DoS backstop; not a strict hard limit. Already framed that way in the docstring.
- `poll_until/4` `Process.sleep(100)` is appropriate (external HTTP polling, not an internal async signal — Iron Law #6 N/A).

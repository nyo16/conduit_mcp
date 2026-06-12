# Oban Worker Verification: Post-Fix Review

## Summary

The fixes address most of the prior review's concerns. Several are correctly resolved.
Three new issues require attention before the example is considered production-safe.

---

## Prior Issues — Resolution Status

### RESOLVED

- **Dynamic `String.to_existing_atom` + `apply` dispatch** — replaced with `@handlers` compile-time allowlist map. Correct.
- **`create_with_job/3` atomicity** — `Ecto.Multi` + `Oban.insert/2` + `Ecto.Multi.update(:link)` is the documented pattern. Correct.
- **`attempt >= max_attempts` status oscillation** — writing "failed" only on the final attempt stops flicker. Correct.
- **`@impl true` annotations** — added to callbacks. Correct.
- **`cancel/1` non-:ok logging** — `with` guard logs instead of crashing. Correct.
- **`timeout/1` callback (worker.ex)** — `:timer.minutes(5)` added. Correct.
- **`@max_duration_ms` clamp** — `min(requested, @max_duration_ms)` applied. Correct.
- **`oban_job_id` stamp on attempt == 1 only** — correct, avoids redundant updates on retries.

---

## Issues Found

### WARNING — `delete/1` uses `&&` on an Ecto return value (oban_task_store.ex:278)

```elixir
task -> @repo.delete(task) && :ok
```

`Repo.delete/1` returns `{:ok, struct}` or `{:error, changeset}`. In Elixir, `&&` treats
any non-`nil`/non-`false` value as truthy — `{:error, changeset}` is truthy, so `&&` always
evaluates the right side and returns `:ok`, **silently swallowing deletion errors**.

Fix:

```elixir
task ->
  case @repo.delete(task) do
    {:ok, _}    -> :ok
    {:error, e} -> {:error, e}
  end
```

Severity: **WARNING** — errors are silently dropped; the `@behaviour` contract is also broken
(callers expecting `{:error, reason}` on failure get `:ok`).

---

### WARNING — `Oban.insert/2` inside `Ecto.Multi` requires explicit repo (oban_task_store.ex:222)

```elixir
|> Oban.insert(:job, worker.new(job_args))
```

`Oban.insert/2` (arity-2, Multi form) requires a repo to be configured for Oban, or you must
pass the repo explicitly as `Oban.insert(multi, name, changeset, repo: MyApp.Repo)`. If Oban
is configured with a different repo than `MyApp.Repo`, the job insert runs outside the
Multi's transaction and **the atomicity guarantee is broken** — a job can be inserted even
if the `:link` step rolls back.

Verify that Oban's configured `repo:` in `config :oban, repo: MyApp.Repo` matches `@repo`.
If they may differ, pass `repo:` explicitly or use `Ecto.Multi.run/3` wrapping `Oban.insert/2`.

Severity: **WARNING** — atomicity breaks if repos diverge.

---

### SUGGESTION — `unique: [period: 300, keys: [:task_id]]` missing `fields:` on Lite engine (worker.ex:25)

The SQLite worker uses:

```elixir
unique: [period: 300, keys: [:task_id]]
```

`Oban.Engines.Lite` at 2.22 supports uniqueness. Without specifying `fields: [:args]`, the
default `fields` is `[:args, :queue, :worker]`. For `task_id`-keyed uniqueness this is fine
in practice because `task_id` is in `:args`. No functional regression — semantics are correct.
The Postgres reference (`oban_task_store.ex`) explicitly sets `fields: [:args]`; aligning for
consistency would be tidy but is not required.

Severity: **SUGGESTION**

---

### RESOLVED — Softening `{:ok, _} =` to `_ =` in worker.ex

The calls being softened are `Tasks.update/2` (progress stamps, status writes). These are
best-effort — a missed progress update does not corrupt the job. Using `_ =` is correct and
prevents a crash on a vanished row. The final `finalize/3` still writes `completed`/`cancelled`
with its own `_ =`, which is also acceptable for the same reason.

Severity: N/A — correctly resolved.

---

### SUGGESTION — `cancel/1` in guide (oban_tasks.md:202) diverges from source

The guide's `cancel/1` calls `@repo.update(...)` and then returns `:ok` unconditionally,
ignoring the update result. The source (`oban_task_store.ex`) calls `update(task_id, ...)` which
returns `{:ok, task}` as the final expression — matching the `@behaviour` `{:ok, map()}` shape.
The guide code would cause a type mismatch if copy-pasted. Update the guide to match the source.

Severity: **SUGGESTION** — guide only, not compiled.

---

## Queue Configuration

No queue config changes in scope. The `unique: [period: 300]` 5-minute dedup window is
reasonable for `task_id`-keyed jobs.

## Idempotency Assessment

The attempt-gated `oban_job_id` stamp and the `attempt >= max_attempts` guard together
make the worker safe to retry. The `@handlers` allowlist correctly prevents an adversarial
handler string from invoking arbitrary modules.

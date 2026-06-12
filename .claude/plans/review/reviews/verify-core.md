# Verification Review: Core Fixes

## Summary
- **Status**: Approved
- **Issues Found**: 1 WARNING, 1 SUGGESTION — no BLOCKERs

---

## Fix 1: `EtsStore.at_capacity?/0` row cap

**Logic correctness: SOUND**

```elixir
defp at_capacity? do
  case Application.get_env(:conduit_mcp, :tasks_max_rows, @default_max_rows) do
    :infinity -> false
    max when is_integer(max) -> :ets.info(@table, :size) >= max
  end
end
```

- `>=` is the correct operator. At exactly `max` rows the next insert would exceed the cap, so rejecting at `>= max` is correct — no off-by-one.
- `:infinity` short-circuits cleanly.
- The check is advisory (TOCTOU: another process could insert between `at_capacity?` and `:ets.insert`). Under concurrent load the table can transiently exceed `max` by the number of concurrent creators. For a DoS-prevention backstop this is acceptable, but it is not a strict hard cap.

**SUGGESTION**: Document the TOCTOU caveat in `@default_max_rows`'s comment so future maintainers understand the cap is best-effort, not strict.

---

## Fix 2: `ensure_table/0` rescue in both `EtsStore` and `Cancellation`

**Correctness: SOUND**

```elixir
defp ensure_table do
  if :ets.whereis(@table) == :undefined do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end
  :ok
rescue
  ArgumentError -> :ok
end
```

The only documented cause of `ArgumentError` from `:ets.new/2` is attempting to create a `:named_table` whose name is already taken — exactly the race condition being guarded against. No other call in the body raises `ArgumentError` (`:ets.whereis/1` returns `:undefined` on miss and never raises). The rescue is correctly scoped at the function level and does not suppress errors from callers.

**WARNING**: Both modules have a supervised `Owner` agent that creates the table at startup. In normal operation the `ensure_table` fallback should never be reached — which means the `rescue ArgumentError` path is only exercised in tests or abnormal restarts. If the `Owner` agent fails to start (e.g., OTP boot ordering issue), `ensure_table` creates an unowned table whose lifetime is tied to the first request process that touches it. This is a pre-existing design tension, not introduced by this fix, but worth acknowledging.

---

## Fix 3: `valid_transition?/2` via `@transitions` map

**Behavioral equivalence: SOUND**

```elixir
@transitions %{
  "working" => ~w(completed failed cancelled input_required),
  "input_required" => ~w(working cancelled)
}

def valid_transition?(from, to) do
  to in Map.get(@transitions, from, [])
end
```

All cases from the test suite are correctly covered:
- `working -> {completed, failed, cancelled, input_required}`: allowed
- `input_required -> {working, cancelled}`: allowed
- Terminal states (`completed`, `failed`, `cancelled`) as `from`: `Map.get` returns `[]`, so all return `false` — correct
- Unknown strings (`"bogus"`, `""`): `Map.get` returns `[]`, returns `false` without raising — correct

The old `String.to_existing_atom` + rescue approach had a subtle flaw: if the atom for a status string had not been created yet (e.g., in a fresh BEAM), `to_existing_atom` would raise `ArgumentError` even for valid-but-not-yet-interned atoms. The `@transitions` map eliminates that class of bug entirely. This is a strict improvement.

**No regression risk.** The map is a compile-time constant; no runtime state involved.

---

## Prior Issues: RESOLVED

All three fixes correctly address the originally reported issues. No new compiler warnings, spec violations, or behavioral regressions introduced.

---
problem: Credo reports "no issues" suspiciously fast; only 3 checks run
component: tooling
symptoms: [credo finds nothing, "running 3 checks", 0.04s analysis]
root_cause: .credo.exs used checks.enabled which REPLACES the default suite
solution: use checks.extra to adjust defaults
date: 2026-06-11
---

# Credo `enabled:` replaces the suite; `extra:` adjusts it

`checks: %{enabled: [...]}` in `.credo.exs` runs ONLY the listed checks —
it silently disables the entire default suite. To customize a few checks
while keeping defaults, use `checks: %{extra: [...]}` (Credo ≥ 1.7).

**Tell-tale**: `mix credo --strict` output says "running N checks" with a
tiny N (~ number of configured checks) and finishes near-instantly.

**Fix applied** (commit b4f11ed): renamed `enabled:` → `extra:`; the
restored 66-check suite surfaced 135 findings (11 real fixes + 3 deliberate
config exemptions with comments).

**Lesson**: a green lint gate is only as good as its config — verify the
check count, not just the exit code.

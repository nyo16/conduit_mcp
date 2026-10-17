# Scratchpad — P1 post-merge fixes

Written 2026-09-22. Source: the round-3 review triage (`hardening-p1-correctness/reviews/post-merge/hardening-p1-correctness-triage.md`).
No research agents were spawned: the plan skill's Iron Law 7 says the review findings **are** the research. Main read the
code sections each task touches to write concrete changes.

## User decisions (triage follow-up)

| Item | Decision | Rejected |
|---|---|---|
| B1 | Pid-keyed slot rows + sweep dead pids at the cap | An unlinked monitor process decrementing on `:DOWN`. It is exact, but it adds a process and a message per connection, and it is one refactor away from becoming the `handle_call` gateway the scratchpad for P1 forbids. |
| W6 | `nil` `:session` means no sessions (like `false`) | Keep creating sessions and warn at `init/1` without `:rate_limit`/`:auth`. That leaves the default posture DoS-able. |
| W13 | Reword the CHANGELOG: RC9 has no opt-out | A config key restoring `-32601`. That is a permanent compatibility path for non-spec behaviour. |
| rest | "Just fix them" with the review's recommended approach | — |

## Severity rulings made in the review (for context)

- B1 was reported as a WARNING (INFERRED) by two agents. Main reproduced it and promoted it to BLOCKER. With 10 h2 drops at
  `keep_alive_interval: 500`, slots were still held 10 s later; HTTP/1.1 recovered to 0. Script: `research/sse_h2_repro.exs`.
- W1: elixir-reviewer said BLOCKER, iron-law-judge said WARNING. The ruling was WARNING. The crash is identical at HEAD~1 (`handler.ex:194-197`), so it is not
  a regression, and it takes down only the request process. The new `@doc` contradicts it, which is why it sits in Phase 2 and not later.

## B1 design notes

- **Insert-then-count** is the atomicity argument. Each acquirer's own row is in the count it reads. Two racers at the boundary
  can both see `max + 1` and both reject (under-admit), but no interleaving admits more than `max`. The old
  `update_counter` had the same property; keep it.
- **Sweep only at the cap.** The steady state costs one `insert` + one `select_count` per SSE connect, with n ≤ `max_connections` (1 000).
  SSE connects are rare compared with POSTs, so no amortisation is needed. Dead rows below the cap are harmless because they are never counted against anyone
  until the cap is hit, and then they are swept.
- `active_connections/0` counts **live** rows without mutating. A getter that sweeps would hide leaks from tests that
  should see them.
- A key per pid assumes one stream per process. That holds: an HTTP/2 stream is a process, and HTTP/1.1 keep-alive runs requests
  sequentially in one process, where `after` runs before the next request.
- `Process.alive?/1` is local-only. Bandit handlers are local, so this is fine.
- The fail-closed test (`sse_test.exs:197-238`) worked by corrupting the global `:active` row. It is replaced by a
  `@doc false` seam taking the table name. This also fixes G7-S6 (it restored `0`, not the snapshot).

## W3 design notes

- The root cause is that `build_scope_map/2` drops `nil` scopes. That is correct for tools and prompts, whose exact-name catch-all returns `nil`, and
  wrong for resources, because an unscoped static URI then falls into the templated scan.
- The fix is dispatch-mirroring: every handled resource in dispatch order, with `nil` scopes kept, and the first *match* wins,
  not the first non-nil scope. `Enum.find_value/2` treats `nil` as "keep looking", so the scan must wrap `{:scope, s}`.
- Endpoint dispatch skips a template whose params do not atomize. The scan has to skip it too, or the scope check and dispatch disagree
  again. That is why `__generate_scope_clauses__` gets an Endpoint-only option.
- G5-S1 (eager handler evaluation) is in the same emitted code, so both change together.

## W4 design notes

- The existing comment (`jwks.ex:132-139`) argues against a cooldown gate because it would pre-empt the single-flight wait.
  The plan keeps that property by ordering the checks: lock held → wait (unchanged). Cooldown with a cached row →
  stale. Cold cache → fetch. Only the "no lock, cooling down, cached row" case changes, and that is exactly the amplification path.

## W5 design notes

- Evict by `{-scope_count, cancelled_at}` until `batch` rows are gone. This keeps "the largest scope pays first" and guarantees a
  full batch even when the table is 10 000 one-row scopes, which is the attack in the review. Ties now break on age, not on map
  iteration order.

## Things not to "improve" while here

Carried from `hardening-p1-correctness/scratchpad.md`:
- `secure_compare`, the alg allowlist, the kty pinning, the CORS-preflight termination, rate limiting failing closed, and no `String.to_atom` on input all hold.
- Owners are create-and-idle. No `handle_call` gateways.

## Dead ends / open questions for /phx:work

- G4: does `prom_ex_plugin!/0` really have no caller? Check with `lsp references` before deleting. If `ConduitMcp.PromEx` calls it
  from a module compiled only with `:prom_ex`, keep it and fix the doc instead.
- G5-S2: check whether `type_coercion: false` failing the build is a bug (it is documented) or intentional.
- G8: `capture_log: true` may hide output that some test reads via `ExUnit.CaptureLog`. It should not (CaptureLog is compatible), but run the suite once to confirm.

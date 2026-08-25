# Scratchpad — hardening plans (P1/P2/P3)

Decisions, rejected alternatives, and open questions. Written 2026-08-24 from `.claude/audit/summaries/consolidated.md`.

## Why three plans instead of one

50 findings / 15 root causes with three different risk profiles. A 9-function transport refactor and a `nimble_options` constraint change do not belong in the same reviewable diff as an auth fix. Split by *what breaks if it's wrong*:

- **P1** — broken today for consumers. Reviewer question: "does this change observable behaviour correctly?"
- **P2** — no behaviour change. Reviewer question: "did the suite pass unchanged?"
- **P3** — allocation + constraints. Reviewer question: "did the benchmark move?"

Rejected: one plan phased by release. Same content, but a single `/phx:work` session would interleave a security fix with a macro-layer refactor, and the audit's own evidence is that this codebase's bugs come from exactly that kind of coupled change.

## Sequencing decisions

**T-H1 first, before anything asserting telemetry.** `TelemetryTestHelper` (`test/support/telemetry_test.ex:20-37`) tags forwarded messages with a ref identifying the *handler*, not the *emitter*, so any concurrent test's emission of the same event lands in the mailbox. Proven by probe. Consequence: RC4, RC6, RC13, and RC14 all want telemetry assertions, and every one of them would be writing tests against a leaky helper. Fix the helper first or the green checkmarks mean nothing.

**RC2's owner + cap in one commit.** The audit's sharpest observation: today the session table dies periodically, which accidentally bounds it. Add the supervised owner alone and it becomes immortal *and* uncapped — a permanent unbounded leak, strictly worse than the bug being fixed. Cap and owner are one changeset or neither.

**RC7 before RC8.** `Tasks.default_owner/1` returns `assigns[:current_user]` (`tasks.ex:177-178`), which neither auth plug assigns. Making `tasks/list` owner-scoped (RC8) while `default_owner/1` still can't produce a stable owner would turn "world-readable" into "nobody can read their own tasks." Canonical principal first.

**RC5's two edits together.** Requiring `exp` reaches the existing `:expired` clause, so it alone makes *absent*-`exp` tokens fail correctly. Fixing the normalizer alone makes *genuinely expired* tokens report `:expired`. Ship one and a real expired token still reports `:invalid_signature`. Both, one commit.

## Rejected alternatives (and why)

| Finding | Rejected fix | Why |
|---|---|---|
| RC1 | Document `mix deps.compile conduit_mcp --force` and stop | Documentation does not fail a build, and the failure is silent by construction — a blanket 401 with a per-request `Logger.error` is indistinguishable from a config mistake. Needed, but not sufficient. |
| RC2 | Stop creating sessions when `:session` was never configured | Removes the exploit path but leaves the ownership bug for every consumer who *does* configure sessions — the documented default posture — and ownership is the half with proven data loss. |
| RC3 | Mirror the `:oauth` branch into `sse.ex:71-81` | Fixes 1 of 9 duplicated functions and re-establishes the exact copy-paste that caused the bug. **But** see the open question below — I split the difference. |
| RC4 | Add a janitor + row cap only | Bounds the growth, leaves the cross-client abort. Scoping is the source fix: it kills the abort *and* makes every planted row attributable and evictable. |
| RC5 | Return `{:error, :expired}` from `validate_claims/2` and leave the normalizer | Correct as far as it goes (the clause is properly wired), but the Joken path still can't produce `:expired`, so real expiry keeps reporting `:invalid_signature`. Adjudicated as contradiction C4 — both tracks right in scope, combination matters. |
| RC7 | Patch each consumer's pattern match independently | Three sites re-deriving identity from the token's internals is how this happened. One principal, one accessor. |
| RC8 | Keep the post-filter, add a limit | Bounds the response, not the copy, and leaves the default-open `nil`-owner path. Match spec bounds all three. |
| RC10 | Explicit `package.files` list or `Path.wildcard("lib/conduit_mcp*")` | Fragile — needs updating for every new source file — and still compiles the Mix task into the consumer's `:prod` build. Move it out of `lib/` instead. |
| RC11 | Bump the `req` constraint only | Transfers the guarantee to a third party's decompression behaviour for a cap the module claims to enforce itself. Stream *and* bump. |
| RC11 | `{:req, "~> 0.6 and >= 0.6.1"}` | Resolves to `>= 0.6.1 and < 0.7.0`, which **excludes req 0.7.2 — the version this repo's own lock holds** (`mix.lock:36`). Would break the repo's own build. Adjudicated C5 in favour of `"~> 0.6.1 or ~> 0.7"`. |
| RC12 | Assert `Process.info(pid, :current_function)` without touching `sse.ex` | Deterministic and cheap, but leaves the mailbox leak and the unbounded connection count — it tests that the bug is present. |
| RC15 | Add `decentralized_counters: true` alongside `write_concurrency` | `at_capacity?/0` calls `:ets.info(@table, :size)` per task creation (`tasks/ets_store.ex:61`); decentralised counters make that O(schedulers). Net loss on the tasks table specifically. |

## Resolved: RC3 scope — full extraction in P1

**Decision (user, 2026-08-24): all 9 duplicated functions land in P1 Phase 4.** P2's Phase 2 is folded in and deleted; P2 renumbered to 5 phases.

I had proposed splitting it — 6 divergence-bearing functions in P1, 3 cosmetic copies in P2 — reasoning that the `:oauth` 401 must ship in the patch release while a 120-line refactor inflates the security diff. Overruled in favour of the consolidator's original recommendation.

The counter-argument that won, and it is the stronger one: leaving 3 identical copies in place for a release preserves exactly the pattern that produced the bug. A half-extracted `Transport.Shared` is a fifth half-extracted abstraction in a codebase whose every defect traced to the other four. Doing it once is cheaper than doing it twice and removes the invitation to diverge again.

Practical consequence for implementation: **Phase 4 is now the largest diff in P1 and should be reviewed as its own commit**, separately from the auth work in Phases 2–3. Its acceptance criterion is absolute — no function body exists in both transports — which makes it mechanically checkable rather than a judgement call. The feature asymmetries it surfaces (`mcp-protocol-version` header, session handling: both StreamableHTTP-only) must each get a documented decision, since undocumented asymmetry is the root cause being eliminated.

## Cross-cutting pattern worth one dedicated sweep

**11 sites where documentation asserts an invariant the code does not hold** — the audit found these across all 4 tracks, and in every case the false moduledoc is *why* nobody noticed the defect:

`CLAUDE.md:31` + `server.ex:11-13` + `session/ets_store.ex:8-10` (no supervised processes / no wiring needed) · `cancellation.ex:41-42` (entries bounded) · `plugs/oauth.ex:13` (expiration checking) · `message_rate_limit.ex:30`, `:78-80` (tracked by user ID) · `guides/choosing_a_mode.md` (cross-mode equivalence) · `jwks.ex:52-58`, `:67` (body cap) · `telemetry.ex:469-479` (complete event list) · `protocol.ex:27` (`server_error/0` exists) · `streamable_http.ex:22-23` + `sse.ex:19-21` (`:allowed_origins` shapes) · `handler_test.exs:1025-1033` (sole table consumer) · `README.md:28-35` + `guides/authentication.md:69-111` (no optional-dep prerequisites).

Each is cited inside the task owning its underlying defect, so all 11 get fixed. But after P1 lands, one pass reading every `@moduledoc` against its implementation is worth it — in this codebase the moduledoc is where the false invariant lives.

## Things the audit confirmed sound — do not "improve" these

Guard against well-intentioned regressions during the refactors:

- Constant-time token comparison via `Plug.Crypto.secure_compare` (`plugs/auth.ex:215`, `:224`). No `==` on secrets anywhere in `lib/`.
- `alg: none` rejected by allowlist (`plugs/oauth.ex:200-208`, `@default_algorithms` `:54`); algorithm confusion prevented by pinning `kty` to the alg family (`:298-327`). Sound by inspection — P1's RC5b adds the missing tests, it does not change the logic.
- CORS preflight cannot bypass auth: `options _` (`streamable_http.ex:290`, `sse.ex:163`) terminates every OPTIONS in the router before any MCP handler.
- No `String.to_atom` on request data anywhere in `lib/` — only two `to_existing_atom` sites, both covered by P3's P-L2 as a *cost* fix. Both `.sobelow-conf` suppressions independently verified as genuine false positives; keep them accurate.
- No path traversal in library code: every `File.read!` in the DSL takes a compile-time literal (`dsl.ex:1472`, `:1547`), template params are `[^/]+` and never reach a file sink.
- Rate limiting fails **closed** when configured (`plugs/rate_limit.ex:88-91` raises without a backend).
- Direct ETS from the calling process, no GenServer funnel anywhere. The four `Owner` modules are Agents that create a table and idle — do not turn them into `handle_call` gateways while refactoring.

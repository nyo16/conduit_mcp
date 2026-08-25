# Requirements verifier review (round 2) — P1 hardening

**Verdict:** PASS WITH WARNINGS

> Read-only scout. This report is the deliverable; Main saves it verbatim to `.claude/plans/hardening-p1-correctness/reviews/requirements.md`.

## Requirements Coverage — the thirteen round-2 fixes

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | `String.replace_invalid("")` before the `/u` regex in `Reflect.text/2` | MET | `lib/conduit_mcp/reflect.ex:76` sits between the byte clamp and `String.replace(@control_chars, "")` at `:77`. Pinned three ways: `test/conduit_mcp/reflect_test.exs:55` (300×`€` does not raise, `String.valid?`, length 200), `:67` (both 3- and 4-byte codepoints across `n <- 195..215`, i.e. every cut offset inside a sequence), `:78` (already-invalid `<<0xFF,0xFE>>` inspected). End-to-end at `test/conduit_mcp/security_test.exs:185` — multibyte method *and* `protocolVersion` return JSON-RPC errors rather than raising inside the rescue |
| 2 | `{:bandit, _}` not drained by the SSE keep-alive loop | MET | `lib/conduit_mcp/transport/sse.ex:236` — `msg when not (is_tuple(msg) and tuple_size(msg) > 0 and elem(msg, 0) == :bandit)`, rationale `:225-231`. Pinned at `test/conduit_mcp/transport/sse_test.exs:176` "the drain leaves Bandit's adapter messages in the mailbox": `:184-185` send both real shapes, `:186` sends 20 junk messages, `:191` `queue_settles_at(sse_pid, 2, …)` asserts the queue settles at **exactly 2**. This is a real discriminating assertion — the junk must drain and the two must not |
| 3 | `ConduitMcp.EtsOwner` exists and logs-and-degrades on a taken name | MET | `lib/conduit_mcp/ets_owner.ex:53-67` — unguarded `:ets.new/2`, `rescue ArgumentError` → `Logger.warning` → `:ok`. The two design questions a reviewer would ask (why the create is not guarded; why losing the race must not raise) are answered at `:17-34`. Tests: `test/conduit_mcp/ets_owner_test.exs:13` free name, `:22` lost race logs `"could not claim"`, `:41` the Agent **stays alive** after losing (this is the actual supervisor-crash property) |
| 4 | All five `Owner` modules delegate to `EtsOwner` | MET (see WARNING 1) | `lib/conduit_mcp/cancellation.ex:323`, `lib/conduit_mcp/session/ets_store.ex:200`, `lib/conduit_mcp/tasks/ets_store.ex:252`, `lib/conduit_mcp/transport/sse.ex:343`, `lib/conduit_mcp/oauth/key_provider/jwks.ex:453`. No `:ets.new` remains in any `Owner`. Positive pin at `test/conduit_mcp/ets_owner_test.exs:57` — `:ets.info(table, :owner) == Process.whereis(owner)` — but for **four** of the five |
| 5 | `:telemetry_event` option on `Session.Janitor` | MET | `lib/conduit_mcp/session/janitor.ex:83` `event: Keyword.get(opts, :telemetry_event, @default_event)`, consumed at `:98` `:telemetry.execute(event, …)`; documented `:34-36`. Pinned at `test/conduit_mcp/application_test.exs:68` — reads the **running** janitor's state, asserts `state.event == [:conduit_mcp, :cancellation, :janitor]` *and* `refute state.event == [:conduit_mcp, :session, :cleanup]`; `:83` pins the session janitor keeps its documented event |
| 6 | `:noun` option on `Session.Janitor` | MET | `lib/conduit_mcp/session/janitor.ex:84`, used in the debug log at `:101`; documented `:37-38`. Set to `"expired cancellation rows"` at `lib/conduit_mcp/application.ex:102`. Not separately asserted (it is a log string only), which is proportionate |
| 7 | Cancellation janitor wiring in `Application` | MET | `lib/conduit_mcp/application.ex:95-107` — `cancellation_janitor/0` with `store: Cancellation`, `ttl: 5 min`, `interval: 1 min`, `name: Cancellation.Janitor`, plus the double-publish rationale inline at `:96-100`. Pinned live at `test/conduit_mcp/application_test.exs:73-79` (`Process.whereis` + `state.store == ConduitMcp.Cancellation`) |
| 8 | `Code.ensure_loaded?` before `function_exported?` in the janitor | **PARTIAL** | Production change present and correct: `lib/conduit_mcp/session/janitor.ex:110-112` `Code.ensure_loaded?(store) and function_exported?(store, :cleanup, 1)`, used by both `init/1` (`:71`) and `handle_info/2` (`:94`). **No test pins it.** `grep` for `ensure_loaded`/`cleanup_exported`/`does not export` across `test/conduit_mcp/session/janitor_test.exs` and `test/conduit_mcp/tasks/janitor_test.exs` returns nothing. See WARNING 2 |
| 9 | The `true` clause in `Application.janitor/3` | MET | `lib/conduit_mcp/application.ex:122-123`. Pinned at `test/conduit_mcp/application_test.exs:32` "true is the symmetric spelling of yes, not a boot crash", asserting the returned child spec equals the defaults — not merely that it does not raise |
| 10 | The `raise` clause in `Application.janitor/3` | MET | `lib/conduit_mcp/application.ex:131-135` `ArgumentError` naming the key, the accepted shapes and the offending value. Pinned at `test/conduit_mcp/application_test.exs:55` with three `=~` assertions on exactly those three parts of the message — the assertion an operator actually depends on |
| 11 | `@notification_methods` drives notification routing | MET | `lib/conduit_mcp/handler.ex:150-153` defines the table; `:246` `case Map.get(@notification_methods, method)` replaces the hand-written `case`; `:161` `methods/0` is `Map.merge(@request_methods, @notification_methods)`, so `Protocol.methods/0` and both dispatchers are one source. Pinned at `test/conduit_mcp/protocol_test.exs:134` (every published notification routes and none logs as unknown), with the request-side counterparts at `:100` and `:118` |
| 12 | `Enum.uniq_by/2` in `dsl.ex` and `endpoint.ex` scope maps | MET | `lib/conduit_mcp/dsl.ex:1397` and `lib/conduit_mcp/endpoint.ex:468`, both `\|> Enum.uniq_by(&elem(&1, 0))` with the "first declaration wins, matching dispatch order" comment. Pinned at `test/conduit_mcp/oauth_scope_test.exs:314` — compiles a server with two same-named scoped components and asserts **no** `"this clause"` diagnostic (`:341`), which is the consumer-build-breaking symptom, plus that the first declaration wins |
| 13 | `:infinity` accepted by `Tasks.EtsStore.list/1` | MET | `lib/conduit_mcp/tasks/ets_store.ex:174` `:infinity -> :ets.select(@table, spec)`, ahead of the `limit > 0` clause at `:177`; the same convention as `:tasks_max_rows` at `:60`. Pinned at `test/conduit_mcp/tasks_test.exs:99` `assert length(Tasks.list(limit: :infinity)) == 5`, alongside `:100` (`[]`), and `:102` (0/negative still mean nothing) |
| 14 | `Map.update!(:id, &derive_id/1)` in `Principal.put/2` | MET | `lib/conduit_mcp/principal.ex:86`, after the `@defaults` merge so an omitted `:id` is normalised too; documented `:73-79`. Pinned at `test/conduit_mcp/principal_test.exs:195` (non-scalar id → `nil`, not a spec violation), `:217` (a claims-shaped id is *dug into*, `%{sub: "x"}` → `"x"`), and — the one that matters — `:224` `rate_limit_key/1` cannot raise for any of `[nil, "u1", 42, :svc, %{}, {1,2}, [1], self()]` |

**12 MET · 1 PARTIAL · 0 UNMET · 0 UNCLEAR**

(Fourteen rows: the assignment's ten bullets, with `:telemetry_event`/`:noun`, the cancellation wiring, and the `true`/`raise` clauses scored separately because they are separately falsifiable.)

## The two clauses the prior pass marked "satisfied structurally"

**RC8 — "a status filter matching nothing does not copy the table". Round 2 added a test; the clause is still satisfied structurally.**

`test/conduit_mcp/handler_tasks_test.exs:313` is now literally titled *"a status filter matching nothing returns nothing without copying the table"*, but its three assertions (`:316-318`) are `== []`, `== []`, and `length(...) == 20`. Every one of those passes just as well against the old `:ets.foldl` + `Enum.filter` implementation. The no-copy property is delivered by construction at `lib/conduit_mcp/tasks/ets_store.ex:159-176` — the status, owner and limit predicates are folded into one `:ets.select/3` match spec — and I agree with the prior pass that asserting it directly would be asserting on implementation detail. The change round 2 made is that the *title* now claims a property the body does not test. See SUGGESTION 1.

**RC12 — "a test asserts the first emitted keepalive chunk". Round 2 did not change this, and it did not need to.**

`test/conduit_mcp/transport/sse_test.exs:88` still asserts `conn.resp_body =~ ": keepalive"` on the body accumulated once `max_connection_lifetime: 200` expires — *that* a keepalive was emitted, not *the first*. With `keep_alive_interval: 20` and a 200 ms lifetime the body contains roughly ten of them. The clause's actual intent — kill the vacuous 200 ms `refute_receive`, make the chunk observable, give `send_keepalive/3` coverage — is delivered, and "the first" is not separately meaningful when every chunk is byte-identical. Not a finding.

## Plan bookkeeping

- **46/46 checkboxes: confirmed.** 36 task items (`plan.md:24` … `:231`) plus 10 Phase 8 gate items (`:238`, `:240`, `:242`, `:244`, `:246`, `:248`, `:250`, `:252`, `:254`, `:256`). Every one is `- [x]` and every one carries a `**Done:**` note. No orphan or unchecked item.
- **"958 tests / 90.0%" is internally consistent** — `plan.md:249` and `plan.md:398` agree, and both record the pre-round-2 pair (930 / 89.8%) rather than overwriting it, which is the honest form. I could not re-execute the suite (no shell in my toolset, and the assignment forbids a full-suite run in any case), so the count is unverified-by-execution, not contradicted.
- **`CHANGELOG.md` quotes no test count or coverage figure for this release**, so there is nothing to disagree with `plan.md`. Worth knowing that this breaks the file's own long-standing convention — `CHANGELOG.md:620` ("expanded to 503 tests"), `:655` (405), `:686` (309), `:723` (229), `:802` (193), `:830` (109) all record it. See SUGGESTION 2.
- The `coveralls.json:2` ratchet is still `86` against an actual 90.0% — a 4-point gap. That is the plan's own choice (T-L5 set 86 when actual was 89.8%) and not a round-2 regression.

## Findings

### WARNING — the fifth ETS owner is not covered by the owner-ownership test
`test/conduit_mcp/ets_owner_test.exs:57-77` · NEW

`ConduitMcp.EtsOwner`'s moduledoc names **five** subsystems (`lib/conduit_mcp/ets_owner.ex:5-10`) and five `Owner` modules delegate to it, but the "every supervised owner actually owns its table" list at `:61-65` contains four: `Cancellation.Owner`, `Session.EtsStore.Owner`, `Transport.SSE.Owner`, `Tasks.EtsStore.Owner`. `ConduitMcp.OAuth.KeyProvider.JWKS.Owner` / `:conduit_mcp_jwks_cache` (`lib/conduit_mcp/oauth/key_provider/jwks.ex:452-457`, started at `lib/conduit_mcp/application.ex:152`) is absent. `test/conduit_mcp/oauth/jwks_test.exs:8` touches the table by name but never asserts who owns it.

This is exactly the owner whose absence was the round-1 SSE blocker, in the subsystem where the consequence is authentication-shaped: if the JWKS Owner ever stops owning its cache, the table's lifetime silently becomes that of one request process, and a concurrent request can hit `:ets` `ArgumentError` mid-verification — the failure mode `application.ex:146-150` documents in prose. The test that would catch it is the one that skipped it.

**Why it matters:** the round-2 fix's own regression test has a 4/5 hole, in the fifth that is hardest to notice because the Owner is started conditionally (`Code.ensure_loaded?`, `application.ex:152`) and so is easy to read as "deliberately excluded" when it is not — with `req` present in `:test`, it *is* running.

**Minimal fix:** add `{ConduitMcp.OAuth.KeyProvider.JWKS.Owner, :conduit_mcp_jwks_cache}` to the list at `ets_owner_test.exs:61-65`, guarded by `if Code.ensure_loaded?(ConduitMcp.OAuth.KeyProvider.JWKS.Owner)` so the bare-consumer build stays green.

### WARNING — the `Code.ensure_loaded?` janitor fix has no regression test
`lib/conduit_mcp/session/janitor.ex:110-112` · NEW

The production change is present and correct in both call sites (`:71` in `init/1`, `:94` in `handle_info/2`), and the rationale at `:66-70` is precise. But nothing in the suite distinguishes `cleanup_exported?/1` from the bare `function_exported?/3` it replaced: no test in `session/janitor_test.exs` or `tasks/janitor_test.exs` mentions an unloaded store, and every store used in tests (`Session.EtsStore`, `Tasks.EtsStore`) is already loaded by the time the janitor starts. Reverting `:111` to `function_exported?(store, :cleanup, 1)` leaves the suite green.

**Why it matters:** this defect's blast radius is the one the comment describes — a janitor that idles for the life of the node while the table it was added to bound grows unbounded, under any interactive-code-loading deployment (dev, `mix run`, a release not built with `:embedded`). It is silent apart from one boot-time warning, so a regression here is discovered as an OOM, not as a failure. It is the only one of the thirteen round-2 fixes with no test behind it.

**Minimal fix:** one test that purges the store module before starting the janitor and asserts the sweep still runs — e.g. define a `cleanup/1`-exporting store module, `:code.delete/1` + `:code.purge/1` it, `refute function_exported?(store, :cleanup, 1)`, then start the janitor, `send(pid, :cleanup)`, `:sys.get_state(pid)` barrier, and assert the backdated row is gone. That is the existing T-M7 idiom (`session/janitor_test.exs:53-66`) plus two lines.

### SUGGESTION — a test title claims a property its body does not assert
`test/conduit_mcp/handler_tasks_test.exs:313` · NEW

"…returns nothing **without copying the table**" is asserted by `== []`, which the pre-RC8 fold-then-filter implementation also satisfies. The name will be read by the next person as a guard on the match-spec design, and it is not one.

**Why it matters:** a test whose name overstates its assertions is worse than no test for that property — it is the reason the prior pass's honest "satisfied structurally" note exists, and this title quietly retires that note without earning it.

**Minimal fix:** rename to "a status filter matching nothing returns nothing", and move the no-copy claim into a comment pointing at `tasks/ets_store.ex:159`.

### SUGGESTION — `CHANGELOG.md` drops the test-count line this file has carried since 0.4.0
`CHANGELOG.md:8` · NEW

Six prior releases record the count (`:620`, `:655`, `:686`, `:723`, `:802`, `:830`); `[Unreleased]` does not. The plan carries 958 / 90.0% at `plan.md:249`; nothing contradicts it, but the number now lives only in a plan file that will not ship.

**Minimal fix:** one line under `[Unreleased]`'s existing sections: `**Test coverage** expanded to 958 tests (up from 930), 90.0% coverage`.

## Scope creep introduced in round 2

**`ConduitMcp.EtsOwner` — justified, and the narrower alternative was worse.** No plan item asked for it, but the defect it fixes is real and load-bearing: five `Owner` Agents each raising `ArgumentError` on a taken table name, three restarts in five seconds taking down `ConduitMcp.Supervisor` and with it the consumer's application. The counterfactual is five copies of the same `rescue`; the module is 67 lines of which 34 are the two rationale sections (`ets_owner.ex:17-34`), and it deletes five `:ets.new` call sites. It also does **not** expand the surface in the direction that would matter — the moduledoc explicitly forbids turning any Owner into a `handle_call` gateway (`:13-15`), preserving the plan's stated design decision. Note it is genuinely new *public* API (`start_link/3`, `claim/3` are both `@doc`'d, not `@doc false`) in a library with "no public API removals" as its compatibility promise — `claim/3` in particular has no caller outside `start_link/3` and its own test. Public only because the test calls it.

**`test/conduit_mcp/application_test.exs` — justified.** Five of its seven tests pin `janitor/3`'s config contract (the `true` clause and the `raise`, both round-2 fixes); the other two pin the `:telemetry_event` split by reading the live janitors' state. No plan item asked for the file, but every test in it defends a round-2 fix, and there was no prior home for `Application`-level assertions.

**`Application.janitor/3` made public — the one item I would flag.** It is `@doc false` (`lib/conduit_mcp/application.ex:110`) with an honest inline reason at `:117-118` ("Public (but undocumented) so the config contract can be tested without restarting the application"), so it stays out of ExDoc and out of the compatibility promise. But it is the only production function in this diff whose visibility was widened *for testability*, and `@doc false` does not stop a consumer calling `ConduitMcp.Application.janitor(:session_janitor, [], Foo)`. Acceptable — the alternative is either no test for a fix whose failure mode is an opaque `{:conduit_mcp, {:bad_return, …}}` at consumer boot, or a test that restarts the application mid-suite, which is strictly worse. Worth one line in the commit message so it is a decision rather than a drift.

**Nothing else new in round 2.** The three wider-than-plan items the prior pass recorded (`Handler`'s inverted routing, `ServerMeta`'s prompt/resource scope hooks, the eight security-review behaviour changes) are unchanged; round 2 touched `handler.ex` only to route `handle_notification/3` off the table that already drove requests, which narrows that item rather than widening it.

## Summary

**12 MET · 1 PARTIAL · 0 UNMET · 0 UNCLEAR** across the thirteen round-2 fixes (scored as fourteen separately-falsifiable rows).

2 WARNING · 2 SUGGESTION · 0 BLOCKER.

Every round-2 production change is present at the file:line the assignment named. Twelve are pinned by tests that would fail on revert; one (`Code.ensure_loaded?`) is not. Scope creep is real but proportionate to the defects, and the plan's own 46/46 bookkeeping is accurate.
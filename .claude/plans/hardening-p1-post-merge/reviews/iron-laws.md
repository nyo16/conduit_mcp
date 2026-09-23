# Iron Law Violations Report — hardening-p1-post-merge (closing review)

## Summary
- Files scanned: the 29 changed `lib/**` files, plus `dsl/schema_builder.ex`, `application.ex` and `ets_owner.ex` (read to cross-check claims, not changed in the diff).
- Checks covered: project Iron Laws (create-and-idle `EtsOwner`, direct ETS access, no `handle_call` gateway or new process on a request path, string-keyed MCP maps, `{:ok,_}/{:error,_}`), no `String.to_atom` on input, no bare rescue in new code, bounded work on attacker input, and no plan tags or change narration in HexDocs. Applicable general laws: #10, #12, #13, #15, #19.
- Violations found: **0 BLOCKER, 1 WARNING (VERIFIED, fixed during this review by DslScope), 6 SUGGESTION**.
- Tooling note: this reviewer had Read/Grep only, with no Bash and no `git diff`. Findings come from reading the working tree. The one runtime confirmation was run by peer `DslScope` at my request.

Clean checks (one line, as requested):
- `grep -nE '\bRC[0-9]+\b' lib/` is empty.
- No `String.to_atom` or `binary_to_atom` in `lib/`. `Endpoint.atomize_uri_params/1` and `Validation.existing_atom/1` use `to_existing_atom`.
- No `GenServer.call`, `spawn`, `Task` or `Agent` was added.
- `SSE.Owner` is still a bare `EtsOwner` child spec.
- Every new error path returns a string-keyed JSON-RPC map.
- New rescues are all narrowed (`ArgumentError`, `Joken.Error`).
- No "previously / used to / now returns" narration is left in any `@moduledoc` or `@doc`. The remaining history lives only in `#` comments, which the plan allows.

---

## High Violations (WARNING)

### [W-1] DSL duplicate tool/prompt names: dispatch became first-wins, validation stayed last-wins, so the handler that runs was validated against the other declaration's schema — VERIFIED, FIXED MID-REVIEW
- **Files**:
  - `lib/conduit_mcp/dsl.ex` `first_declaration_wins/1`, used by `generate_tool_clauses/1` and `generate_prompt_clauses/1`: new in this diff.
  - `lib/conduit_mcp/dsl/schema_builder.ex:442-460`: `compile_tool_validation_schemas/1` / `compile_prompt_validation_schemas/1`, unchanged. They do `Enum.reduce(tools, %{}, fn tool, acc -> Map.put(acc, to_string(tool.name), schema) end)` over declaration order, so the **last** declaration wins.
- **Evidence**: DslScope ran a probe (`/private/tmp/conduit_build/dslscope_validation_probe.exs`). Tool `"dup"` is declared twice: the first with `param :n, :integer, max: 10`, the second with no `max`. `tools/call` with `n: 99` reached the **first** handler and accepted 99. The prompt case was the same: `code: "toolong"` was accepted by the first handler despite its `max_length: 3`.
- **Why it matters**: this diff introduced the mismatch. Before it, dispatch and validation both happened to take the last declaration. The deviation note "Dispatch is now de-duplicated first-wins" moved dispatch and scope to first-wins but left validation last-wins. The effect is that the constraints the running handler was written against are silently skipped. This is a validation bypass: a security control is present in the source and absent at runtime.
- **Status**: DslScope fixed it during this review. `dsl.ex` `__before_compile__` (around lines 1251-1260) now passes `Enum.uniq_by(reversed_tools/prompts, &to_string(&1.name))` to `generate_validation_lookup_functions/2`. Regression tests are in `dsl_test.exs` `describe "duplicate declarations"` (red before the fix, green after, per DslScope). **Main must re-run the Phase 7 gates**: the tree changed after compile, credo, dialyzer and the 3-seed suite ran.
- **Remaining (SUGGESTION S-1 below)**: `tool_schemas` / `prompt_schemas` (`dsl.ex:1244-1247`) are still built from **all** declarations. `tools/list` therefore still advertises two `"dup"` entries, and one of their `inputSchema`s is never served.

---

## Medium Violations (SUGGESTION)

### [S-1] Duplicate DSL declarations should be a `CompileError`, as they already are in Endpoint mode
- **File**: `lib/conduit_mcp/dsl.ex` `first_declaration_wins/1`, `scoped_names/1`, `readable_resources/1`, and the new `uniq_by` in `__before_compile__`. Compare `lib/conduit_mcp/endpoint.ex:305-311`, which raises `"duplicate #{type} name(s)"`.
- **Why**: there are two conventions for the same author mistake. The DSL keeps three or four separate de-duplication sites that must agree: dispatch, scope, validation, and the listing, which still disagrees (see W-1). The class of bug found in W-1 exists only because the DSL tolerates duplicates. Raising at `@before_compile` removes every one of those sites and matches Endpoint mode.
- **Confidence**: REVIEW. This is a design choice. The compile-time break is acceptable because the behaviour is unreleased.

### [S-2] SSE `acquire_connection_slot/1` does an O(n) `select_count` on every connect where an O(1) size read is equivalent
- **File**: `lib/conduit_mcp/transport/sse.ex:285, 303, 317` (`count_slots/1` = `:ets.select_count(table, [{{{:slot, :_}, :_}, [], [true]}])`).
- **Evidence**: after B1 removed the `:active` row, the only write to `:conduit_mcp_sse_connections` is `sse.ex:301` (`{{:slot, self()}, ...}`). Every row is therefore a slot row, and `:ets.info(table, :size)` gives the same count in O(1). `select_count` with an unbound key walks the whole `:set` table.
- **Why**: the task brief names "select_count on each connect". It is bounded by `max_connections` plus in-flight acquirers (default 1 000), so this is not a hole, but it is avoidable work on every `GET /sse`. The scratchpad accepted the cost on the grounds that "SSE connects are rare". That is true for honest clients and false for a flood.
- **Fix**: `count_slots(table)` → `:ets.info(table, :size)`, with a comment stating the invariant "table holds only slot rows". `:ets.info/2` returns `:undefined` rather than raising for a missing table, so the fail-closed path needs `is_integer/1` handling or a match. VERIFIED by trace.

### [S-3] At the SSE cap, every rejected `GET /sse` re-runs the full sweep
- **File**: `lib/conduit_mcp/transport/sse.ex:303, 320-326`.
- **Evidence**: `count_slots(table) > max and sweep_dead_slots(table) > max`. `sweep_dead_slots/1` does `:ets.select` of every pid, `Process.alive?/1` on each, and a second `select_count`, on **every** attempt while the table is full.
- **Why**: an unauthenticated client holding `max_connections` live streams (the default config has no auth and no rate limit) makes each further connect cost about 3n ETS/BIF operations. It is bounded (n ≤ `max_connections`), so this is not a violation, but it is attacker-amplifiable CPU on a request path.
- **Fix (optional)**: skip the sweep when one ran within the last ~1 s. For example, keep `{:last_sweep, t}` in the same table (then S-2's size shortcut needs `size - 1`). Or accept it and note in the section comment that the rejected path costs O(max). INFERRED cost. Not probed.

### [S-4] `server.ex`, `application.ex` and `ets_owner.ex` HexDocs still call the SSE table a "counter"
- **Files**:
  - `lib/conduit_mcp/server.ex:24` "`ConduitMcp.Transport.SSE.Owner` — the SSE concurrent-stream counter" (in this diff)
  - `lib/conduit_mcp/application.ex:16-17` "owns the concurrent-stream counter"
  - `lib/conduit_mcp/ets_owner.ex:8` "`ConduitMcp.Transport.SSE`'s connection counter"
- **Why**: B1 replaced the counter with pid-keyed slot rows, and the plan asked to update the `Owner` moduledoc from "counter" to "slot table". `SSE.Owner`'s own moduledoc was updated (`sse.ex:366-368`), but these three published moduledocs were not. It is minor, but they describe the representation this diff exists to change.
- **Fix**: "the SSE slot table (one row per live stream)".

### [S-5] The `handle_request/3` `@doc` bullet misstates the `requestId` rule
- **File**: `lib/conduit_mcp/handler.ex:74-76` ("`requestId` is not a string or an integer → `-32602`").
- **Evidence**: `Cancellation.cancel(nil, _, _)` returns `:ok` (`cancellation.ex` `cancel/3` first clause). So `"requestId": null`, or a missing `requestId`, is **not** an error: the notification returns `:ok`. Only a present, non-null, non-scalar id errors.
- **Fix**: "`requestId` is present and neither a string nor an integer (a missing or `null` id is ignored)". VERIFIED by trace.

### [S-6] Silent no-op for a truthy non-list `:session` (`session: true`, `session: %{}`)
- **File**: `lib/conduit_mcp/transport/streamable_http.ex:104-113, 192-199` (the `is_list(session_config)` gate).
- **Why**: after W6, `session: true`, which a user reads as "turn sessions on", silently means **off**. The implementation note records only that it "no longer crashes". This diff added one-time init validation for `:allowed_origins` for exactly this reason (G4: a misconfiguration should raise at boot, not degrade). The same rule applies here. Because a silently disabled session also changes the cancellation scope to `"ip:"`, it has a (documented) isolation effect.
- **Fix**: in `Shared.init/2` or the StreamableHTTP `__transport_private__/1`, accept `nil | false | keyword()` and raise `ArgumentError` otherwise. REVIEW.

---

## Pre-existing (unchanged code, one line each)
- `lib/conduit_mcp/validation.ex:87-91,120-124` — the non-map `arguments` error echoes `"value" => params` unclamped (the whole ≤1 MB body goes back into `data.errors`). The shape is new (string keys) but the echo is older. `Reflect.text/2` exists for exactly this.
- `lib/conduit_mcp/validation.ex:638` — bare `rescue _ ->` around a user `:validator` fn swallows `KeyError`/`UndefinedFunctionError` from the author's own bug as "validation function error".
- `lib/conduit_mcp/plugs/oauth.ex:286-288` — `peek_header/1` has a bare `rescue _ -> {:error, :invalid_token_format}`.
- `lib/conduit_mcp/principal.ex:201` — `scalar("")` is accepted as an identity, so a verifier returning `%{id: ""}` merges every such caller into one principal. OAuth's `scalar_claim/1` rejects `""`, so the two strategies disagree.
- `lib/conduit_mcp/plugs/auth.ex:252` — `Logger.error("Invalid verify function return: #{inspect(other)}")` is unclamped.
- `lib/conduit_mcp/tasks.ex:114,145` — `function_exported?/3` without `Code.ensure_loaded?/1` (PERSISTENT from round 3).
- `lib/conduit_mcp/handler.ex` telemetry metadata carries the raw `method`/`tool_name`/`uri`/`prompt_name`, giving unbounded label cardinality (PERSISTENT from round 3).
- `lib/conduit_mcp/transport/sse.ex:122` — `connection: keep-alive` on an h2 response (already recorded in the implementation notes).
- `lib/conduit_mcp/transport/sse.ex:108-120` — the 406/503 bodies use atom-keyed maps (plain HTTP errors, not MCP maps, JSON-encoded, so harmless).
- `lib/conduit_mcp/dsl.ex:1838` — `template_regex/2` calls `:persistent_term.put/2` on a request-path cache miss (normally pre-seeded by `@on_load`).

## Prior findings status (round-3 iron-laws.md)
- W1 tuple owner in match spec — **FIXED** (`tasks/ets_store.ex:220` `{:const, owner}`, and the comments on `status_guard`/`unowned_guard` explain why they are safe).
- W2 non-map `params` on `notifications/cancelled` — **FIXED** (`handler.ex` `handle_cancelled/2` → `-32602`, `id: nil`).
- W3 OAuth principal id format undocumented — **FIXED** (`principal.ex:28-38` table plus the aliasing note).
- W4 `nil`-owner semantics backwards — **FIXED** (`principal.ex:61`, `tasks.ex:166-167`).
- S1 notification contract — **FIXED**, with a residual `null`-id imprecision (S-5 above).
- S2 "Agent" ownership docs / `server.ex` child list — **FIXED**. "counter" wording is left over (S-4).
- S3 CHANGELOG `EtsOwner` contradiction — not re-checked (lib-only scope).
- S4 `OptionalDeps` — **FIXED** (`prom_ex_plugin!/0` deleted, no callers left; the `@doc` names `fetch_key/2`).
- S5 `Validation` `@doc` — **FIXED** (string-keyed example, no redundant pointer).
- S6 Cancellation comments — **FIXED**. The new `reclaim/0` frees a full batch across scopes, so the amortisation claim in the comment and the moduledoc now holds. The `foldl` comment names `ordered_set`.
- S7 stale line pointers — **FIXED** (no `:1583`, `handler.ex:NN` or "thirteen lines" remain).
- S8 HexDocs narration and plan tags — **FIXED** (grep clean; narration survives only in `#` comments).
- S9 anonymous `key_func: fn` example — **FIXED** (no `key_func: fn` in `lib/`).

## Fix correctness spot-checks (VERIFIED by trace, no new issue)
- **B1**: insert-then-count never over-admits. The reject path deletes its own row. `release` is idempotent. `Process.alive?(self())` keeps the caller's own row during a sweep. A same-pid re-acquire overwrites (`:set`). `ArgumentError` fails closed. `active_connections/0` is read-only.
- **W3**: the DSL and Endpoint scope scans mirror dispatch. Static clauses come first, including `nil` ones once any template is scoped. Templates follow in dispatch order, with `{:scope, s}` wrapping so an unscoped first match wins. Endpoint `:atomize` skips a template exactly when dispatch skips it. Handler-less DSL resources are excluded from both.
- **G5-S1**: the nested `case` chain runs only the first matching template's handler.
- **W4**: order is lock, then cooldown-with-row, then fetch. A cold cache still fetches. The invented-kid log on the cooldown path is at `:debug`.
- **W5**: `reclaim/0` sorts `{-scope_count, cancelled_at, scope, id}` and takes `batch`. It is bounded by `max_rows` and amortised over `batch` inserts.
- **G6-S6**: every `{:error, reason}` reachable from `verify_token/3`'s `with` maps into `@telemetry_reasons`, and `telemetry_reason/1` has no uncovered producer.
- **G6-S1 / G6-S2**: `true`, `false` and `:ok` derive `nil`, and `:principal_id` with `:function`/`:custom` raises at `init/1`.

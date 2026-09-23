# P1 post-merge fixes (target: ships with P1 in the unreleased v0.10.2)

**Source:** `.claude/plans/hardening-p1-correctness/reviews/post-merge/hardening-p1-correctness-triage.md`
(round-3 review of `378ab15`, `reviews/post-merge/p1-post-merge-review.md`). Finding ids (B1, W1–W13,
G1–G8) are the review's; details and evidence live there.
**Scope:** 1 blocker + 13 warnings + 34 suggestions (G1–G8). Deferred: G9, and all pre-existing items.
**Baseline to preserve:** compile `--warnings-as-errors` (dev + test) · format · `credo --strict` ·
dialyzer 0 · sobelow `--exit medium` · 975 tests on 3 seeds · coverage 90.2 % (floor 86) · bare-consumer check · hex tarball without `mix/tasks`.

## Why one plan

P1 is merged but **unreleased** (`CHANGELOG.md` `[Unreleased]`, `mix.exs` still `0.10.1`). Everything here
fixes, or corrects the documentation of, code that ships in that release. The work is split into phases, and
the phases are ordered so that the documentation phase describes finished behaviour. The P2 (`hardening-p2-structural`)
and P3 (`hardening-p3-performance`) plans are untouched, and nothing here pre-empts them.

## CHANGELOG policy

- Defect in code **new in `[Unreleased]`** (B1, W2, W3, W4, W5, most G items): amend the existing
  `[Unreleased]` entry that describes that code. Do **not** add a "Fixed" line for a bug no release ever shipped.
- Defect already present in **0.10.1** (W1): add a `### Fixed` line.
- Behaviour change relative to 0.10.1 (W6): add it under `### Breaking changes`, with its opt-out.

## Sequencing constraints (do not reorder)

1. **B1 before W12 and before the SSE fail-closed test rewrite.** Both assert against the counter representation B1 replaces.
2. **W5 and W11 in one commit.** The test must pin the new eviction behaviour, not the old one.
3. **W3 and G5-S1 together.** Both rewrite the generated resource dispatch/scope code in `dsl.ex`.
4. **W4 and G6-S4 together.** They change the same function (`jwks.ex` `fetch_keys/1` / `refresh_keys/1`).
5. **Phase 4 (docs) after Phases 1–3 and 5.** W6 changes a documented default, W3 changes scope semantics, and G5-S7
   changes cancellation scope values, so the docs must describe the end state.
6. **W13 after W6.** W6 adds a breaking-change bullet, so the header's count must be computed afterwards.

## Iron Law / convention checks for every task

- ETS owners stay create-and-idle `ConduitMcp.EtsOwner` processes. Callers keep reading and writing ETS directly.
  **No `handle_call` gateway**, and no new process on a request path.
- MCP response maps keep string keys. Callbacks keep `{:ok, _}` / `{:error, _}`.
- No `String.to_atom` on input.
- Every reproduced bug gets a regression test that **fails before the fix**. Run it red first.
- `@moduledoc` / `@doc` / comments must describe the code after the change. Comments cite function names, not line numbers (G3).

---

## Phase 1 — Blocker: SSE slot accounting [otp/ets]

- [x] **B1 — make each SSE slot a pid-keyed row; sweep dead rows at the cap.**
  `transport/sse.ex:112-133,265-317`. Under HTTP/2, Bandit's stream process is linked to the connection and does
  not trap exits. A peer close therefore kills it before `after release_connection_slot()` runs, and the
  node-lifetime counter leaks one slot per disconnect. Reproduced: 10 h2 drops left 10 slots held 10 s later, while
  HTTP/1.1 recovered to 0 (`research/sse_h2_repro.exs`).
  **Decision (user):** pid-keyed rows + sweep at the cap. Rejected alternative: an unlinked monitor process (see scratchpad).
  **Change:**
  - `acquire_connection_slot/1`:
    1. `:ets.insert(table, {{:slot, self()}, System.monotonic_time()})` **first**.
    2. `count = :ets.select_count(table, [{{{:slot, :_}, :_}, [], [true]}])`.
    3. If `count > max`: sweep. Select the `{:slot, pid}` keys, delete every one whose pid is not `Process.alive?/1`, then recount.
    4. If it is still `> max`: delete our own row and return `false`.

    Because each caller inserts before it counts, concurrent acquirers can under-admit at the boundary but never over-admit.
  - `release_connection_slot/0`: `:ets.delete(table, {:slot, self()})`. It is idempotent, so the zero clamp and its comment go.
  - Any `ArgumentError` from ETS → `false` (keep the round-2 #4 fail-closed rule). Delete the `update_active/1` / `:active` counter entirely.
  - `active_connections/0` (`@doc false`): the number of slot rows whose pid is alive, computed read-only (no mutation in a getter).
  - Rewrite the section comment above `acquire_connection_slot/1`: explain why rows are keyed by pid, and name the HTTP/2 link-kill.
    Update the `Owner` moduledoc from "counter" to "slot table".
  - Test seam for fail-closed: `@doc false def __acquire_slot__(table, max)` (the private function takes the table name).
    The route calls it with `@connections_table`.

  **Acceptance:**
  - A new `sse_test.exs` test with `max_connections: 1`. Start a stream in a spawned process, `Process.exit(pid, {:shutdown, :peer_closed})`,
    and the next `GET /sse` gets 200, not 503. It fails against the current code.
  - Re-run `research/sse_h2_repro.exs` with `max_connections: 10`. After 10 h2 drops, `active_connections/0 == 0`, and an 11th
    connection (h2 or HTTP/1.1) is admitted.
  - HTTP/1.1 behaviour is unchanged. Existing `sse_test.exs:254` (503 at `max_connections: 0`) and `:266` (finished connection releases) pass.

- [x] **B1 follow-through — rewrite the SSE counter tests for the new representation (includes W12, G7-S6).** [test]
  - `sse_test.exs:197-238` simulates "counter unreadable" by writing `{:active, :not_a_number}` into the live global
    table, then restores `0` rather than the saved value (G7-S6). Replace it with a call to `__acquire_slot__/2` against a table name that
    does not exist → `false`. The test no longer touches the global table.
  - **W12:** `sse_test.exs:254-264`, the 503 path. Capture `before = SSE.active_connections()` and assert it is unchanged after the 503.
    Mutation check: skipping the own-row delete on the reject path must fail this test.
  - Update the `async: true` justification comment at `sse_test.exs:2-6` if the invariant it states changed.

  **Acceptance:** no test writes `:active`; `grep ':active' lib/conduit_mcp/transport/sse.ex test/conduit_mcp/transport/sse_test.exs` is empty.

---

## Phase 2 — Reproduced correctness defects

- [x] **W1 — `notifications/cancelled` with non-map `params` returns an error, not a 500.** [handler]
  `handler.ex:282-285`. `Map.get(params, …)` on `nil` / `[1]` / `"x"` / `5` raises `BadMapError`. Through the transport this is a
  `Plug.Conn.WrapperError` and a bare 500 (`research/notif_repro.exs`). It was already present in 0.10.1.
  **Change:**
  - `handle_cancelled/2` accepts a missing `"params"` (→ `%{}`, today's `:ok` path) or `%{"params" => %{} = params}`.
  - Any other `params` shape → `Protocol.error_response(nil, Protocol.invalid_params(), "notifications/cancelled requires a params object")`.
  - Update the comment above the function, and the `handle_request/3` `@doc` (the `@doc` wording is finished in G1).

  **Acceptance:** the four reproduced shapes are added to `security_test.exs`'s malformed-notification block at both layers. Direct
  `Handler.handle_request/2` returns the error map. `StreamableHTTP.call/2` returns a JSON-RPC body with no raise, at the
  status `Shared.dispatch_post/2` uses for error maps. `CHANGELOG.md` `### Fixed` line.

- [x] **W2 — wrap the owner as a match-spec constant.** [ets]
  `tasks/ets_store.ex:214`. `{:==, {:map_get, "owner", :"$1"}, {:const, owner}}`. Also check `unowned_guard/0` and `status_guard/1`
  for the same pattern (`status` is always a binary, so it is safe; say so in the comment).
  **Acceptance:** `tasks_test.exs` gets a tuple owner `{:tenant, 7}` and a map owner. `Tasks.list([], owner)` returns exactly that owner's
  rows and no others. It fails today with `ArgumentError: not a valid match specification` (`research/tuple_owner_repro.txt`).

- [x] **W3 — resource scope lookup must follow dispatch, including unscoped resources.** [dsl]
  `dsl.ex:1261-1266,1399-1415,1453-1506`; `endpoint.ex:106-111,454-470`. An unscoped static `user://me` falls through to the
  templated scan and inherits `user://{id}`'s `admin` scope. Reproduced in DSL and Endpoint mode.
  **Change:**
  - **Tools and prompts keep dropping `nil` scopes**, because their catch-all already returns `nil`.
  - **Resources keep `nil`-scoped entries**, in dispatch order, for handled resources only. In `__generate_scope_clauses__`:
    - Emit a `def __scope_for_resource__("user://me"), do: nil` clause for every unscoped static resource.
    - The templated scan walks **all** handled templates. It returns the scope of the **first matching** template, even when
      that scope is `nil`: wrap it as `{:scope, s}` inside `Enum.find_value` and unwrap after.
  - Shortcut: when no resource declares a scope, emit only the plain `nil` fallback. Unscoped servers keep zero cost.
  - Endpoint mode: dispatch skips a matching template whose params fail `atomize_uri_params/1` (`endpoint.ex:374-376`), so the scan
    must skip it too. Add an option to `__generate_scope_clauses__` (e.g. `resource_match: :atomize`), used only by Endpoint.
  - Rewrite the ordering comments at `dsl.ex:1253-1260,1395-1398` and `endpoint.ex:446-453` to state the invariant: the scope lookup mirrors
    dispatch, including unscoped entries.

  **Acceptance:** the review's repro becomes a regression test in `oauth_scope_test.exs`, in DSL **and** Endpoint mode:
  - `resources/read user://me` succeeds without `admin`.
  - `user://42` is still denied without it.
  - The unscoped-template-before-scoped-template variant also dispatches and authorizes the same template.

  The existing clause-count tests (`oauth_scope_test.exs:313-420`) are updated to the new shape and still assert one clause per URI.

- [x] **G5-S1 — templated DSL resource dispatch must be lazy.** [dsl]
  `dsl.ex:1650-1679`. `unquote(template_clauses) |> Enum.find_value(…)` builds the list, which **evaluates every matching template's handler**
  before picking the first. Two overlapping templates therefore run both handlers and their side effects. Endpoint mode is already lazy.
  **Change:** emit a list of `{template, fn conn, params -> … end}` pairs, or a nested `case` chain, so a handler runs only after
  every earlier template has failed to match.
  **Acceptance:** a test with two overlapping templates, where the second handler `send`s to the test pid. `refute_received` when the first matches.

- [x] **G5-S6 — a non-binary `uri` gets `-32602`, not `-32603`.** [handler]
  `handler.ex:433-447,665-676`. `Regex.run/2` on a non-binary raises inside the rescued request path. Gate with `is_binary/1` in
  `resources/read`, `subscribe`, `unsubscribe` and `completion/complete` (`ref.uri`), and return `invalid_params` with a `Reflect.text/2`-clamped value.
  **Acceptance:** `security_test.exs` cases for `"uri" => 5` and `%{}` on a scoped server assert `-32602` and no `[error]` log.

---

## Phase 3 — Availability under hostile load [security]

- [x] **W4 + G6-S4 — gate the JWKS miss branch on the cooldown; stop the misleading log.**
  `oauth/key_provider/jwks.ex:122-179`. After the TTL lapses with the IdP failing, `serve_stale/3` never rewrites `cached_at`, so every
  request is a `:miss` → `fetch_and_cache/2`. The lock bounds concurrency, not rate, and `authenticate` runs before `rate_limit`.
  **Change:**
  - In `:miss`:
    - cold cache (no row): fetch, exactly as now;
    - cached row and `cooling_down?/2`: `serve_stale/3` (which enforces `:stale_max_age`);
    - otherwise: `fetch_and_cache/2`, which already routes a held lock to `await_refresh/3`.
  - Keep the single-flight wait. A request that arrives after the winner recorded `:last_refresh` but before it published must still
    wait, not fail. The comment at `:132-139` explains exactly this race: rewrite that comment, and make sure the lock check comes before the cooldown check.
  - **G6-S4:** the invented-`kid` path during cooldown logs a "refresh failed" warning that is false. Log it at `:debug`, or not at all, when the
    miss is cooldown-suppressed (the `serve_stale(jwks_uri, :not_found, config)` call at `:175`).

  **Acceptance:** new `jwks_test.exs` cases:
  - A warm-but-expired cache with a failing IdP (Req.Test stub that counts calls): 50 sequential `fetch_keys/1` calls within the cooldown → exactly 1 outbound fetch, all served stale.
  - A cold cache still fetches.
  - The existing single-flight test (`jwks_test.exs:271`) and stale-lock test (`:301`) still pass.
  - Invented kid during cooldown → no `[warning]` (`capture_log`).

- [x] **W5 + W11 — reclaim frees a full batch, largest scopes first (one commit).**
  `cancellation.ex:316-351`; tests `cancellation_test.exs:184-222`.
  **Change:**
  - `reclaim/0` does one `:ets.select` of `{scope, id, cancelled_at}` and computes the frequencies.
  - It evicts rows ordered by `{-scope_count, cancelled_at}` until `batch` rows are gone: oldest-first within the largest scopes, then the next
    largest. With many 1-row scopes it therefore still frees `batch` rows per scan, and ties break on age, not on `Enum.max_by` order.
  - Rewrite the cost comment (`:320-323`) with the real amortisation, and the moduledoc bullet (`:64-72`).
  - **W11:** seed 2 older `"bystander"` rows, fill with `"hog"`, and trigger reclaim from a third scope. Assert: bystanders still 2, caller's row present,
    hog count dropped by `batch`. Add a second case: 1-row scopes only → exactly `batch` rows evicted, oldest first.

  **Acceptance:** both tests fail against the current `reclaim/0` (the 1-row-scope case frees 1 row).

- [x] **W6 — no sessions unless `:session` is configured.**
  `transport/streamable_http.ex:193-208`. **Decision (user):** treat `nil` like `false`.
  **Change:**
  - `create_session_for_initialize/2` creates a session only when `is_list(session_config)`. The now-dead `_ -> Session.EtsStore` branch
    in `create_session/3` goes.
  - `:session` option doc (`streamable_http.ex:31-34`): "sessions are off unless configured".
  - `README.md:499` — the `# Default` comment is false after this. Show `session: []` as the opt-in (EtsStore by default), and `session: false` as equivalent to omitting it.
  - Check `guides/multi_node_sessions.md:216` for consistency.

  **Acceptance:**
  - With no `:session`, an `initialize` response has no `mcp-session-id` and the session table does not grow.
  - The `@session_opts` tests in `streamable_http_test.exs:404-584` are unchanged and still pass.
  - Any test that relied on implicit sessions is updated.
  - `CHANGELOG.md` `### Breaking changes` gets a bullet with the one-line opt-in (`session: []`).

---

## Phase 4 — Documentation matches code [docs]

- [x] **W7 — document the exact principal id formats.** `principal.ex:28-38`, `guides/authentication.md:155-162`.
  - `:oauth` → `"sub:<v>"` or `"client_id:<v>"`, with the aliasing rationale.
  - `:function`/`:custom` → `derive_id/1`'s formats, including `"<Struct>:<id>"`. Note `:custom` in the strategy comment.
  - `:bearer_token`/`:api_key` → `:principal_id` or the digest.
  - Add a one-line doctest or an example for each format.

  **Acceptance:** the table and the moduledoc state the same formats that `principal_test.exs:64` and `oauth_test.exs:708` pin.

- [x] **W8 — correct the `nil`-owner semantics everywhere.**
  - Sites: `principal.ex:40`, `tasks.ex:185`, the `tasks.ex` `create/3` `@doc`, and `handler.ex:709-713`.
  - Replace each with: "`nil` = no principal: sees only unowned tasks; nothing under `:tasks_require_owner` (see `get/2`)."
  - Grep `lib/` and `guides/` for "no scoping", "readable by anyone" and "no-op" near owner/scope, and fix every hit.

- [x] **W13 + G2 (CHANGELOG half) — make `[Unreleased]` accurate.** `CHANGELOG.md:15-44` and the `EtsOwner` entries.
  - **Decision (user):** reword, no opt-out. RC9's `-32602`/`-32002` codes are a spec-conformance fix with no opt-out, and the entry says so.
  - The header count must equal the bullets actually listed under it, including W6's new bullet (constraint 6).
  - `EtsOwner`: "Added" says it degrades and "Fixed" says it retries. Keep the true one (it retries every 1 s and re-raises on bad opts).
  - Fold in the amendments the CHANGELOG policy above requires for B1/W3/W4/W5/G4/G5-S7/G6.

  **Acceptance:** requirement #45 from the P1 plan re-scores MET: every "breaking" bullet either has an opt-out or states why it has none.

- [x] **G1 — notification and cancellation contract docs.**
  - `handler.ex:62-78`: list **every** notification that returns an error map: bad `requestId`, non-map `params` (W1), and
    `:cancellation_limit_reached`. Switch that last one from `internal_error` (-32603) to `-32000` server error (`Protocol.server_error/0`),
    and assert the code in the existing cap test. This closes round-2 #19.
  - `cancellation.ex:136-142`: the `cancel/3` `@doc` must say that only the per-scope quota rejects.
  - `cancellation.ex:270-271`: "safe for set tables" — the table is an `ordered_set`. State the guarantee that actually applies (ETS allows deleting the
    current key during `foldl` on any table type) or restructure.
  - The O(20) amortisation claim: already rewritten in W5. Verify the two agree.

- [x] **G2 (code half) — no "Agent" in the ownership docs; complete `server.ex`'s child list.**
  - "Agent" at `session/ets_store.ex:12,190`, `tasks/ets_store.ex:6` and `jwks.ex:181` → "`ConduitMcp.EtsOwner` process".
  - The `server.ex` moduledoc lists `Transport.SSE.Owner` and `Cancellation.Janitor`, matching `CLAUDE.md:35-38`.

- [x] **G3 — comment and published-doc hygiene.**
  - Replace rotted line references with function names: `dsl.ex:1254` ("`:1583`"), `reflect.ex:106-107` ("`handler.ex:69-73`"), `tasks/ets_store.ex:172` ("thirteen lines above").
  - Move change narration and plan tags (`RC2`, `RC3`, "previously…", "used to…") out of `@moduledoc`/`@doc` text and into the CHANGELOG. Sites:
    `tasks/ets_store.ex` `list/1` `@doc`, `principal.ex`, `cancellation.ex`, `transport/shared.ex`, `tasks.ex` `get/2`, `reflect.ex`,
    the `schema_converter.ex` compile-time message, `origin_validation.ex`, `sse.ex:264`, `validation.ex:434`.
  - Code comments explaining *why* may keep history. HexDocs text may not.

  **Acceptance:** `grep -nE '\bRC[0-9]+\b' lib/` is empty; `mix docs` builds without warnings.

- [x] **G4 — API doc drift.**
  - `plugs/message_rate_limit.ex:88-93`: the anonymous `key_func: fn` example → `&MyApp.RateKeys.msg/1`. State "callbacks in transport opts must be
    remote captures (`Plug.Router.forward` escapes init opts)" in the `transport/shared.ex` moduledoc, and in `plugs/rate_limit.ex` if it shows the same example.
  - `OptionalDeps`: delete `prom_ex_plugin!/0` if it still has no caller in `lib/` (check `lsp references` first), and fix the
    `validate_key_provider!/1` `@doc` to name `fetch_key/2`.
  - `Validation.validate_tool_params/3` `@doc`: returned errors are already formatted, so drop the `format_validation_errors/1` pointer and use string keys in the example.
  - `:allowed_origins` Regex: document that it must be anchored (`~r/\Ahttps:\/\/example\.com\z/`). Validate the option's shape **once** in
    `Shared.init/2`, raising `ArgumentError` naming the accepted shapes, instead of `Logger.error` per request.

  **Acceptance:** an invalid `:allowed_origins` raises at `init/1`, pinned by test; the `forward` compile test still passes.

---

## Phase 5 — Robustness and auth hardening

- [x] **G5-S2 — SchemaConverter: bad value for a known key ≠ unknown key.** `validation/schema_converter.ex:222-257`.
  A recognised constraint with a bad value (e.g. `min: "5"`) must raise "invalid value for :min", not "unknown option … did you mean :min?".
  Check whether `type_coercion: false` failing the build is intended. If it is a valid option, accept it. **Acceptance:** tests for both messages; `type_coercion: false` compiles.
- [x] **G5-S3 — `Tasks.list/2` enforces `:limit` after the owner re-check.** `tasks.ex:171-176`.
  Add `Enum.take/2` after the pinned-owner filter, so a store that honours `:limit` but ignores `:owner` cannot hand the caller other rows or
  truncate their own. **Acceptance:** a test store stub that ignores `:owner` shows the caller gets ≤ limit rows, all their own.
- [x] **G5-S7 — namespace cancellation scope keys.** `cancellation.ex:130-132`: `"session:" <> id`, `"principal:" <> id`, `"ip:" <> ip`.
  The telemetry `scope` metadata changes with it (unreleased, so amend the entry). **Acceptance:** a principal whose id equals a client IP string no longer shares a quota with that IP.
- [x] **G6-S1 — `derive_id/1` rejects non-identities.** `principal.ex:148,154-157`. `true`, `false` and `:ok` → `nil`, so `auth.ex:252` falls back to the
  credential digest. Update the `@doc` list of accepted shapes. **Acceptance:** two different credentials whose verifiers return `{:ok, true}` get different ids.
- [x] **G6-S2 — `:principal_id` is only for static strategies.** `plugs/auth.ex:131-132,252`. Raise `ArgumentError` at `init/1` when
  `:principal_id` is set with `:function`/`:custom`; it would merge every user into one principal. The option is unreleased, so this is not a
  break. Document it in `auth.ex:25-28`. **Acceptance:** init raises for `:function` + `:principal_id`; static strategies are unchanged.
- [x] **G6-S6 — OAuth telemetry reasons are atoms, not attacker text.** `plugs/oauth.ex` failure telemetry. Map every `reason` to a fixed atom set
  (`:expired`, `:invalid_issuer`, `:invalid_signature`, `:alg_not_allowed`, …) and keep header-derived strings out of metadata.
  **Acceptance:** a token with header `alg: "<script>"` emits a telemetry reason that is an atom from the documented set.

---

## Phase 6 — Test quality [test]

- [x] **W9 — the unloaded-store janitor test must not purge a production module.** `session/janitor_test.exs:173-213`.
  Compile a throwaway store module with `Code.compile_string/1`, write its `.beam` to a tmp dir, `Code.prepend_path/1`, then `:code.purge/1` + `:code.delete/1` **it**.
  Its `cleanup/1` sends to the test pid. **Acceptance:** `ConduitMcp.Cancellation` is never purged. Reverting the `Code.ensure_loaded?` in `janitor.ex` still fails the test.
- [x] **W10 + G7-S1/S2 — JWKS tests assert what their titles claim.** `oauth/jwks_test.exs`.
  - W10 (`:97-114`): gzip a **valid** key set with `content-encoding: gzip` and assert `{:error, :invalid_jwks}`. Drop the 64 MB payload and the "cannot expand in memory" title.
  - S1: the "while streaming" title → describe what Req.Test actually delivers (one chunk). Drop the 8 MB allocation.
  - S2: the waiter test asserts a waiter existed (`refute_received :outbound_fetch` on the waiter side).

  **Acceptance:** forcing `compressed: true` in `jwks.ex` fails W10's test.
- [x] **G7-S3/S4/S5 — `ets_owner_test.exs` determinism.**
  - S3 (`:71-104`): replace the sleep-poll (up to 6 s) with `send(owner, :reclaim)` + `:sys.get_state/1` as a sync barrier.
  - S4: delete the dead `trap_exit` `on_exit` at `:57`.
  - S5 (`:121-133`): make the `Code.ensure_loaded?` JWKS guard meaningful, or remove it.

  **Acceptance:** the module runs in < 1 s.
- [x] **G7-S7…S11 — small test fixes.**
  - S7: stale "only consumer" comment at `handler_tasks_test.exs:252-254`.
  - S8: `rate_limit_test.exs:227-234` shares the global `"unknown"` bucket. Use a recording backend so it is repeatable in one VM.
  - S9: `application_test.exs:68-90` stops reading `:sys.get_state(pid).event/.store` and asserts observable behaviour (the telemetry event emitted and the store swept).
  - S10: `optional_deps_test.exs:20-22`. Fix the title contradiction and delete the duplicate of `:39-42`.
  - S11: delete the duplicates at `protocol_test.exs:100-116` (vs `:118-131`), `handler_tasks_test.exs:114/195` and `streamable_http_test.exs:95-98`.
- [x] **G7 (requirements S3) — pin Endpoint-mode prompt scope.** In `oauth_scope_test.exs`, add deny and allow tests for a scoped prompt component in Endpoint mode.
- [x] **G8 — quiet test output.** `test/test_helper.exs:14`: `ExUnit.start(capture_log: true, …)`. Confirm no test depends on log output reaching the console,
  and that the protocolVersion log line is clamped (`Reflect.text/2`). **Acceptance:** a passing `mix test` prints < 50 lines.

---

## Phase 7 — Verify

- [x] `mix compile --warnings-as-errors` (dev and `MIX_ENV=test`, `--force`)
- [x] `mix format --check-formatted` · `mix credo --strict` · `mix dialyzer` (0) · `mix sobelow --config --exit medium`
- [x] `mix test` on 3 seeds (random, `--seed 0`, one fixed). Report the count, which is expected to rise above 975.
- [x] `MIX_ENV=test mix coveralls` ≥ 86 %, and not below 90.2 % without a stated reason.
- [x] `bash .github/scripts/bare_consumer_check.sh` OK · `mix hex.build` tarball has no `mix/tasks`.
- [x] Smoke tests: `research/sse_h2_repro.exs` (B1 acceptance), `research/notif_repro.exs` (W1: every shape → JSON-RPC body, no raise), and the tuple-owner repro (W2).
- [x] `mix docs` builds without warnings (G3).
- [x] Re-run `/phx:review` on the diff. It is also the closing security pass the P1 plan's requirement #46 asked for (G9, deferred bookkeeping).

## Deferred (user)

- **G9:** relabel `hardening-p1-correctness/plan.md:256`'s re-audit checkbox. Bookkeeping only; the Phase 7 re-review stands in.
- **Pre-existing (10 items, review § Pre-existing):** not in scope. Cheapest follow-up candidate: `handler.ex:119`, a request with non-map `params`
  → `-32603` instead of `-32602`. It is W1's twin.

## Implementation notes (/phx:work, 2026-09-23)

Result: 1 014 tests (5 doctests, 9 properties, 1 000 tests) green on a random seed, `--seed 0` and `--seed 424242`; passing run prints 6 lines.
Coverage 90.7 %. Compile `--warnings-as-errors` (dev + test, `--force`), format, `credo --strict`, dialyzer 0, sobelow `--exit medium`,
bare-consumer check, hex tarball (no `lib/mix`), `mix docs` 0 warnings. Smoke: h2 repro (10 h2 drops → `active_connections() == 0`,
11th admitted over h2 and HTTP/1.1), notif repro (every shape → JSON-RPC body), tuple/map owner lists own rows.

Deviations from the plan text:
- **DSL duplicate declarations (beyond plan, security):** on Elixir 1.20/OTP 29, adjacent *generated* clauses with identical heads and a
  variable before the binary (`handle_call_tool(conn, "x", p)`) resolve to the **last** clause; the scope lookup used the first → scope bypass.
  Dispatch is now de-duplicated first-wins (DSL tools/prompts/static resources, Endpoint static resources). Probe: `/private/tmp/conduit_build/dslscope_matrix.exs`.
  Follow-up: `SchemaBuilder.generate_validation_lookup_functions` emits duplicate `__validation_schema_for_tool__/1` heads the same way.
- **W3:** nil static clauses + scan emitted only when a *template* declares a scope (static-only scoping gives nil for every template anyway).
  Endpoint templated dispatch: first matching template whose params atomize wins, even if `execute/2` returns nil (no fall-through).
- **G5-S1:** a DSL template handler returning nil no longer falls through; reported as internal error like a static handler.
- **W10:** "forcing `compressed: true` fails the test" is unachievable — Req ignores `compressed:` when `into:` streams. The test fails if
  decompression becomes reachable (compressed: true + no `into:` collector).
- **W11 test 1** (bystanders) passes on old code too; its mutant (evict globally oldest) fails it. Test 2 (1-row scopes) is the red one.
- **G1:** no handler-level cap test existed; added one in `handler_test.exs`.
- **G5-S2:** per-param `type_coercion: boolean` now overrides the global setting (accepting-and-ignoring would silently drop it).
  Non-map input to `validate_tool_params/3`/`validate_prompt_args/3` now returns string-keyed errors (G4 doc truth).
- **G4:** `OptionalDeps.prom_ex_plugin!/0` deleted (no caller; lsp unavailable, grep-verified). `:allowed_origins` list containing a Regex is rejected at init.
- **W6:** `validate_session/2` uses the same `is_list` rule, so `session: true` no longer crashes.
- **G6-S6:** OAuth telemetry reason set: :expired :not_yet_valid :invalid_issuer :invalid_audience :invalid_signature :malformed_token
  :missing_alg :alg_not_allowed :alg_mismatch :unsupported_key_type :invalid_key :key_not_found :key_unavailable :missing_subject.

Found, not fixed (out of scope): `GET /sse` sends `connection: keep-alive`, forbidden in HTTP/2 (RFC 9113 §8.2.2); strict h2 clients (curl)
reject every SSE response (exit 92).

Review (2026-09-23): REQUIRES CHANGES (0 blockers, 7 warnings) → triage → all 17 fixed; see
`reviews/hardening-p1-post-merge-review.md` and `reviews/hardening-p1-post-merge-triage.md`. The DSL first-wins dedup described
above was replaced by a CompileError on duplicate declarations (SG1).

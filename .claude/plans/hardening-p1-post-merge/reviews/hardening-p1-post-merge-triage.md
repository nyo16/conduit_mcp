# Triage: P1 post-merge review (2026-09-23)

**Source:** `hardening-p1-post-merge-review.md`. Details, evidence and recommended fixes are in `../summaries/review-consolidated.md`.
**User guidance:** "Just fix them", using the approach the review recommends for each item.

The user first selected none of W1–W4. When asked to confirm, they chose to include all four.

SG1 replaces the first-wins dedup with a `CompileError`. W6's test therefore checks that compile error, not dispatch order.

## Fix Queue

### Warnings
- [x] **W1**: allow `:principal_id` only when the static `:token` or `:api_key` is configured. Raise `ArgumentError` at `init/1` otherwise, e.g. for `verify:` with the `:bearer_token` default or with `:api_key`. Update the moduledoc. Add red-first `auth_test` cases for both configs.
- [x] **W2**: fix the telemetry path in `handler.ex` and `telemetry.ex`.
  - `handle_resource_read/4` emits `uri` only when it is a binary, otherwise `nil`. Document the metadata type as `String.t() | nil`.
  - The default handlers render client-sourced metadata (`uri`, `tool_name`, `prompt_name`, `method`) through `Reflect.text/2`.
  - Red first: `"uri" => %{}` with the default logger attached at debug level must leave the handler attached.
- [x] **W3**: fix the `tasks/store.ex` `list/1` `@doc`. A store that ignores `:owner` must also ignore `:limit`, because honouring `:limit` alone truncates the caller's own rows.
- [x] **W4**: `security_test.exs` G5-S6 tests: replace `log == ""` with refutations of the regression's own signature.
- [x] **W5**: `jwks_test.exs` waiter test: add `refresh_cooldown: 0`, so a serialised task fetches and fails the test.
- [x] **W6**: duplicate prompt declarations are covered by SG1's `CompileError` test.
- [x] **W7**: make the `EtsOwner` reclaim interval injectable (default 1 000 ms). Test that the owner re-arms and reclaims by itself with a short interval, with no 1 s sleeps.

### Suggestions
- [x] **SG1**: a duplicate DSL tool name, prompt name or resource URI raises a `CompileError` in `@before_compile`. Add the missing duplicate resource-URI check to Endpoint. Delete the dedup sites (`first_declaration_wins/1`, the `uniq_by` calls, `readable_resources/1` dedup, Endpoint `uniq_by`) and their "last clause" comments. Rewrite the CHANGELOG duplicate-declarations line: this is unreleased, so the entry becomes "raises at compile time", and the Fixed line explains why.
- [x] **SG2**: make the SSE per-connect cost cheaper.
  - Count with `:ets.info(table, :size)` (O(1)), with an `is_integer` check to keep fail-closed.
  - Do not re-sweep on every rejected connect at the cap. If a sweep ran within about 1 s and freed nothing, skip it. No new process.
- [x] **SG3**: replace the "counter" wording in the `server.ex`, `application.ex` and `ets_owner.ex` moduledocs with "slot table".
- [x] **SG4**: add a catch-all clause to `telemetry_reason/1` in `plugs/oauth.ex`. Add a test that every emitted reason belongs to `@telemetry_reasons`.
- [x] **SG5**: validate options at `Shared.init/2`.
  - `:session` must be `nil | false | keyword`. Anything else raises and names `session: []`.
  - SSE `:max_connections` must be a positive integer.
  - Test that the `session: []` opt-in issues a session id.
- [x] **SG6**: fix the JWKS cooldown edge cases.
  - Past `:stale_max_age`, the fail-closed branch honours `context == :cooldown` and logs at debug instead of error.
  - A cold cache inside the cooldown returns `{:error, :refresh_cooldown}` instead of fetching back-to-back.
  - `refresh_keys/1` checks the lock before the cooldown.
  - Reword the comment in `fetch_on_miss/2`.
- [x] **SG7**: correct the `reclaim/0` comment and the moduledoc about 1-row-scope ties and concurrent racers. Optionally single-flight `reclaim/0` with an `insert_new` lock row.
- [x] **SG8**: doc fixes.
  - `handle_request/3` `@doc`: a missing or `null` `requestId` is ignored.
  - Document the per-param `type_coercion:` in the DSL `param` docs and in the Component `field` docs.
  - The `strip_markers/1` `@doc` names `:type_coercion`.
- [x] **SG9**: robustness fixes.
  - `Cancellation.scope/1` tolerates a non-binary principal id (only a binary id goes into `"principal:"`).
  - `owner_guard` uses `:"=:="`.
  - Endpoint and DSL decide atomizability per template at compile time.
  - The nested-case compile time is left as is. Measure it if a flat shape isn't cheap.
- [x] **SG10**: test hardening (TST S1–S5, S7–S11).
  - JWKS stale-serve tests assert that a refresh was attempted.
  - The W3 "void" test asserts that `__scope_for_resource__` returns nil and that the message does not say "Insufficient scope".
  - Add a W5 spill-over test.
  - Tuple owners with match-spec-special atoms (`:_`, `:"$1"`).
  - Move the `Code.put_compiler_option` test out of the async module, or document why it can stay.
  - `<=` for the W6 table-size assertion.
  - W10 comment. Correct the SSE fail-closed comment. Delete the redundant `@tag :capture_log`.

## Skipped

None.

## Deferred

- The 21 pre-existing items in `../summaries/review-consolidated.md` § Pre-existing. The strongest follow-up candidates are:
  - `requestId` length unbounded (256 × ~1 MB per scope)
  - `connection: keep-alive` on h2 SSE
  - session not bound to its principal
  - raw client strings in telemetry metadata

## Result (2026-09-23)

All 17 items fixed. Gates: compile `--warnings-as-errors` (dev + test, `--force`), format, `credo --strict`, dialyzer 0,
sobelow (`--exit medium` and the conf's `exit: "low"`), 1 041 tests green on seed 0, 424242 and random (6 output lines),
coverage 91.7 %, `mix docs` 0 warnings, bare-consumer OK, tarball without `lib/mix`, smoke repros re-run green.
Extra (found during fixes): `Principal.id/1` returns only strings (covers `rate_limit_key/1` and cancellation scope).
`.sobelow-conf` `skip: true` so the single `# sobelow_skip ["DOS.StringToAtom"]` on `Endpoint.template_param_atoms/1`
(compile-time URI literal) is honoured; the check stays active elsewhere.
Behaviour notes: `max_connections: 0` now raises (positive integer required); duplicate DSL declarations are a
CompileError (Breaking bullet #10); JWKS cold cache after a failed fetch returns `{:error, :refresh_cooldown}` inside the window.

## Follow-up (branch `hardening/p1-post-merge`, 2026-09-23)

Promoted from Deferred and fixed: SSE `connection: keep-alive` on HTTP/2 (removed); MessageRateLimit raw `method`
(nil in telemetry, `Reflect` in the log); `requestId` capped at 256 bytes; `notifications/cancelled` recorded only for
requests in flight in the caller's scope (`:conduit_mcp_in_flight`, `Cancellation.InFlightOwner`, dead-pid sweep in
`Cancellation.cleanup/1`); anonymous IPv6 keys and cancellation scopes bucket by /64 (`Principal.client_bucket/1`,
Breaking bullet #11). Gates: 1 061 tests on 3 seeds, dialyzer 0, sobelow, credo, docs 0 warnings, coverage 91.7 %,
bare-consumer OK; curl `--http2-prior-knowledge` now streams `event: endpoint` (exit 28 at --max-time, was 92).

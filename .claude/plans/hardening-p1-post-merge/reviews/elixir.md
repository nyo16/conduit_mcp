# Code Review: hardening-p1-post-merge (uncommitted `git diff HEAD`, lib/**)

Elixir reviewer, Phase 7 closing pass. This agent had **no Bash**, so it ran no `git diff`,
`mix test` or `mix run` probes. It read the post-change files directly.
- **VERIFIED (trace)**: followed through the source, citing the lines.
- **INFERRED**: reasoned, not executed.
- **UNVERIFIED**: a claim in the diff this agent could not check.

## Summary
- **Status**: ⚠️ Changes Requested (no blockers)
- **Issues found**: 0 BLOCKER · 2 WARNING · 9 SUGGESTION · 2 PERSISTENT (one line each)

Fix-by-fix verdict (each traced against the post-change code):

| Fix | Verdict |
|---|---|
| B1 SSE pid-keyed slots | Correct. Insert-then-count cannot over-admit, the reject path deletes its own row, release is idempotent, `active_connections/0` is read-only, and ArgumentError fails closed. No new process. |
| W1 non-map cancelled params | Correct. `"params": null` is also rejected, which matches the `@doc` ("present but not an object"). |
| W2 `{:const, owner}` | Correct. The `status_guard/1` and `unowned_guard/0` comments are accurate. |
| W3 scope mirrors dispatch | Correct in DSL and Endpoint for static, templated, handler-less, unscoped-first-template and non-atomizable-template cases. Unscoped servers emit only the `nil` fallbacks, so they pay nothing extra per request. |
| G5-S1 lazy templated dispatch | Correct. The nested `case` runs exactly one handler, and the `nil`/`false` no-fall-through change is in the CHANGELOG. Compile-time cost: see S1. |
| W4 JWKS miss ordering | Correct as specified: lock → cooldown (cached row) → fetch. G6-S4 is fixed for the within-`stale_max_age` path only (see S4). |
| W5 reclaim | Correct. A full batch is freed even with 1-row scopes, ties break on age, and the O(20 log n) amortisation holds. One doc overclaim: S5. |
| G1 / G5-S6 / G5-S2 / G5-S3 / G5-S7 | Correct. For G5-S3, the "truncate their own" half is not fixable in the facade and stays PERSISTENT. |
| First-wins duplicate dedup | Dispatch and scope now agree, but **validation does not** (W1 below). |

---

## Critical Issues

None.

---

## Warnings

### W1. Duplicate DSL tool/prompt names: dispatch and scope are first-wins, but the validation schema is still last-wins — VERIFIED (trace)

**Files**: `lib/conduit_mcp/dsl.ex` (`generate_tool_clauses/1`, `generate_prompt_clauses/1` → `first_declaration_wins/1`, around lines 1420-1430 and 1630-1690). The last-wins half is in the unchanged `lib/conduit_mcp/dsl/schema_builder.ex:445-493`.

```elixir
# schema_builder.ex — reversed_tools is declaration order, so Map.put keeps the LAST
Enum.reduce(tools, %{}, fn tool, acc ->
  Map.put(acc, to_string(tool.name), build_nimble_options_schema(tool))
end)
...
def __validation_schema_for_tool__(tool_name) do
  case unquote(Macro.escape(tool_dual)) do %{^tool_name => dual} -> dual ... end
end
```

`dsl.ex` now emits only the **first** declaration's `handle_call_tool/3` / `handle_get_prompt/3` clause, and
`scoped_names/1` answers with the first declaration's scope. `Handler.handle_tool_call` validates with
`__validation_schema_for_tool__/1` (last declaration) and then dispatches to the first. The first handler therefore
receives params checked against the **second** declaration's schema. Example: first
`param :id, :integer, required: true, min: 1`, second with no params. The first handler then gets unvalidated,
uncoerced params. Prompts behave the same way through `compile_prompt_validation_schemas/1`.

This mismatch comes from the diff. Before it, dispatch was (per the diff's own claim) last-wins, which agreed with validation.
The diff also documents the opposite:
- CHANGELOG `[Unreleased]` ("Dispatch and scope lookup now both use the first declaration") is incomplete.
- The plan's implementation note says the follow-up is that `generate_validation_lookup_functions` "emits duplicate
  `__validation_schema_for_tool__/1` heads the same way". It does not. It emits a **single** clause over a map, and the
  map is last-wins by construction, not because of clause order. The planned follow-up is aimed at the wrong mechanism.
- `tools/list` / `prompts/list` still advertise **both** declarations (`tool_schemas` is built from all `reversed_tools`),
  so clients see two tools with one name and two different input schemas.

**Why it matters**: a validation bypass behind a developer mistake the build accepts silently. `min:`, `enum:`,
`validator:` and required-ness on the handler that actually runs are not enforced.

**Recommended approach** (preferred first):
1. Reject duplicates at compile time. Raise `CompileError` for a duplicate DSL tool name, prompt name or resource URI, as
   Endpoint already does for tools and prompts (`endpoint.ex` `validate_no_name_conflicts!/3`), and add the missing
   resource-URI check to Endpoint. This also makes the unverified "clauses resolve to the last" rationale (S9) irrelevant,
   and removes `first_declaration_wins/1`, the `uniq_by`s and their comments.
2. If duplicates must stay legal, make `compile_*_validation_schemas/1` first-wins (`Map.put_new/3`), de-duplicate
   `tool_schemas`/`prompt_schemas`/`resource_schemas` the same way, and add a test that pins validation for a duplicated
   name.

### W2. `Tasks.Store` `list/1` `@doc` still says a store ignoring `:owner` is "slow rather than unsafe" — VERIFIED (trace), PERSISTENT (prior S3, doc half)

**File**: `lib/conduit_mcp/tasks/store.ex:141-150` (changed in this diff).

```
`ConduitMcp.Tasks.list/2` re-checks the returned rows and re-applies `:limit`, so a store that ignores
`:owner` is slow rather than unsafe
```

`Tasks.list/2` passes `:limit` to the store and filters afterwards (`tasks.ex:169-175`). A store that honours `:limit`
and ignores `:owner` returns the first N rows of *anyone*. The filter then leaves the caller with fewer of their own
rows, or none, even though more exist. The facade cannot repair that. G5-S3 fixed "more than limit" and "other
callers' rows", but this doc now claims the combination is merely slow. The prior review asked for the doc to say that
`:limit` is only correct when honoured together with `:owner`.

**Recommended approach**: amend the `@doc`: "a store that ignores `:owner` must also ignore `:limit`. Honouring
`:limit` alone truncates the caller's own rows before the facade's owner re-check." Alternatively, make the facade
withhold `:limit` from stores that do not declare owner support. The doc fix is enough.

---

## Suggestions

### S1. G5-S1 nested `case` chain: one function body nested N deep — INFERRED
`dsl.ex` `generate_templated_resource_clauses/1` / `generate_templated_resource_match/2`.

What was checked:
- The generated shape is correct and lazy. Each level binds `{param_names, regex}` in the enclosing level's `:no_match`
  branch, so a template's regex is fetched only after every earlier template failed to match.
- Hygiene is sound. `conn`, `uri` and `params` share the `ConduitMcp.DSL` context. An app-view-only chain's unused
  `conn` does not warn, because only `nil`-context vars do.
- Per-request cost equals the old scan's.

The chain inlines every templated handler's `fn` AST into **one** function nested N levels deep. Elixir expansion and
the Erlang compiler passes recurse per level. [INFERENCE] Compile time should stay near-linear for tens of templates,
but it is unmeasured for hundreds, and a crash inside a deep chain produces a hard-to-read stack trace.

**Recommendation**: a flat, equally lazy shape. Emit one `defp __read_template__(index, conn, params)` clause per
template, plus a literal `[{template, index}]` list scanned with `Enum.find_value/2` that returns `{index, params}`,
then call once. Or add a `mix bench`/compile-time smoke with about 200 templates to pin the cost.

### S2. Per-param `type_coercion:` is undocumented where users write it — VERIFIED (grep)
The new option is documented only in the `SchemaConverter` and `Validation` moduledocs. The option lists that
developers read, the DSL `param` docs (`dsl.ex:415-424`) and `Component.Schema` (`component/schema.ex:38-47`), do not
mention it. The `SchemaConverter.strip_markers/1` `@doc` (around `schema_converter.ex:316-325`) lists the markers as
"…plus the `additional_properties` knob", which is now incomplete: `:type_coercion` is also stripped (line 313). Add
one bullet in each place.

### S3. `session: true` (or a map) now silently means *no sessions* — VERIFIED (trace)
`streamable_http.ex:104-113,192-199` gate on `is_list(session_config)`, so `session: true`, which reads naturally as
"on", disables sessions and `require_session` without any signal. The plan note records this as "no longer crashes".
`Shared.init/2` already validates `:cors_origin` / `:allowed_origins` shapes. Validate `:session` there too: accept
`nil | false | keyword()`, and raise `ArgumentError` naming `session: []` otherwise. The same applies to SSE
`:max_connections`: a non-integer such as `"10"` makes `count_slots(t) > "10"` always false (number < binary in term
order), so the cap silently fails **open**. That is pre-existing, but it is now one line to guard in the same place.

### S4. JWKS cooldown path still logs a false "refresh failed" error, per request, once the cache exceeds `:stale_max_age` — VERIFIED (trace)
`jwks.ex` `serve_stale/4`. G6-S4 downgraded the **within**-max-age cooldown log to `:debug`
(`log_stale_serve(:cooldown, …)`). The **beyond**-max-age branch ignores `context` and always runs:

```elixir
Logger.error("JWKS refresh failed and cached keys for #{jwks_uri} exceed stale_max_age; failing closed")
```

Two consequences:
- In the cooldown branches (`fetch_on_miss/2` check 2 and `refresh_keys/1`) no refresh was attempted, so the message is
  false.
- `authenticate` runs before `rate_limit`, so each unauthenticated request carrying any JWT emits one `[error]` line
  for the whole cooldown window.

It is still an improvement on the pre-diff behaviour, which fetched and logged on every request. Pass `context` into
the failing-closed branch and log it at `:debug` (or once per cooldown) when `context == :cooldown`.

The comment above `fetch_on_miss/2` ("the lock can be taken between checks 1 and 2 … which is the outage behaviour
anyway") is also slightly off. With a *healthy* IdP, a request that lands in that window serves the TTL-expired set
instead of waiting. That is a microsecond window and harmless, but it is not outage-only. Reword it to "…serves the
previous key set, bounded by `:stale_max_age`".

### S5. `reclaim/0` comment overclaims — VERIFIED (trace)
`cancellation.ex` comment above `reclaim/0`: "so a well-behaved caller is never the one that pays". With the W11 attack
shape (every scope holding one row), all scopes tie at size 1 and eviction falls to pure age order. The oldest 1-row
scopes, which may be well-behaved callers, pay. The moduledoc wording ("the clients responsible for the pressure are the
ones that pay") has the same issue, to a lesser degree. Reword to "…a caller holding fewer rows than the largest scopes
is evicted only after them".

### S6. `EtsStore.owner_guard/1` uses `==`, while the facade re-check uses a pinned match — INFERRED
`tasks/ets_store.ex:219-220` `{:==, {:map_get, "owner", :"$1"}, {:const, owner}}` versus `tasks.ex:240-243`
`^owner -> true`. For numeric owners, `1 == 1.0` is true in the store but `^1` does not match `1.0`. The store's
`:limit` then counts rows the facade drops. Use `:"=:="` so the two layers share one equality. This only matters for a
custom `:task_owner_fun`, because `Principal.id/1` returns binaries.

### S7. Non-map `arguments` is reflected verbatim into `data.errors[].value` — VERIFIED (trace)
`validation.ex:87-93,120-126` put the raw client value (up to the body limit) into the error payload through
`format_single_error/1` (`"value" => value`). It is JSON-safe, so nothing crashes, but it reflects a large payload
unclamped. Report the type instead (`value: nil`, message "Parameters must be a map, got: list"), or clamp it with
`ConduitMcp.Reflect.text/2`, as the new `invalid_uri_error/2` does.

### S8. SSE: each rejected connect at the cap costs O(max) — INFERRED
`sse.ex` `__acquire_slot__/2` → `sweep_dead_slots/1`. At the cap with every slot alive, each `GET /sse` performs:
insert, `select_count` over up to `max` rows, `select`, `max` × `Process.alive?/1`, and a second `select_count`.
Before the diff this was one `update_counter`. With the default `max_connections: 1_000` this is microseconds, and it
is the chosen design (scratchpad: "sweep only at the cap"). It is noted only because this is an unauthenticated
endpoint when auth is off. If it matters later, skip the sweep when the previous sweep in the last second freed nothing
(an ETS timestamp row). That stays within the Iron Law: no process.

### S9. The "adjacent generated clauses resolve to the *last* one" rationale — UNVERIFIED
The rationale appears in `dsl.ex` `first_declaration_wins/1`, `endpoint.ex:103-107` and the CHANGELOG. It contradicts
Erlang's first-match clause semantics. The probe (`/private/tmp/conduit_build/dslscope_matrix.exs`) exists, but this
agent could not run it. The code is correct either way, because it de-duplicates. If the observation holds, it is an
Elixir/OTP compiler bug worth reporting upstream and citing (issue link) in the comment. If it does not hold, the three
comments and the CHANGELOG entry describe a cause that is not real. W1's option 1 (compile error on duplicates) removes
the need for the claim entirely.

---

## Checked, no issue
- `__generate_scope_clauses__/4` shortcut. When no *template* is scoped it emits only scoped static clauses plus a `nil`
  fallback. That is correct because every templated answer is `nil`, and static-only scoping keeps its exact clauses.
  Unscoped servers get three `nil` fallbacks and nothing else.
- DSL/Endpoint static-versus-templated split. `String.contains?(uri, "{")` in the scope code equals
  `SchemaBuilder.templated?/1` in dispatch, so both sides classify every URI the same way.
- Completion `ref/resource` with a template string (for example `"user://{id}"`) matches its own template regex (`{id}`
  matches `[^/]+`), so `completion_scope/2` resolves the template's scope. In `:atomize` mode the keys are compile-time
  names, so atomizing succeeds.
- `handle_cancelled/2`, `cancel_request/2` and the `handle_request/3` `@doc` list agree (3 error cases, codes -32602,
  -32602, -32000). `Protocol.server_error/0` exists (`protocol.ex:106`).
- `authorize_resource/3` gates resources/read, subscribe and unsubscribe. `validate_completion_ref/1` gates `ref.uri`.
  `invalid_uri_error/2` clamps with `Reflect.text/2`.
- `Cancellation.cleanup/1`'s `foldl`-delete comment is accurate: `ets:foldl` fixes non-ordered tables, and
  `ets:next/2` tolerates a deleted key on `ordered_set`.
- `SchemaConverter`. Recognised keys with bad values now raise "invalid value for :min …", and `type_coercion: false`
  compiles. The per-param override is inherited by object fields (`validation.ex:653-681`).
- No `RC<n>` tags and no `file.ex:NNN` line references remain in `lib/` (grep).
- Iron Laws: no new process, no `handle_call`, owners unchanged, string-keyed response maps, no `String.to_atom` (Endpoint
  uses `String.to_existing_atom` on compile-time param names only).

## Pre-existing (unchanged code, one line each)
- `handler.ex` `dispatch_callback/3`: `{:error, error}` with a non-map `error` (for example `{:error, :not_found}` from a
  user handler) evaluates `error["code"]` on an atom, which raises. It is rescued upstream and reported as -32603 instead
  of the handler's error.
- `validation.ex:163` — `@doc` for `update_validation_config/1` sits under a `# Private functions` banner (cosmetic).
- `dsl/schema_builder.ex:11` — moduledoc says "The module now generates…" (change narration in HexDocs; G3 missed it).

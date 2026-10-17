# Review: P1 hardening (`.claude/plans/hardening-p1-correctness/plan.md`)

**Date**: 2026-08-24
**Files Reviewed**: 76 (61 tracked modified, 15 new) · 5526 insertions / 1541 deletions
**Reviewers**: elixir-reviewer, security-analyzer, testing-reviewer, iron-law-judge, requirements-verifier
**Round**: 2 (a five-agent round already ran on this tree; all 13 of its findings were fixed before this one)

## Summary

| Severity | Count |
|----------|-------|
| Blockers | 2 |
| Warnings | 11 |
| Suggestions | 9 |

**Verdict**: **BLOCKED**

Two blockers, both reproduced with `mix run` by the reviewer and then
independently re-reproduced during consolidation. One is an unauthenticated
crash; the other breaks the Phoenix integration the README documents.

Note: `iron-law-judge` and the round-1 specialists die instantly on an
unavailable pinned model (`anthropic/claude-sonnet-4-0` → 404). Those roles were
re-run on generic `reviewer` agents with the same rubric. Worth fixing in the
plugin's agent definitions.

## Requirements Coverage (from plan `.claude/plans/hardening-p1-correctness/plan.md`)

Round 1's verifier scored the 36 plan items **36 MET / 0 PARTIAL / 0 UNMET**.
This round re-verified only the 13 fixes made *after* that pass:

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| 1 | `String.replace_invalid` before the `/u` regex | MET | `reflect.ex:76`; `reflect_test.exs:55,67,78`; `security_test.exs:185` |
| 2 | `{:bandit, _}` excluded from the SSE drain | MET | `sse.ex:236`; `sse_test.exs:176` asserts the queue settles at exactly 2 |
| 3 | `EtsOwner` logs-and-degrades | MET | `ets_owner.ex:53-67`; `ets_owner_test.exs:13,22,41` |
| 4 | All five Owners delegate to it | MET | five call sites, no `:ets.new` left in any Owner — but the test covers **4/5** (Warning 8) |
| 5 | `:telemetry_event` option | MET | `janitor.ex:83,98`; `application_test.exs:68` |
| 6 | `:noun` option | MET | `janitor.ex:84,101`; log-string only, not separately asserted |
| 7 | Cancellation janitor wiring | MET | `application.ex:95-107`; `application_test.exs:73-79` |
| 8 | `Code.ensure_loaded?` in the janitor | **PARTIAL** | `janitor.ex:110-112` present and correct; **no test pins it** (Warning 7) |
| 9 | `true` clause in `janitor/3` | MET | `application.ex:122`; `application_test.exs:32` |
| 10 | `raise` clause in `janitor/3` | MET | `application.ex:131-135`; `application_test.exs:55` |
| 11 | `@notification_methods` routing | MET | `handler.ex:246`; `protocol_test.exs:134` |
| 12 | `Enum.uniq_by/2` in the scope maps | MET (but see Warning 9) | `dsl.ex:1397`, `endpoint.ex:468` — present; the *justification* is false and the test is vacuous |
| 13 | `:infinity` limit | MET | `tasks/ets_store.ex:174`; `tasks_test.exs:99` |
| 14 | `Map.update!(:id, &derive_id/1)` | MET | `principal.ex:86`; `principal_test.exs:195,217,224` |

**Summary**: 13 MET · 1 PARTIAL · 0 UNMET · 0 UNCLEAR

Plan bookkeeping confirmed accurate: 46/46 checkboxes, and `plan.md:249` / `:398`
record 958 tests / 90.0% while preserving the pre-round-2 pair.

---

## Blockers (2)

### 1. `Reflect.text/2` raises on a JSON array — uncaught 500 on an unauthenticated POST

**File**: `lib/conduit_mcp/reflect.ex:86-92`
**Reviewer**: elixir-reviewer · reproduced independently during consolidation

`stringify/1`'s fallback rescues only `Protocol.UndefinedError`. But `to_string/1`
on a list raises `ArgumentError` or `UnicodeConversionError`, and JSON puts an
array wherever a scalar is expected.

`Cancellation.insert_cancellation/3` pipes the raw client `params["reason"]`
through `truncate_reason/1` → `Reflect.text(reason, 200)` (`cancellation.ex:295`),
and the notification path has **no rescue** — `handle_notification/3` is reached
from the `cond` in `handle_request/3` (`handler.ex:69-73`), outside
`do_handle_method/5`'s.

Reproduced:

```
Reflect.text([1.5])   -> ** (ArgumentError)
Reflect.text([%{}])   -> ** (ArgumentError)
Reflect.text([-1])    -> ** (UnicodeConversionError)
Reflect.text([1, 2])  -> ""          # silently converts codepoints
```

```elixir
%{"jsonrpc" => "2.0", "method" => "notifications/cancelled",
  "params" => %{"requestId" => "abc", "reason" => [1.5]}}
|> ConduitMcp.Handler.handle_request(ConduitMcp.TestServer)
# ** (ArgumentError) cannot convert the given list to a string
```

**Why this matters**: this is the *same defect class* as round 1's P0, in the
same module, on the same unauthenticated surface. Any client that can POST gets
a 500 with a stacktrace instead of a JSON-RPC reply, on both transports. The
module exists specifically to guarantee this cannot happen — its own comment at
`reflect.ex:74-78` says `to_string/1` raises "for terms with no String.Chars
implementation… exactly the shapes a hostile or buggy client sends", and then
enumerates the wrong exception. Also live at `transport/shared.ex:371-374`
(behind Logger's level check) and it downgrades `tools/call` with a non-scalar
`name` from `-32602` to `-32603` plus a spurious `[error]` log line.

**Recommended approach**:

```elixir
defp stringify(value) when is_list(value), do: inspect(value, limit: 10, printable_limit: 256)

defp stringify(value) do
  to_string(value)
rescue
  _ in [Protocol.UndefinedError, ArgumentError, UnicodeConversionError] ->
    inspect(value, limit: 10, printable_limit: 256)
end
```

The `is_list` clause must come first — `[1, 2]` currently succeeds and yields
`""`, which is worse than raising.

---

### 2. `Plug.Router.forward` no longer compiles with `:rate_limit` — the documented Phoenix integration

**File**: `lib/conduit_mcp/transport/shared.ex:247-249` (+ `plugs/rate_limit.ex:103`, `plugs/message_rate_limit.ex:120`)
**Reviewer**: elixir-reviewer · reproduced independently during consolidation

RC3 moved plug resolution into `init/1`: `resolve_plug/2` returns
`{mod, mod.init(config)}` and `Shared.init/2` puts it in the router opts.
`Plugs.RateLimit.init/1` puts a **local** function capture in that map
(`key_func: Keyword.get(opts, :key_func, &default_key_func/1)`).
`Plug.Router.forward/2` calls `target.init(opts)` at compile time and escapes
the result into `@plug_forward_opts` — a closure cannot be escaped.

Reproduced:

```elixir
forward "/mcp", to: ConduitMcp.Transport.StreamableHTTP,
  init_opts: [server_module: Srv, allowed_origins: "*",
              rate_limit: [backend: FakeBackend, limit: 5, scale: 1000]]
# ** (ArgumentError) cannot inject attribute @plug_forward_opts into function/macro
#    because cannot escape #Function<0.10520185/1 in ConduitMcp.Plugs.RateLimit.default_key_func>
```

The same mount **without** `:rate_limit` compiles. This is a regression:
`git show HEAD:lib/conduit_mcp/transport/streamable_http.ex` has no `def init` at
all, so `Plug.Builder`'s identity default applied and opts stayed plain data.

**Why this matters**: `README.md:287` documents `forward` as *the* Phoenix
integration, and `README.md:301` says "Both transports support authentication,
rate limiting, CORS". Combining the two documented features now fails to
compile — and the trigger is the *default* `key_func`, i.e. the configuration a
consumer gets by writing nothing. A user-supplied remote capture
(`&MyApp.key/1`) works, so this is invisible to anyone who overrides it.

**Recommended approach**: promote `default_key_func/1` to public in both plugs
and capture it remotely — remote captures are escapable:

```elixir
@doc false
def default_key_func(conn), do: ConduitMcp.Principal.rate_limit_key(conn)

# in init/1
key_func: Keyword.get(opts, :key_func, &__MODULE__.default_key_func/1)
```

Add a compile-time regression test that `forward`s a rate-limited transport, and
state the "callbacks must be remote captures" constraint in
`shared.ex`'s moduledoc.

---

## Warnings (11)

### 1. The global cancellation cap re-introduces the cross-tenant DoS the per-scope quota was added to prevent

**File**: `lib/conduit_mcp/cancellation.ex:146-150`
**Reviewer**: security-analyzer · verified

```elixir
cond do
  at_capacity?() -> {:error, :cancellation_limit_reached}            # global, 10_000
  scope_at_capacity?(scope) -> {:error, :cancellation_limit_reached} # per-scope, 256
  true -> insert_cancellation(scope, id, reason)
end
```

The moduledoc at `cancellation.ex:57-65` states the intent verbatim: *"a global
cap alone is a cross-tenant denial of service, because one unauthenticated
client filling the table stops every other client's cancellations from being
recorded."* The code then checks the global cap **first and unconditionally**.
The per-scope quota bounds one scope to 256 rows; nothing bounds how many scopes
one client may own.

Unauthenticated exercise against the documented `session: []` posture: open 40
sessions (cap is 100 000), then 256 `notifications/cancelled` per session =
10 240 rows > the 10 000 global cap. Every *other* client's cancellation now
fails. The 5-minute TTL closes the window, but ~10k POSTs/min sustains it, and
these ids have no in-flight request so `clear/2` never reclaims them.

**Recommendation**: check `scope_at_capacity?/1` first; when the global cap
fires, evict the oldest row from the largest scope (the table is an
`ordered_set`, so this is cheap) rather than refusing a scope that is under its
own quota.

---

### 2. SSE `:max_connections` fails **open** when the counter is unreadable

**File**: `lib/conduit_mcp/transport/sse.ex:288-295`
**Reviewer**: security-analyzer · verified

`update_active/1` rescues `ArgumentError -> 0`, and `acquire_connection_slot/1`
evaluates `if update_active(1) > max` — so `0 > 1_000` is `false` and the slot
is **granted**. Every failure mode of the counter reads as "the server is idle".

The project's own stated rule is that rate limiting fails closed when
configured; a resource cap should too. Coupled to Warning 3: once
`SSE.Owner` degrades, the table belongs to a stream process, and its exit either
resets `:active` to 0 or trips this rescue.

**Recommendation**: return a sentinel that denies (`:unavailable`) and treat it
as `false` in `acquire_connection_slot/1`. The release path has its own rescue
and is unaffected.

---

### 3. `EtsOwner.claim/3` degrades permanently — no retry, no ownership check

**File**: `lib/conduit_mcp/ets_owner.ex:56-70`
**Reviewer**: security-analyzer + elixir-reviewer (same function, two aspects)

Rescuing is right for supervisor stability, but the degrade is terminal: the
Agent idles forever, `Supervisor` reports a healthy tree, and nothing
re-attempts. The racer the moduledoc names is a request or janitor process that
exits seconds later — at which point the name is free and the Owner could have
it, but never asks. Of the five tables only `:conduit_mcp_sse_connections` turns
loss of ownership into a security bypass; the rest fail closed (sessions vanish,
tasks 404).

Second aspect: `:ets.new/2` raises `ArgumentError` for **two** unrelated reasons
and the rescue cannot tell them apart. A typo in a caller's opts
(`:naned_table`) is logged as *"the name is already taken, so the table belongs
to another process"* — actively misleading in the one module whose purpose is to
make ownership diagnosable.

**Recommendation**: `rescue e in ArgumentError -> if :ets.whereis(table) != :undefined, do: warn_and_degrade(), else: reraise(e, __STACKTRACE__)`,
plus a bounded `Process.send_after(self(), :claim, 1_000)` re-claim.

---

### 4. `validate_key_provider!/1` never checks `fetch_key/2` — the branch every real token takes

**File**: `lib/conduit_mcp/optional_deps.ex:85` · call site `lib/conduit_mcp/plugs/oauth.ex:242`
**Reviewer**: security-analyzer · verified

`ConduitMcp.OAuth.KeyProvider` declares two required callbacks
(`key_provider.ex:57,62`). The validator tests only `fetch_keys/1`, but
`fetch_signing_key/2` dispatches on `kid` — and every token from a real
JWKS-publishing authorization server carries one. A custom provider implementing
only `fetch_keys/1` passes `init/1` cleanly and raises `UndefinedFunctionError`
on the first authenticated request: precisely the failure RC1 added this module
to prevent, as its own `@doc` at `optional_deps.ex:67-69` says.

**Recommendation**: one more `cond` clause checking
`function_exported?(mod, :fetch_key, 2)`.

---

### 5. RC13 is not applied in Endpoint mode — raw URI reflected

**File**: `lib/conduit_mcp/endpoint.ex:384-398`
**Reviewer**: elixir-reviewer

Every other "Resource not found" site routes the URI through `Reflect.text/1`
(`dsl.ex:1352`, `dsl.ex:1653`, `endpoint.ex:188`, `server.ex:272`). The two
emitted by `generate_resource_clause/1` still interpolate `#{uri}` raw — and
those are the *reachable* ones in Endpoint mode (`endpoint.ex:188` is only
emitted when the endpoint declares no resources at all). A URI up to the
transports' `length: 1_000_000` parser cap is reflected verbatim, control
characters included.

**Recommendation**: wrap both in `ConduitMcp.Reflect.text/1`, and add an
Endpoint-mode case to the `security_test.exs` control-character block.

---

### 6. `validate_tool_params/3`'s public return contract changed without its `@doc`

**File**: `lib/conduit_mcp/validation.ex:33-58`
**Reviewer**: elixir-reviewer

Both public functions now propagate `{:error, :tool_not_found}` /
`{:error, :prompt_not_found}` — a bare atom where the second element was always
a list of error maps. The `@doc` still promises "`{:error, validation_errors}`
with detailed error information". `format_validation_errors/1` is guarded
`when is_list(errors)` (`validation.ex:128`), so the documented
`case ... do {:error, errs} -> format_validation_errors(errs)` now raises
`FunctionClauseError`. Silent breaking change for anyone driving validation
outside `Handler`.

**Recommendation**: document both new returns and add a `format_validation_errors/1`
clause for the atom form.

---

### 7. The `Code.ensure_loaded?` janitor fix has no regression test

**File**: `lib/conduit_mcp/session/janitor.ex:110-112`
**Reviewer**: requirements-verifier

Production change present and correct in both call sites. Nothing distinguishes
`cleanup_exported?/1` from the bare `function_exported?/3` it replaced — every
store used in tests is already loaded. Reverting `:111` leaves the suite green.
Blast radius is a janitor that idles for the life of the node while its table
grows unbounded, discovered as an OOM rather than a failure. **The only one of
the 13 round-2 fixes with no test behind it.**

**Recommendation**: purge the store module, `refute function_exported?`, start
the janitor, tick it, assert the backdated row is gone — the existing T-M7 idiom
plus two lines.

---

### 8. The Owner-ownership test covers 4 of 5 tables — the JWKS one is missing

**File**: `test/conduit_mcp/ets_owner_test.exs:57-77`
**Reviewer**: requirements-verifier

`EtsOwner`'s moduledoc names five subsystems; the "every supervised owner
actually owns its table" list contains four. `JWKS.Owner` /
`:conduit_mcp_jwks_cache` is absent — the subsystem where losing ownership is
authentication-shaped, and the one whose Owner starts conditionally
(`application.ex:152`) so its absence reads as deliberate. This is the same
defect class as round 1's SSE blocker.

**Recommendation**: add it, guarded by `Code.ensure_loaded?` so bare-consumer
builds stay green.

---

### 9. The duplicate-scope test is vacuous — and its justification comment is false

**File**: `test/conduit_mcp/oauth_scope_test.exs:338-347`; comments at `lib/conduit_mcp/dsl.ex:1395`, `lib/conduit_mcp/endpoint.ex:465`
**Reviewer**: testing-reviewer · **verified with an independent probe**

Round 1 added `Enum.uniq_by/2` to both scope maps on the premise that duplicate
generated clause heads emit a *"this clause cannot match"* warning that fails a
consumer's `--warnings-as-errors` build. **That premise is wrong.** Probe:

```
generated duplicates  -> diagnostics: []      __scope_for_tool__("dup") == "first:scope"
hand-written duplicates -> ["this clause cannot match because a previous clause at line 2"]
```

Clauses injected via `unquote` in a `__before_compile__` carry no line metadata,
so the compiler never warns — and first-declaration-wins already held without
the fix. Both of the test's assertions therefore pass with `uniq_by` deleted
from `dsl.ex:1397` **and** `endpoint.ex:468`.

The `uniq_by` calls are harmless (smaller emitted code, explicit intent) but the
comments assert an invariant that does not hold — the exact class this plan set
out to eliminate. `endpoint.ex:468` is additionally unreached by any test.

**Recommendation**: rewrite the comments to say what is true (de-duplication is
intent-explicitness, not a build fix), and assert the *generated shape* — one
`__scope_for_tool__("dup")` clause, not two — rather than a diagnostic the
compiler never emits. Add the Endpoint-mode case.

---

### 10. The `tasks/list` clamp test is satisfied by the fixture size

**File**: `test/conduit_mcp/handler_tasks_test.exs:390-403`
**Reviewer**: testing-reviewer · verified

Creates 10 tasks, requests `"limit" => 10_000`, asserts `== 10`. The server
maximum is 100, so `min(10_000, 100)` and an unclamped `10_000` both return the
same 10 rows. Replacing `tasks_list_limit/1` with the identity leaves the suite
green. The inline comment "A client asking for more than the server maximum gets
the maximum" is false — it gets 10, which is below the maximum. This clamp is
the only bound on `tasks/list` response size against a 10 000-row table.

**Recommendation**: the module is already `async: false` — snapshot/restore
`:tasks_list_max_limit`, set it to 3, create 10 tasks, assert 10_000 → 3 and a
client limit of 2 → 2.

---

### 11. The bare-consumer path guard blocks `"` and `\` but not `#{`

**File**: `.github/scripts/bare_consumer_check.sh:49`
**Reviewer**: security-analyzer · verified

The round-1 fix is otherwise complete (quoted heredoc, every expansion quoted,
`sed` escapes `& / |`). But the substitution target sits inside an **Elixir**
double-quoted string, and `#{...}` needs neither a quote nor a backslash. A
checkout at `/tmp/#{File.write!("/tmp/pwn","x")}` — a legal directory name —
produces a `mix.exs` that evaluates it on `mix deps.get`. Not presently
exploitable (`$REPO_ROOT` is CI-controlled) but the guard is the script's stated
security boundary and the comment at lines 24-26 claims a property it does not
have.

**Recommendation**: add `#` to the rejected class and to the message.

---

## Suggestions (9)

1. **`CLAUDE.md:35-36` supervision tree omits two started children** — `Transport.SSE.Owner` (`application.ex:33`, always) and `Cancellation.Janitor` (`application.ex:57`, default-on). Iron Law 3. *(iron-law-judge)*
2. **`Tasks.EtsStore` duplicates its table options** at `ets_store.ex:230` and `:252`; every sibling routes both sites through one `table_opts/0`. Iron Law 4. *(iron-law-judge)*
3. **`Reflect`'s bidi strip misses U+061C (ALM)**, plus U+2060 and U+FEFF — `reflect.ex:36`. Everything else on that surface was probed and held. *(security-analyzer)*
4. **`Principal.derive_id/1` does not namespace by struct type** — `principal.ex:125-129`. A `:verify` returning `%User{id: 42}` and `%ApiClient{id: 42}` yields `"42"` for both. Cannot collide with OAuth ids (those are claim-prefixed); the collision is within the `derive_id/1` space. *(security-analyzer)*
5. **Handler-less scoped resources contribute to the scope scan but not dispatch** — `dsl.ex:1386-1398` vs `:1576-1579`. Needs overlapping templates; fails closed but enforces the wrong scope. *(elixir-reviewer)*
6. **`handle_request/3`'s notification return is undocumented** — it can now return an error map, but the moduledoc still says notifications are "logged and dropped". *(elixir-reviewer)*
7. **`test/support/test_server.ex:86-88` still encodes the pre-RC9 `-32601`**, and it is the server behind four test files, so every request-level `resources/read` miss in the suite observes the old code. *(testing-reviewer)*
8. **The `:conduit_mcp_tasks` async invariant is already false as stated** — `handler_tasks_test.exs:6-14` says "every module that touches it MUST be `async: false`"; `security_test.exs:1` is `async: true` and reaches it. Harmless today; narrow the claim to writers. *(testing-reviewer)*
9. **`handler_tasks_test.exs:313`'s title claims a no-copy property its body does not assert** — `== []` passes against the pre-RC8 fold-and-filter too. *(requirements-verifier)*

---

## Clean surfaces (stated, not omitted)

Verified and found sound: OAuth `resolve_subject/2` namespacing (no reachable
collision), `check_alg_allowed/2` + `resolve_signer_alg/2` (no alg confusion, no
RSA-as-HMAC), `validate_claims/2` (`exp` mandatory, `nbf` typed, `iss` pinned,
`aud` list-aware, `header_safe/1` strips CR/LF/quote), `Cancellation.scope/1`
not forgeable via `mcp-session-id` (store-validated, 24 random bytes), transport
pipeline order (`OriginValidation` precedes `authenticate`; CORS off by
default), `/.well-known/oauth-protected-resource` (four allow-listed fields, no
key material). Iron Laws 1 and 2 clean across the diff. Round 1's two blockers
are fixed and neither is PERSISTENT.

---

## Summary table

| # | Finding | Severity | Reviewer | File | New? |
|---|---------|----------|----------|------|------|
| 1 | `Reflect.text/2` raises on a JSON array → uncaught 500 | BLOCKER | elixir | `reflect.ex:86` | Yes |
| 2 | `Plug.Router.forward` + `:rate_limit` fails to compile | BLOCKER | elixir | `shared.ex:247` | Yes |
| 3 | Global cancellation cap checked before per-scope quota | WARNING | security | `cancellation.ex:146` | Yes |
| 4 | SSE `:max_connections` fails open | WARNING | security | `sse.ex:288` | Yes |
| 5 | `EtsOwner.claim/3` degrades permanently, misleading log | WARNING | security+elixir | `ets_owner.ex:56` | Yes |
| 6 | `validate_key_provider!/1` skips `fetch_key/2` | WARNING | security | `optional_deps.ex:85` | Yes |
| 7 | RC13 unapplied in Endpoint mode (raw URI) | WARNING | elixir | `endpoint.ex:384` | Yes |
| 8 | `validate_tool_params/3` contract changed, `@doc` did not | WARNING | elixir | `validation.ex:33` | Yes |
| 9 | `Code.ensure_loaded?` fix untested | WARNING | requirements | `janitor.ex:110` | Yes |
| 10 | Owner-ownership test covers 4/5 tables | WARNING | requirements | `ets_owner_test.exs:57` | Yes |
| 11 | Duplicate-scope test vacuous; comment false | WARNING | testing | `oauth_scope_test.exs:338` | Yes |
| 12 | `tasks/list` clamp test satisfied by fixture size | WARNING | testing | `handler_tasks_test.exs:390` | Yes |
| 13 | Script guard misses `#{` | WARNING | security | `bare_consumer_check.sh:49` | Yes |
| 14 | `CLAUDE.md` supervision tree incomplete | SUGGESTION | iron-laws | `CLAUDE.md:35` | Yes |
| 15 | `Tasks.EtsStore` duplicate table opts | SUGGESTION | iron-laws | `tasks/ets_store.ex:252` | Yes |
| 16 | `Reflect` misses U+061C / U+2060 / U+FEFF | SUGGESTION | security | `reflect.ex:36` | Yes |
| 17 | `derive_id/1` not namespaced by struct | SUGGESTION | security | `principal.ex:125` | Yes |
| 18 | Handler-less scoped resources skew scan order | SUGGESTION | elixir | `dsl.ex:1386` | Yes |
| 19 | Notification return contract undocumented | SUGGESTION | elixir | `handler.ex:69` | Yes |
| 20 | `TestServer` stale `-32601` | SUGGESTION | testing | `test_server.ex:86` | Yes |
| 21 | Tasks async invariant already false | SUGGESTION | testing | `handler_tasks_test.exs:6` | Yes |
| 22 | No-copy test title overstates | SUGGESTION | requirements | `handler_tasks_test.exs:313` | Yes |

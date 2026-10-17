# Iron Law review — P1 hardening

**Verdict:** PASS WITH WARNINGS

## Findings

### WARNING — CLAUDE.md supervision tree omits two always-started children
`CLAUDE.md:35` · Iron Law #3 · NEW

The supervision-tree section lists the always-started children as
`Cancellation.Owner`, `Session.EtsStore.Owner`, `Session.Janitor`, and the
conditional ones as `Tasks.EtsStore.Owner` and `JWKS.Owner`. The code starts
more than that. `application.ex:33` (`always_started/0`) unconditionally starts
`ConduitMcp.Transport.SSE.Owner`, and `application.ex:57` (`cancellation_janitor/0`,
default-on) starts `ConduitMcp.Cancellation.Janitor`. Neither appears anywhere
in the doc. So the moduledoc-style architecture note asserts a supervision tree
the application does not actually run — the exact doc/code drift class this pass
set out to eliminate, and doubly so because the SSE.Owner was *added this round*
(prior round-1 fix) yet the doc that was edited in the same diff was not updated
to match.

**Why it matters:** An operator reading CLAUDE.md to reason about what runs,
what to monitor, or what to disable will not know the SSE connection-counter
owner or the cancellation janitor exist; the cancellation janitor in particular
is the only thing bounding the unauthenticated `notifications/cancelled` table
over time, and the doc gives no hint it is running or how to tune/disable it.

**Minimal fix:** Add `ConduitMcp.Transport.SSE.Owner` to the "Always" bullet and
add `ConduitMcp.Cancellation.Janitor` (default-on; disable with
`config :conduit_mcp, :cancellation_janitor, false`) alongside `Session.Janitor`.

### WARNING — Tasks table ETS options duplicated instead of centralized
`lib/conduit_mcp/tasks/ets_store.ex:252` · Iron Law #4 · NEW

`ConduitMcp.Tasks.EtsStore` writes its table options as a literal
`[:named_table, :public, :set, read_concurrency: true]` in two places:
`ensure_table/0` (`ets_store.ex:230`) and `Owner.start_link/1` (`ets_store.ex:252`).
Every sibling owner routes both call sites through one function —
`Session.EtsStore.table_opts/0` (`session/ets_store.ex:65,74` used at both
`ensure_table` and `Owner.start_link:200`), `Cancellation.table_opts/0`
(`cancellation.ex:80,326`), `SSE.connections_table_opts/0`. Tasks is the lone
holdout with two hand-maintained copies that must be edited together.

**Why it matters:** These are not cosmetic options. If a future edit adds e.g.
`write_concurrency: :auto` to one copy and not the other, the table is created
with different concurrency semantics depending on which path wins — the
supervised `Owner` at boot versus a request's `ensure_table/0` fallback in an
embedded/non-OTP context. That is a silent, environment-dependent behaviour
split, which is precisely the two-sources-of-truth hazard RC3/A-L1 removed
elsewhere.

**Minimal fix:** Add `@table_opts`/`def table_opts` to `Tasks.EtsStore` (as the
peers have) and reference it from both `ensure_table/0` and `Owner.start_link/1`.

## Law-by-law

Law 1 (never silently swallow an error): clean. All three new rescues are
either narrow or non-silent. `Handler.do_handle_method/5`'s blanket `rescue`
(`handler.ex:169-179`) logs `Exception.message`, method and request_id before
returning `-32603`, so a consumer callback bug is surfaced to the operator, not
hidden. `EtsOwner.claim/3` (`ets_owner.ex:60-70`) rescues only `ArgumentError`
from `:ets.new/2` and logs a warning. `Reflect.stringify/1` (`reflect.ex:96-99`)
rescues only `Protocol.UndefinedError` and returns an `inspect/2` rendering.
`SchemaConverter.validate_schema/1` (`schema_converter.ex:271-280`) is correctly
narrowed to `[ArgumentError, NimbleOptions.ValidationError]`. `Validation.existing_atom/1`'s
`rescue ArgumentError` (`validation.ex:256`) is the documented interned-atom
fallback. (PRE-EXISTING `validation.ex:612` — `check_custom_validator/3` still
has a bare `rescue _` that turns any exception in a consumer validator into
`"validation function error"`; not introduced by this patch.)

Law 2 (never default open): clean. `verify_scope(_conn, nil)` and the generated
`__scope_for_*__` `nil` catch-alls mean "no scope declared → public", which is
correct and matches the DSL. `owner_guard(nil)`/`Tasks.authorized?/2` deny an
owned task to a nil caller (the round-1 default-open fix holds; not persistent).
`origin_validation.ex` fails closed on unset (`:69`), unknown shapes (`:103`),
and non-`"*"` mismatches. OAuth rejects a subject-less token
(`oauth.ex:resolve_subject → :missing_subject`). `has_scope?/2`/`has_scopes?/2`
(`oauth.ex:455,463`) are consumer-facing helpers, not internal authorization;
`has_scopes?(conn, [])` returning true is standard `Enum.all?` vacuity and is
the consumer's contract, not a control this library relies on.

Law 3 (docs must not assert invariants the code lacks): one finding — the
CLAUDE.md supervision tree above. Otherwise clean: `Reflect`'s clamp/strip
moduledoc and `@doc` examples match the implementation (byte clamp →
`replace_invalid` → control-char regex covering C0/C1/DEL, U+200B–200F,
U+2028–202E, U+2066–2069 → grapheme clamp); `EtsOwner`'s "why the create is not
guarded"/"why losing the race must not raise" match `claim/3`;
`origin_validation.ex`'s DNS-rebinding discussion correctly disclaims coverage;
`Protocol`'s moduledoc now backs `server_error/0` with an actual delegate
(`protocol.ex`). Session/cancellation row-cap and TTL-sweep bullets match
`at_capacity?`/`cleanup/1`.

Law 4 (no two sources of truth): one finding — the Tasks table-opts duplication
above. Otherwise clean: `Handler.@request_methods`/`@notification_methods` are
the single table `Protocol.methods/0` delegates to; error codes route through
`ConduitMcp.Errors` everywhere (`server.ex:260`, `dsl.ex:1303/1322`,
`endpoint.ex` — the `-32602`/`-32002` literals survive only in comments);
`__validate_scope__!/2` lives once in `dsl.ex:1408` and `component.ex:225`
delegates to it; the five owners share `ConduitMcp.EtsOwner`; the transports
share `ConduitMcp.Transport.Shared`. Table-name atoms are repeated between each
module and its nested `Owner` (e.g. `:conduit_mcp_sessions` at
`session/ets_store.ex:64` and `:200`), but a nested module cannot read the outer
module attribute, so this repetition is structural and uniform across all five
owners — not a fixable second source.

## Summary
0 BLOCKER · 2 WARNING · 0 SUGGESTION

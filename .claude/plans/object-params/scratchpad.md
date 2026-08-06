# Scratchpad — object-params

## Decisions

- **No research agents spawned.** Input was an investigation report with file:line
  citations. Iron Law #7: findings ARE the research. Time went to *verifying* the report in
  this tree instead of re-discovering it — which paid off (8 additional findings, 1
  correction).
- **Fix RC1 with read-modify-write, not `accumulate: true`.** Two independent reasons:
  the source report recommended it as the 4-line mechanical change, and
  `ConduitMcp.Component.Schema` already does exactly this correctly. Registering the
  attributes as accumulating would force dropping the `[]` seeds at `dsl.ex:441/518/566`
  and auditing every reversal — larger surface, no benefit.
- **`convert_type(:object)` → `{:map, :any, :any}`, not `{:map, :string, :any}`.** Proved
  below. The report offered the latter as "stricter, also works"; in this codebase it is a
  regression.
- **Nested runtime validation: B2 chosen** (user decision, this session) — wire nested
  schemas through NimbleOptions rather than documenting non-enforcement (B1) or hand-rolling
  (B3). Lands as its own PR (phases 4+5) because it carries the `convert_keys_to_atoms/1`
  change, which is on the path for every param of every type.
- **B2's key direction is atoms, not strings.** The first draft of this plan assumed
  normalising nested object values to *string* keys. Probing NimbleOptions 1.1.1 proved that
  impossible: `{:map, :string, :any}` cannot be combined with `keys:` at all, and even the
  `keys: [*: ...]` wildcard is atom-only. So B2 must atomise.
- **Atomisation must match against declared field names only.** `String.to_atom` on
  client-supplied keys is unbounded atom creation and atoms are never GC'd — a remote
  memory-exhaustion DoS in a server library. The existing `String.to_existing_atom` +
  rescue at `validation.ex:239-243` is deliberately safe and B2 must stay at least as safe.
  Declared field names are already interned at compile time by the DSL, so matching against
  them needs no new atoms.
- **Phase 5 (`additionalProperties`) is no longer optional.** Under B2 the validator starts
  rejecting undeclared nested keys, so the published JSON Schema has to say so. Shipping
  Phase 4 alone would mean a validator whose behaviour the schema doesn't describe.

## Corrections to the source report

1. **Report path wrong.** It cites `schema_builder.ex:232` as if top-level; the file is
   `lib/conduit_mcp/dsl/schema_builder.ex` (module `ConduitMcp.DSL.SchemaBuilder`). Line
   numbers were correct.
2. **Bug 3 is non-deterministic, not universal.** Report: "every JSON-RPC call rejected".
   Actually depends on whether nested keys intern as existing atoms —
   `convert_keys_to_atoms/1` at `validation.ex:235-256` is recursive and uses
   `String.to_existing_atom` with a string fallback. An object keyed `"name"` passes today.
3. **Report's alternative fix `{:map, :string, :any}` is wrong here** — it rejects the
   common (interning) case. Measured:

   ```
   after convert_keys_to_atoms (recursive, to_existing_atom):
     interning key     -> %{bag: %{name: "v"}}
     non-interning key -> %{bag: %{"zzq_not_an_atom_9f3" => "v"}}

   :map                   -> interning=PASS    non-interning=REJECT
   {:map, :string, :any}  -> interning=REJECT  non-interning=PASS
   {:map, :any, :any}     -> interning=PASS    non-interning=PASS
   ```

4. **Bug 1's observed surface differs.** Report predicted `FunctionClauseError in
   Enum.reverse/1` for the block form; actual is `BadMapError: {:nested, [...]}`. Same root
   cause, different landing spot. Not worth chasing — the fix is identical.
5. **`build_items_schema/1` has no `nil` clause at all**, so `items: nil` is a
   `FunctionClauseError`, not the `Enum.reduce(nil, …)` the report predicted.
6. **Report scoped only `ConduitMcp.DSL`.** `ConduitMcp.Component.Schema` — the DSL every
   existing test actually uses — shares RC2, RC3, RC5 and adds RC6.

## Repro script

`/tmp/repro_dsl.exs`, run with `MIX_ENV=test mix run --no-start`. Compiles seven probe
modules via `Code.compile_string/1` inside a rescue, prints the exception per form. Also
prints the NimbleOptions type matrix. Recreate from `plan.md`'s reproduction table if
needed; it is throwaway and lives outside the repo.

`/tmp/keytype.exs` mirrors `validation.ex:235-256` verbatim and prints the key-type matrix
in correction #3.

`/tmp/nimble_nested.exs` probes NimbleOptions 1.1.1 nested-schema capability. Verbatim
output, since the whole B2 design rests on it:

```
1. type: :map + keys: [...] (atom-keyed nested schema)
  valid atom-keyed        -> OK %{name: "n", age: 3}
  missing required        -> REJECT required :name option not found, received options: [:age] (in options [:bag])
  wrong nested type       -> REJECT invalid value for :name option: expected string, got: 1 (in options [:bag])
  undeclared extra key    -> REJECT unknown options [:zzz], valid options are: [:name, :age] (in options [:bag])
  string keys             -> REJECT invalid map in :bag option: invalid value for map key: expected atom, got: "name"

2. keys: [*: ...] wildcard
  atom keys               -> OK %{a: 1}
  string keys             -> REJECT ... expected atom, got: "a"

3. {:map, :string, :any} + keys
  string-keyed map w/ keys -> SPEC-INVALID expected a keyword list, but an entry ... not a two-element tuple

4. does the dead :fields bridge shape work? [type: :map, schema: [...]]
  type: :map, schema: [...] -> SPEC-INVALID unknown options [:schema], valid options are: [:type, :required, ...]

5. deep nesting: object in object
  deep valid              -> OK %{inner: %{k: "v"}}
  deep missing required   -> REJECT required :k option not found, received options: [] (in options [:bag, :inner])

6. list of objects (array items)
  list of maps            -> OK [%{a: 1}]
```

Four things this settled:

- Nested validation works, including depth, and errors carry a key path (`[:bag, :inner]`) —
  so B3's hand-rolled path buys nothing.
- **Atom keys are mandatory.** No configuration produces nested validation on string keys.
- **The dead `{:fields, fields}` bridge is wrong, not just unwired** — it emits
  `{:schema, ...}`, and `:schema` is not a valid NimbleOptions option. Wiring it as written
  would crash schema compilation. Rewrite to `keys:` or delete.
- Undeclared nested keys are rejected by default, and for a *string* key the native message
  is `expected atom, got: "zzz"` — useless to an API consumer. Phase 4 needs its own
  unknown-field pre-check to produce a decent error.

## Dead ends / things checked and dismissed

- **Is `nested:` validated anywhere?** No. Grepped `nested` across
  `validation/schema_converter.ex` + `validation.ex`. Only hit is the unwired
  `{:fields, fields}` clause at `schema_converter.ex:158-162`, dated "for future nested
  object support". `convert_param_to_nimble_option/1` at `:74` destructures only
  `%{name:, type:, opts:}`.
- **Do handlers see mixed atom/string keys?** No. `validation.ex:220` runs
  `convert_keys_to_strings/1`, which recurses. The mixed-key window is internal to
  validation. So the handler contract is string keys and `{:map, :any, :any}` does not leak
  inconsistency outward.
- **Does any existing test cover objects?** No. Grepped `:object|field\(|nested` across
  `test/`. Every `field(...)` hit is a flat scalar inside `Component` `schema do`. The
  `mcp_apps_test.exs:381-385` "nested" hit is `stringify_keys` on a plain map, unrelated.
- **Is `ConduitMcp.DSL.items` reachable from a component module?** No — `Component`
  imports `Component.Schema`, which exports no `items`. Confirms RC6.

## Base-branch note

Branched `fix/object-params` off `master`. Independent of the seven pending `deps/*`
branches from the dependency update — disjoint file sets (`mix.lock` vs `lib/`), so no
conflict either way. Land order does not matter.

## Findings from implementation (all 5 phases, one session)

1. **`Component.Schema` DID have RC1 — at depth ≥ 2.** The plan called it the reference
   implementation. True for one level: its `:object` block clause put
   `:__component_nested_fields` to `[]` without saving the enclosing scope, and always
   pushed the finished field into `:component_fields`. So `field :bag, :object do ... field
   :inner, :object do ... end ... end` wiped the parent's siblings, leaked `inner` into the
   top-level field list, and then crashed on `Enum.reverse(nil)`. Verified against `HEAD`
   by loading the old module over the new one: `Protocol.UndefinedError`, `Enumerable not
   implemented for Atom`. Fixed with an explicit scope save/restore
   (`__open_nested_scope__/1` + `__close_nested_scope__/2`) and a single
   `__push_field__/3` choke point, which is also where RC6's bare-`field`-in-`:array`-block
   rejection lives.

2. **The arity trap is wider than the plan's two sites.** `ConduitMcp.DSL.field/4` has it
   too — and the `field/4` moduledoc's own example (`field :address, :object, "Address" do`)
   was one of the broken forms. Also fixed the 2-arg form (`param :bag, :object do ... end`),
   which otherwise *evaluates the block into the description*. An explicit `param/3`
   clause is impossible (`def param/3 conflicts with defaults from param/4`), so the 2-arg
   form is caught by a `param/4` clause matching `[{:do, _}]` in the **description**
   position.

3. **Custom-constraint markers are spec-invalid inside a NimbleOptions `keys:` schema.**
   `keys: [name: [type: :string, __min_length__: 2]]` raises
   `unknown options [:__min_length__]`. So marker stripping had to become recursive — which
   surfaced that the identical `Keyword.drop` was duplicated in **four** modules
   (`SchemaConverter`, `SchemaBuilder`, `Validation`, `Endpoint`), each reading a
   `@custom_constraint_markers` copied at compile time. All four now call the single
   `SchemaConverter.strip_markers/1`; `custom_constraint_markers/0` is gone.

4. **Nested custom constraints were unenforced too, not just nested `required`/types.**
   `validate_custom_constraints/2` only walked the top level. It now recurses into declared
   nested objects, carrying a dotted path, so `enum`/`min`/`max`/length/`validator` work at
   depth and errors read `bag.inner.zip`.

5. **`additional_properties: true` cannot be expressed in NimbleOptions at all.** Its
   `keys:` schema rejects anything undeclared and its `keys: [*: ...]` wildcard is atom-only
   (already in the probe table), so "declared fields enforced + extras allowed" is not a
   schema you can write. Implemented as prune-then-remerge: undeclared keys are dropped in
   `normalize_object/3` before validation and merged back from the original request in
   `restore_additional_properties/3`. Declared keys keep the validated value, so nested
   defaults survive. This is the only reason the original `params` are threaded that far.

6. **`additionalProperties` must always be emitted for objects.** JSON Schema's implicit
   default is *allow*, but the validator's default once fields are declared is *reject*.
   Omitting the key would have published a schema that contradicts enforcement. Defaults:
   `false` with declared fields, `true` without. And an explicit
   `additional_properties: false` on a fieldless object now takes the `keys: []` path so
   "no keys at all" is actually enforced instead of being advertised and ignored.

7. **Nested `required` errors lost the path.** NimbleOptions puts it in the message suffix
   (`(in options [:bag, :inner])`), which the existing regex parser dropped, so a nested
   failure reported a bare `city`. `qualify_with_key_path/2` folds it in.

8. **Objects inside `:array` items are not enforceable** — NimbleOptions has no spec for
   attaching `keys:` to a list element type. Left unenforced rather than hand-rolling a
   second validation path (which is what B3 was rejected for), and stated as a limitation
   in the `SchemaConverter` moduledoc, both DSL moduledocs, the README, and both guides.
   This is the one place the published JSON Schema still describes more than the server
   checks, and it is now documented rather than silent.

### Dialyzer

`normalize_params/2` and `restore_additional_properties/3` were written with defensive
non-map fallback clauses; dialyzer flagged both as unreachable (`pattern_match_cov`) because
`validate_tool_params/3` already guards `is_map(params)`. Removed — baseline was clean and
had to stay clean.

### Prompt path

Prompt `arg` defs (`dsl.ex` `arg/4`) carry **no** `:nested` key at all, and
`validation_test.exs` builds param maps by hand without one. Hence
`convert_param_to_nimble_option/1` reads it with `Map.get/2`, never a destructure.

## Review round (5 specialists, findings acted on)

`/phx:review` after the first commit (`441aac9`). Reviews in
`.claude/plans/object-params/reviews/`. Four of five agents initially died with
`404 model: claude-sonnet-4-0` — those agent definitions pin an unavailable model; re-spawned
on `reviewer`/`task`. Worth knowing before the next review in this repo.

**Verdict on the plan's hard constraint:** atom-table exhaustion **UPHELD**. `lib/` has
exactly three atom-producing calls, all `String.to_existing_atom` with a rescue; nested keys
resolve only through `Map.fetch/2` against a compile-time name map. `String.to_atom`: zero hits.

Six defects found and fixed. Every one was reproduced first — none was taken on the
reviewer's word:

1. **Client-forgeable validation errors.** `qualify_with_key_path/2` matched
   `(in options [...])` anywhere and took the *first* hit, but NimbleOptions appends the real
   key path *last* and embeds the offending value via `inspect/1`. Sending
   `"required :password option not found (in options [:admin, :secrets])"` as a value produced
   `%{"parameter" => "admin.secrets.password", "message" => "is required"}` and suppressed the
   real error. Anchored every parser to the message's own structure (reason = prefix, path =
   suffix) and deleted `parse_invalid_value_error/2` and `parse_type_error/2`, whose regexes
   could never match genuine NimbleOptions output and therefore fired *only* on injected text.
   Re-added an anchored `^invalid value for :(\w+) option: ` parser, which also gave type
   errors a `parameter` for the first time.
2. **RC6 one level down.** `__push_field__/3` tested the nested scope before the array scope,
   so the bare-`field`-in-`:array`-block guard only fired at depth 0. An `:array` block inside
   an `:object` block silently published the item field as a property of the parent. Fixed by
   *hiding* the enclosing scope for the duration of an array block.
3. **Nested type coercion missing.** Every other new pass recursed through `keys:`;
   `apply_type_coercion/2` did not. `%{"age" => "30"}` was accepted at the top level and the
   identical nested payload rejected — while the docs I had just written promised enforcement
   "to any depth" plus coercion by default.
4. **`min:`/`max:`/`validator:` failed open** — and fixing (3) is what exposed it. Constraints
   are checked by this library, and the check ran *before* coercion: `check_min_value/3` skips a
   binary, coercion then makes it a number, and the markers are already stripped from the
   schema NimbleOptions sees. `"5"` passed `min: 18`. `validator:` was worse — the user's
   function received the raw binary, and `"5" > 18` is `true` in Erlang term order. Coercion
   now runs first. The top-level instance was pre-existing; the nested one I introduced in (3).
5. **Keyword list in the description position.** `param :bag, :object, required: true do ... end`
   is arity 4 with `[required: true]` in the *description* slot. The new block-routing clause
   hard-coded `opts: []`, so the opts were dropped *and* the keyword list landed in
   `"description"` — which is not JSON-encodable, so `tools/list` failed for the whole server.
   `split_description_opts/1` now classifies it: a description is a string, so a keyword list
   here is unambiguously opts.
6. **Two silent `items` misuses.** A second `items` in one block overwrote the first, and an
   `items` nested inside `items :object` was overwritten when the outer block closed. Both were
   accepted and discarded. The guard is now "array open *and* no field scope open", plus a
   duplicate check.

Also fixed, all reviewer-flagged: the three **DSL** counterparts of RC6 (a bare `field` in an
`:array` block, an `items` outside one, and a `field` outside any object block were all
silently swallowed; `items :string do ... end` raised a bare `FunctionClauseError`) — the DSL
is the *primary* front end and had none of the guards `Component.Schema` got. Top-level
undeclared parameters now produce a structured error instead of `parameter: nil` plus, for a
non-interning name, an `ArgumentError` out of `NimbleOptions.validate/2` — the same
atom-table-luck non-determinism as RC3, one level up. `to_string/1` on an exotic unknown key.
`strip_markers/1`'s catch-all narrowed to `nil` so a malformed schema fails loudly on the
runtime path. `validate_schema/1`'s bare rescue narrowed to the classes NimbleOptions actually
raises. The `items` docstrings — the docs a developer actually reads — now carry the
array-item non-enforcement caveat.

**The duplication was the root cause, so it is now gone.** Both front ends solved the same
nesting problem with divergent copies, and both bugs (2) and the depth->=2 corruption lived in
the divergence. `ConduitMcp.DSL.FieldScope` is the single implementation of open/hide/close/
restore/prepend; each DSL keeps only its own choke point, because the targets and error
wording differ. `nil` vs `[]` is discriminated by clause, never by `if` — `[]` is truthy.

### Deliberately not done

- **Deprecated `custom_constraint_markers/0` delegate.** A reviewer wanted one kept for a
  minor. Declined: clean cutover, no shims. It is recorded under `### Removed` in the
  CHANGELOG naming `strip_markers/1` as the replacement, which is the honest treatment for a
  0.9.x public function whose only purpose was to let callers hand-roll the stripping that
  `strip_markers/1` now does for them.
- **Precomputing `declared_names/1` into a `__declared__` schema marker.** A real per-request
  allocation (one map plus one binary per declared field, per object, twice per strict object).
  Declined for now: it denormalises information already in `keys:`, so the two can drift, and
  the win is unmeasured. If nested-object validation ever shows up in a profile, this is the
  first thing to do — along with `join_path/2`, which allocates a binary per present field per
  level on the *success* path.
- **DSL nested array-of-objects capability.** `field :rows, :array do ... end` inside a DSL
  object param raises a clear `CompileError` rather than working. That is a missing feature,
  not a bug, and the error is honest. `Component.Schema` supports it.

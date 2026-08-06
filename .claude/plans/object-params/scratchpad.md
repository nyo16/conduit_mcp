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

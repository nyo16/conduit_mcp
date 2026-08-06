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
- **Nested runtime validation is a separate decision, not part of the unblock.** Wiring it
  requires changing `convert_keys_to_atoms/1`, whose blast radius exceeds objects.

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

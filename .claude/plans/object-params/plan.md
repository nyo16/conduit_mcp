# Plan: Make object parameters functional

**Status:** IMPLEMENTED — all 5 phases complete, gate green. Not yet committed.
**Branch:** `fix/object-params` (off `master`)
**Slug:** `object-params`
**Source:** downstream investigation report (conduit_mcp 0.9.7 consumer) + first-party
verification in this tree
**Depth:** standard (findings supplied; verification done inline, no research agents spawned
per Iron Law #7)
**Decisions taken:** nested runtime validation = **B2** (wire through NimbleOptions);
`additionalProperties` promoted from optional to required by that choice. Ships as two PRs —
phases 1–3, then phases 4–5. Both were implemented in one session; split at commit time.

## Problem

Object parameters are dead code that has never been exercised. Every declaration form
crashes at compile time, and the one shape that compiles is rejected at runtime by the
validator. This affects **both** DSLs — `ConduitMcp.DSL` (`tool ... param`) and
`ConduitMcp.Component.Schema` (`schema ... field`).

Zero tests in the suite declare an `:object` param or a nested `field` inside a
`param`/`field` block. Confirmed by grep across `test/`.

## Verified reproductions

Run in this tree at `master` via `mix run --no-start` (script: `scratchpad.md`).
All seven forms fail:

| # | Form | Observed failure | In report? |
|---|---|---|---|
| A | `param(:bag, :object, "d")` | `Protocol.UndefinedError` — Enumerable not implemented for Atom | yes |
| B | `param :bag, :object, "d", [] do field(...) end` | `BadMapError: {:nested, [...]}` | yes (as `Enum.reverse/1` FunctionClauseError) |
| C | `param :bag, :object, "d" do ... end` (3-arg + block) | `Protocol.UndefinedError` | yes (minor) |
| D | `param :rows, :array, "d", [] do items :object do ... end end` | `BadMapError: {:nested, nil}` | **no** |
| E | `field(:bag, :object, "d")` in `schema do` | `Protocol.UndefinedError` | **no** |
| F | `field :bag, :object, "d" do ... end` in `schema do` | `Protocol.UndefinedError` | **no** |
| G | `field :rows, :array, "d" do ... end` in `schema do` | `FunctionClauseError` in `build_items_schema/1` | **no** |

## Root causes

### RC1 — `ConduitMcp.DSL` accumulator attributes never registered as accumulating

`dsl.ex:69-71` registers `:mcp_tools`, `:mcp_prompts`, `:mcp_resources` with
`accumulate: true`. It never registers `:mcp_current_tool_params` or
`:mcp_current_nested_params`. The blockless `param/4` clause compensates with an explicit
read-modify-write (`dsl.ex:431-432`), but four sites write `@attr value` as if the
attribute accumulated, replacing the whole list with a bare map:

| Site | Macro | Effect |
|---|---|---|
| `dsl.ex:454` | block-form `:object` param | discards every param declared before it |
| `dsl.ex:475` | block-form `:array` param | same |
| `dsl.ex:508` | `field/4` | each nested field discards the previous one and the `[]` seed |
| `dsl.ex:538` | nested `:object` `field/5` | same |

`items/2`'s `:object` clause (`dsl.ex:564-577`) seeds `@mcp_current_nested_params []` at
`:566` and reverses at `:572`, so it inherits the same corruption — this is case **D**,
and it is a fifth affected form the report did not list.

**`ConduitMcp.Component.Schema` does not have this bug.** It uses read-modify-write at
every site (`schema.ex:99-100`, `:121-122`, `:141-146`) and dispatches on nesting context
with `Module.has_attribute?(__MODULE__, :__component_nested_fields)` (`:140`). It is the
reference implementation; the fix should mirror it rather than invent a pattern.

### RC2 — `nested: nil` / `items: nil` reach the schema builder

`schema_builder.ex:232` destructures `%{type: :object, nested: nested_params}` and passes
it straight to `build_properties_and_required/1`, which is `Enum.reduce(params, ...)` at
`:214`. Any blockless object gives `nested: nil` → `Enum.reduce(nil, ...)` → crash
(cases **A**, **E**).

`build_items_schema/1` (`:271`, `:286`) has clauses for `%{type: :object, nested: ...}` and
`%{type: type}` but **no clause for `nil`** — so `items: nil` raises `FunctionClauseError`
rather than the `Enum.reduce` error the report predicted (case **G**).

### RC3 — `:object` maps to a NimbleOptions type that cannot accept JSON-RPC keys

`schema_converter.ex:86`: `defp convert_type(:object), do: :map`. NimbleOptions `:map` is
shorthand for `{:map, :atom, :any}`.

**The report's analysis of this is incomplete, and its suggested alternative fix is wrong
for this codebase.** `validation.ex:235-256`'s `convert_keys_to_atoms/1` is **recursive**
(`:248`) and uses `String.to_existing_atom` with a string fallback (`:239-243`). So a
nested object's key type depends on whether that atom happens to already be interned in
the VM. Measured:

| Nested key | After `convert_keys_to_atoms/1` |
|---|---|
| `"name"` (interns) | `%{bag: %{name: "v"}}` — **atom** |
| `"zzq_not_an_atom_9f3"` (does not intern) | `%{bag: %{"zzq_not_an_atom_9f3" => "v"}}` — **string** |

Against that input:

| `convert_type(:object)` | interning key | non-interning key |
|---|---|---|
| `:map` (current) | PASS | REJECT |
| `{:map, :string, :any}` (report's "stricter" alternative) | **REJECT** | PASS |
| `{:map, :any, :any}` | PASS | PASS |

Two consequences:

1. The bug is **non-deterministic**, not "every call rejected". An object whose keys all
   happen to intern passes today. That makes it flaky rather than uniformly dead, and it
   means a naive fix can look correct in a test that uses `"name"`.
2. `{:map, :any, :any}` is the **only** safe choice. `{:map, :string, :any}` would reject
   the common case and is a regression.

Handlers are unaffected by the mixed keys: `validation.ex:220` runs
`convert_keys_to_strings/1`, which recurses, so the handler contract stays string-keyed.

### RC4 — nested fields are never validated at runtime

`convert_param_to_nimble_option/1` (`schema_converter.ex:74`) destructures only
`%{name:, type:, opts:}` — it **ignores the `nested:` key entirely**. There is a
`convert_validation_opt({:fields, fields}, acc)` clause at `:158-162`, commented "for
future nested object support", that would build `{:schema, nested_schema}` — but nothing
ever writes `opts[:fields]`; the DSL puts nested fields under the param map's `nested:`
key. It is an unwired bridge.

So after RC1–RC3 are fixed, a declared object validates as "is a map" and nothing more,
while the generated JSON Schema advertises nested `required` fields to the client. The
moduledoc at `schema_converter.ex:18` claims `:object -> :map (with nested validation)`,
which is false.

This is a design fork, not a bug fix — see Phase 4 and the open decision.

### RC5 — arity trap on 3-arg + block

`param :bag, :object, "desc" do ... end` binds to the **blockless** `param/4` clause with
`opts: [do: {...}]`, because `[do: ...]` satisfies `when is_list(opts)` (`dsl.ex:420`).
The user then hits RC2's crash with nothing pointing at their source. The block clause
engages only when `opts` is passed explicitly — as the moduledoc example at `dsl.ex:97`
happens to do.

`Component.Schema` has the identical trap: `field(name, type, description, opts \\ [],
do_block \\ nil)` (`schema.ex:82`), so 3-arg + block lands on the `field(name, type,
description, opts, nil)` clause at `:128` with `opts: [do: ...]` (cases **F**, **G**).

### RC6 — `Component.Schema` `:array` block form has no `items` macro

`schema.ex:106-126` handles `field :x, :array, "d", opts do ... end` by seeding
`:__component_array_items` and running the block — but `Component.Schema` exports no
`items` macro, and `ConduitMcp.DSL.items/1,2` is not imported into component modules. So
the block can only contain `field` calls, which (because `:__component_nested_fields` is
absent) accumulate into `:component_fields` and **silently corrupt the parent field list**.
There is no way to declare array item types in the component DSL at all.

## Phases

Phase 1 is the unblock and is self-contained. Phases 2–3 close the forms the report
missed. Phase 4 is the design fork. Phase 5 is optional scope.

### Phase 1 — Make object params compile and validate `[dsl]` `[schema]` `[validation]`

- [x] Add regression tests for cases **A**–**G** first, as compile-time assertions
      (`Code.compile_string/1` inside `assert_raise`-style helpers won't work post-fix —
      assert on the *generated schema* instead). Cover: blockless object, block object with
      a param declared before it, 3-arg + block, `items :object`, and both component forms.
      These must fail before the fix. — `test/conduit_mcp/object_params_test.exs`, 29 tests.
      Confirmed failing pre-fix: `FunctionClauseError` in `Enum.reverse/1` at compile time.
- [x] `dsl.ex:454` — replace `@mcp_current_tool_params param_def` with the read-modify-write
      from `:431-432`.
- [x] `dsl.ex:475` — same.
- [x] `dsl.ex:508` — replace `@mcp_current_nested_params field_def` with read-modify-write.
- [x] `dsl.ex:538` — same.
- [x] Confirm the `[]` seeds at `dsl.ex:441`, `:518`, `:566` remain correct under
      read-modify-write (they do — do **not** switch to `accumulate: true`, which would
      require dropping the seeds and changing reversal order; the report and the existing
      `Component.Schema` implementation both favour read-modify-write). — seeds unchanged.
- [x] `schema_builder.ex:232` — default `nested_params` to `[]`. Yields
      `{"type":"object","properties":{}}` for an open object, which is correct JSON Schema.
- [x] `schema_builder.ex` — add a `build_items_schema(nil)` clause returning an
      unconstrained item schema; keep `%{type: :object, nested: nil}` safe via the same
      `|| []` default at `:271`. — `build_items_schema(nil), do: %{}` (JSON Schema "any").
- [x] `schema_converter.ex:86` — `defp convert_type(:object), do: {:map, :any, :any}`.
      **Not** `{:map, :string, :any}` — see RC3.
- [x] Add a validation test that exercises a nested object with a **non-interning** key
      (e.g. `"zzq_not_an_atom_9f3"`) *and* an interning key (`"name"`) in the same payload,
      so the RC3 regression can't hide behind atom-table luck.
- [x] Verify: `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix test`
      — green, 660 tests.

### Phase 2 — Close the arity trap in both DSLs `[dsl]`

- [x] `dsl.ex:420` — add a guard or an explicit `param(name, type, description, [do: _])`
      clause that raises a `CompileError` naming the file/line and telling the user to pass
      `opts` explicitly (`param :bag, :object, "d", [] do ... end`) or use the 4-arg form.
      — made it **work** instead (see below); also covers `param :bag, :object do ... end`
      and the DSL's own nested `field/3 + block`, which the moduledoc documents.
- [x] `schema.ex:128` — same for `Component.Schema.field/5`.
- [x] Decide and document whether 3-arg + block should instead be made to **work** rather
      than raise. Making it work is friendlier and is what users will try first; it needs
      the `[do: _]`-detecting clause to forward to the block implementation with `opts: []`.
      Recommendation: make it work, and keep a raise only for genuinely ambiguous input.
      — **Decided: make it work.** Block bodies moved into shared `build_block_param/6` and
      `build_block_field/6` helpers; the `[do: _]`-detecting clauses forward with `opts: []`.
      A block on a type that has no block form raises a `CompileError` carrying
      `__CALLER__`'s file/line.
- [x] Add tests asserting the chosen behaviour for both DSLs.
- [x] Verify (same gate as Phase 1).

### Phase 3 — `Component.Schema` array items `[schema]`

- [x] Add an `items/1` and `items/2` macro to `ConduitMcp.Component.Schema` mirroring
      `ConduitMcp.DSL.items/1,2`, or import the DSL's. — added natively (the DSL's write to
      `@mcp_current_*` attributes the component path does not use). `items` outside an
      `:array` block is now a `CompileError` instead of silently leaking into the next array.
- [x] Make `field :x, :array, ... do ... end` reject a block containing bare `field` calls
      instead of silently leaking them into `:component_fields` (RC6). — enforced in the new
      single `__push_field__/3` choke point.
- [x] Tests for `field :rows, :array, "d", [] do items :object do field ... end end`.
- [x] **NEW (not in the original plan)** — `Component.Schema`'s `:object` block clause never
      saved/restored the parent nested scope, so an object nested inside an object wiped its
      parent's fields and then crashed on `Enum.reverse(nil)`. Verified against `HEAD`:
      `Protocol.UndefinedError` / `Enumerable not implemented for Atom`. Fixed with
      `__open_nested_scope__/1` + `__close_nested_scope__/2`. The plan's claim that
      `Component.Schema` "does not have this bug" held only at depth 1.
- [x] Verify. — green, 677 tests.

### Phase 4 — Nested runtime validation via NimbleOptions (decision: **B2**) `[validation]`

NimbleOptions capability verified against the locked 1.1.1 (probe in `scratchpad.md`).
What works and what constrains the design:

| Probe | Result |
|---|---|
| `type: :map, keys: [name: [type: :string, required: true]]` w/ atom keys | **OK** |
| ...missing required nested key | rejected: `required :name option not found` |
| ...wrong nested type | rejected: `expected string, got: 1` |
| ...undeclared nested key | rejected: `unknown options [:zzz]` |
| ...**string** keys | rejected: `expected atom, got: "name"` |
| `keys: [*: [type: :any]]` wildcard w/ string keys | **rejected** — wildcard is still atom-only |
| `{:map, :string, :any}` **+** `keys:` | **spec-invalid** — cannot combine |
| deep nesting (object in object) | **OK**, errors carry a path: `in options [:bag, :inner]` |

Two hard consequences:

1. **There is no way to get NimbleOptions nested validation on string-keyed maps.** So B2
   necessarily requires atomising nested object keys before validation. Normalising to
   *string* keys — what the Phase 4 sketch in the previous draft assumed — is a dead end.
2. **The dead `{:fields, fields}` bridge is not merely unwired, it is wrong.** It emits
   `{:schema, nested_schema}`, and `:schema` is not a valid NimbleOptions option
   (`unknown options [:schema], valid options are: [:type, :required, ...]`). Wiring it as
   written would crash schema compilation. It must be rewritten to `keys:` or deleted.

**Security constraint — do not lose this property.** `String.to_atom` on client-supplied
keys is unbounded atom creation, and atoms are never garbage-collected. That is a
memory-exhaustion DoS on a server library. The existing `String.to_existing_atom` +
rescue at `validation.ex:239-243` is deliberately safe; B2 must stay at least as safe.
The way to have both: atomise a nested key **only when it matches a declared field name**.
Those atoms already exist, created at compile time by the DSL. Undeclared keys are never
atomised.

Design that follows from the above:

- Object **with** declared nested fields → `type: :map, keys: [<declared specs>]`, with
  schema-driven key normalisation.
- Object **without** declared fields (open bag) → keep Phase 1's `{:map, :any, :any}`,
  no `keys:`, pass-through.

Tasks:

- [x] Add a schema-driven nested-key normaliser: given a param's `nested:` field list,
      atomise only those incoming keys whose string form matches a declared field name;
      leave every other key as a string. Never call `String.to_atom` on client input.
      — `Validation.normalize_params/2` + `normalize_object/3`. Drives off the generated
      `keys:` schema rather than the raw `nested:` list, so both DSL front ends and any
      hand-written schema get it for free.
- [x] Replace the blanket recursion in `convert_keys_to_atoms/1` (`validation.ex:248`) for
      object-typed params with that schema-driven pass. Note this blanket recursion is the
      root of RC3's non-determinism, so removing it is a fix, not collateral.
      — `convert_keys_to_atoms/1` deleted. Top-level keys keep the historical
      `String.to_existing_atom`-with-string-fallback; only objects carrying a `keys:`
      schema are descended into.
- [x] **Audit blast radius:** `convert_keys_to_atoms/1` runs on every param of every type.
      Run the full suite and specifically re-check any test that relies on nested values
      being atomised (grep `convert_keys_to_atoms` consumers and the prompt path too —
      `compile_validation_schema(%{args: args})` at `schema_converter.ex:67` shares it).
      — No consumers left; no test relied on nested atomisation (grepped `test/`). Prompt
      `arg` defs carry **no** `:nested` key at all, so `convert_param_to_nimble_option/1`
      reads it with `Map.get/2`; the same applies to the hand-written param maps in
      `validation_test.exs`. Full suite green (706), dialyzer clean.
- [x] `convert_param_to_nimble_option/1` (`schema_converter.ex:74`) — destructure `nested:`
      and emit `type: :map, keys: [...]` for objects with declared fields. It currently
      ignores `nested:` entirely (RC4). — new `type_opts/2`.
- [x] Recurse for depth: nested objects inside nested objects must emit nested `keys:`.
      Verified supported, with path-carrying errors. — falls out of
      `dsl_params_to_nimble_options/1` recursing into itself.
- [x] Delete or rewrite the broken `convert_validation_opt({:fields, fields}, acc)` bridge
      at `schema_converter.ex:158-162`. Do not leave it emitting an invalid `:schema` key.
      — deleted; `nested:` is the real bridge.
- [x] Decide the undeclared-nested-key policy and make the error message good. NimbleOptions'
      native rejection for a *string* undeclared key is `expected atom, got: "zzz"`, which is
      useless to an API consumer — pre-check undeclared keys and emit a proper
      "unknown field `zzz` in object `bag`" error instead. — `unknown_key_errors/4`, run
      before NimbleOptions sees the params. Reports `parameter: "bag.zzq"`, message
      `unknown field "zzq" in object "bag"`.
- [x] Fix `schema_converter.ex:18` — the moduledoc claim `:object -> :map (with nested
      validation)` becomes true only once this phase lands; until then it is false.
      — rewritten, plus a `## Nested Objects` section stating the enforcement boundary.
- [x] Confirm the handler-facing contract is unchanged: `validation.ex:220`'s
      `convert_keys_to_strings/1` recurses, so handlers keep receiving string keys.
      Add a test asserting that explicitly — it is the property that makes atomisation an
      internal detail. — asserted end to end through `ConduitMcp.Handler.handle_request/2`.
- [x] Tests: missing nested required; wrong nested type; undeclared nested key; deep
      nesting; object inside array items; open bag still accepts anything; and **both** DSL
      front ends (`param` and `Component.Schema` `field`).
      — `test/conduit_mcp/nested_object_validation_test.exs`, 29 tests.
- [x] **NEW** — nested *custom* constraints (`enum`, `min`/`max`, length limits,
      `validator`) were also unenforced, and the markers are spec-invalid inside a
      NimbleOptions `keys:` schema (`unknown options [:__min_length__]`). So
      `strip_markers/1` now recurses into `keys:` and `validate_custom_constraints/2`
      recurses into declared nested objects, with dotted error paths
      (`bag.inner.zip`). Marker stripping was duplicated in four modules; all four now
      call the single `SchemaConverter.strip_markers/1`.
- [x] **NEW** — nested `required` errors from NimbleOptions reported a bare field name
      (`city`) because the key path lives in the message's `(in options [:bag, :inner])`
      suffix. `qualify_with_key_path/2` folds it into the parameter name.
- [x] **DOCUMENTED LIMITATION** — objects inside `:array` items are **not** enforced:
      NimbleOptions cannot attach a `keys:` schema to a list element type (no spec exists).
      Item schemas are still published for clients. Stated in the `SchemaConverter`
      moduledoc, both DSL moduledocs, the README, and both guides.
- [x] Verify (same gate as Phase 1). — green.

### Phase 5 — `additionalProperties`, merged into Phase 4 `[schema]`

**Now coupled to Phase 4, not optional.** Once Phase 4 rejects undeclared nested keys,
`additionalProperties` stops being cosmetic: it becomes the knob that selects between
strict rejection and pass-through, and the JSON Schema must agree with what the validator
actually enforces. Shipping Phase 4 without it means the schema says nothing while the
validator rejects.

- [x] Honour `opts[:additional_properties]` in `schema_builder.ex` `build_property/1` for
      `:object`, emitting `"additionalProperties"` in the JSON Schema. — **always** emitted
      for objects, defaulting to `false` when fields are declared and `true` when they are
      not. Omitting it would have meant JSON Schema's implicit `true` contradicting the
      validator's rejection.
- [x] Make the same opt drive the validator: `additional_properties: true` → allow
      undeclared keys (open bag semantics even when fields are declared);
      `false`/absent → reject. — declared fields stay enforced under `true`: undeclared
      keys are pruned before NimbleOptions (its `keys:` schema rejects anything undeclared,
      and its `keys: [*: ...]` wildcard is atom-only) and merged back from the original
      request by `restore_additional_properties/3`. Nested defaults survive the merge.
- [x] Reconcile with the open-bag case: an object with no declared fields and no opt should
      keep behaving as `{:map, :any, :any}`. — it does. An explicit
      `additional_properties: false` on a fieldless object now means "no keys at all" and
      takes the `keys: []` path, so the schema's `"additionalProperties": false` is
      enforced rather than being a lie.
- [x] Tests for `additional_properties: true | false` against both the emitted JSON Schema
      and runtime validation, asserting the two agree.
- [x] Verify. — green: 706 tests, credo --strict clean, dialyzer clean,
      `mix format --check-formatted` clean. Documented snippets smoke-tested end to end
      through `ConduitMcp.Handler`.

## Resolved decision — nested runtime validation

**Chosen: B2 — wire nested schemas through NimbleOptions.** (User decision, this session.)

Rejected alternatives, recorded so the next reader doesn't relitigate:

- **B1 — document, don't enforce.** Smallest change, but leaves the server advertising
  nested `required` constraints it never checks.
- **B3 — hand-roll nested validation** against the `nested:` tree. Most control, but adds a
  second validation path to keep in sync with the JSON Schema builder. NimbleOptions turns
  out to support everything needed (including depth and error paths), so the extra path
  isn't justified.

B2's cost is now known rather than assumed: it requires schema-driven key atomisation
(string keys are impossible — see the Phase 4 probe table) and it touches
`convert_keys_to_atoms/1`, which every param type flows through. That blast radius has its
own audit task.

## Split decision — OVERRIDDEN

**Shipped as one branch, one PR** (`fix/object-params`). User decision at implementation
time, superseding the two-PR plan below.

Consequences of the override, so nothing is silently lost:

- The `convert_keys_to_atoms/1` change no longer has its own revert unit. It is the one
  subtractive change on a path every param of every type flows through, so it is the thing
  to look at first if a regression appears. Its audit task is done (see Phase 4).
- The intermediate-release behavioural break disappears, which is the good news: phases 1–3
  alone would have accepted objects with undeclared nested keys, and phases 4–5 reject them.
  Shipping together means no version ever exhibited the permissive behaviour, so there is no
  break to note for adopters. See the Risks entry on rejection behaviour.
- Version bump: minor, not patch — nested validation rejects input that a hypothetical
  phases-1–3-only release would have accepted, and `additionalProperties` is new API.

Original plan, kept for the record:

- **PR 1 — phases 1–3, "object params work".** Same class of defect, same two front-end
  files, one round of tests. This is the unblock and it is independently shippable.
- **PR 2 — phases 4+5, "nested object validation".** Now that B2 is chosen, these are one
  unit: Phase 4 makes the validator reject undeclared nested keys, and Phase 5 is the knob
  that makes the published JSON Schema agree with it. Splitting them ships a validator whose
  behaviour the schema doesn't describe. This PR also carries the
  `convert_keys_to_atoms/1` change, so it wants its own review and its own revert unit.

## Risks

- **The fix is mechanical but the feature is unproven.** Nothing has ever exercised this
  path, so the tests written in Phase 1 define the contract for the first time. Expect the
  generated JSON Schema shape to need a judgement call (e.g. whether an open object emits
  `"properties": {}` or omits the key).
- **`{:map, :any, :any}` is permissive by design.** It accepts any map. Correct given RC3,
  but a typo'd nested key reaches the handler silently until Phase 4 lands. State it in the
  release notes for whatever version ships PR 1 alone.
  — **RESOLVED by the single-PR override.** No release ever ships Phase 1 without Phase 4,
  so the permissive window never exists publicly. `{:map, :any, :any}` remains the type for
  objects that declare no fields, where accepting anything is the intended contract.
- **Two DSLs, one schema pipeline.** `ConduitMcp.DSL` and `ConduitMcp.Component.Schema`
  both feed `SchemaBuilder` and `SchemaConverter`. Every fix in the shared pipeline must be
  tested from *both* front ends or the component path will drift again — it already has
  (RC6).
- **B2's blast radius is the real risk in this plan.** `convert_keys_to_atoms/1` is on the
  path for every param of every type, tools and prompts alike
  (`compile_validation_schema(%{args: args})`, `schema_converter.ex:67`). Changing its
  recursion to be schema-driven is the right fix for RC3's non-determinism, but it is the
  one change here that can break params that work today. Hence the explicit audit task.
- **Atom-table safety is a hard constraint, not a preference.** If Phase 4 is implemented
  with `String.to_atom` instead of match-against-declared-names, it introduces a
  remote memory-exhaustion DoS in a server library. Any review of PR 2 should check this
  specifically.
  — **Honoured.** `String.to_atom` appears nowhere in the change. Nested keys are atomised
  only via `Map.fetch/2` against a compile-time-declared-name map
  (`Validation.declared_names/1` + `declared_key/3`); the top-level pass keeps the existing
  `String.to_existing_atom` + rescue. Grep `String.to_atom` in `lib/` to confirm — still
  zero hits. **This is the single most important thing for a reviewer to re-verify.**
- **Phase 4 changes rejection behaviour for input that is accepted today.** After PR 1, an
  object with undeclared keys validates; after PR 2 it may not. That is a behavioural
  break for anyone who adopted objects between the two releases — narrow, but real. Either
  ship both in one version or note it.
  — **RESOLVED: shipped in one version.** No adopter can be caught in the gap.
- **Version/compat.** Public library at 0.9.7. Phase 2's arity-trap change only affects
  code that currently crashes, so it is not breaking. Phase 5 adds opts.
  — With the single-PR override this is **one minor bump**: nested validation and
  `additional_properties` are new behaviour, and no previously-working declaration form
  changes meaning (every object form crashed or was rejected before).

## Self-check

- *Does the plan cover every finding in the source report?* Yes — see the completeness
  matrix below, plus 8 findings the report did not have.
- *Is anything in the plan unverified?* Every file:line, every failure mode, and every
  NimbleOptions capability claim was reproduced in this tree — including the two facts that
  changed the design (string-keyed nested validation is impossible; the `:fields` bridge
  emits an invalid option). What remains unverified is the *implementation* of the
  schema-driven normaliser in Phase 4, which does not exist yet.
- *What would make this plan wrong?* If the intended contract for `:object` is "atom-keyed
  map" rather than "JSON object", then RC3's fix is wrong and the real fix is in
  `convert_keys_to_atoms/1`. The handler-facing contract (`convert_keys_to_strings/1` at
  `validation.ex:220`) says string keys, so JSON object is the right reading — but a
  maintainer should confirm before PR 2.
- *What is the riskiest task?* Replacing the blanket recursion in `convert_keys_to_atoms/1`.
  Everything else is additive or local; that one is subtractive on a shared path.

## Completeness matrix

Every finding from the source report, plus first-party additions. No finding is dropped.

| Source finding | Where addressed |
|---|---|
| Bug 1 — accumulators never registered (`dsl.ex:69-71` + 4 write sites) | Phase 1 (RC1) |
| Bug 2 — `nested: nil` reaches schema builder (`schema_builder.ex:232`) | Phase 1 (RC2) |
| Bug 2b — same latent nil in `build_items_schema/1` (`:271`) | Phase 1 (RC2) |
| Bug 3 — `:object` → `:map` (`schema_converter.ex:86`) | Phase 1 (RC3) |
| Minor — arity trap on 3-arg + block | Phase 2 (RC5) |
| Enhancement — no `additionalProperties` | Phase 5, now coupled to Phase 4 by the B2 decision |
| Repro module for the upstream issue | Phase 1 tests (we *are* upstream — `origin` is `nyo16/conduit_mcp`, so this becomes a regression test, not an issue) |
| **NEW** — `items :object do ... end` broken (case D) | Phase 1 (RC1) |
| **NEW** — `Component.Schema` blockless object crashes (case E) | Phase 1 (RC2) |
| **NEW** — `Component.Schema` 3-arg + block crashes (case F) | Phase 2 (RC5) |
| **NEW** — `Component.Schema` `:array` block leaks fields, no `items` macro (case G) | Phase 3 (RC6) |
| **NEW** — `build_items_schema/1` has no `nil` clause | Phase 1 (RC2) |
| **NEW** — `nested:` ignored by `convert_param_to_nimble_option/1`; dead `:fields` bridge | Phase 4 (RC4) |
| **NEW** — `schema_converter.ex:18` moduledoc falsely claims nested validation | Phase 4 (RC4) |
| **NEW** — report's `{:map, :string, :any}` alternative is a regression | Phase 1 (RC3), proved |
| **NEW** — `Component.Schema` is the correct reference implementation for RC1 | Phase 1 approach |
| **NEW** — dead `:fields` bridge emits an **invalid** NimbleOptions option (`:schema`), so wiring it as written would crash schema compilation | Phase 4 (RC4), proved |
| **NEW** — nested validation on string-keyed maps is **impossible** in NimbleOptions 1.1.1 (`{:map, :string, :any}` + `keys:` is spec-invalid; even `keys: [*: ...]` is atom-only) | Phase 4 design, proved |
| **NEW** — B2 requires atomising nested keys, which collides with atom-table DoS safety; must match against declared field names only | Phase 4 security constraint |

## Verification gate (every phase)

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix dialyzer
```

Baseline on `master`: all green, 648 tests.

After implementation: all green, **706 tests** (+58). `mix compile --warnings-as-errors`,
`mix format --check-formatted`, `mix credo --strict`, `mix test`, `mix dialyzer` all clean.
New test files: `test/conduit_mcp/object_params_test.exs` (29, phases 1–3) and
`test/conduit_mcp/nested_object_validation_test.exs` (29, phases 4–5).

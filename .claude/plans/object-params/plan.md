# Plan: Make object parameters functional

**Status:** DRAFT — awaiting approval
**Branch:** `fix/object-params` (off `master`)
**Slug:** `object-params`
**Source:** downstream investigation report (conduit_mcp 0.9.7 consumer) + first-party
verification in this tree
**Depth:** standard (findings supplied; verification done inline, no research agents spawned
per Iron Law #7)

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

- [ ] Add regression tests for cases **A**–**G** first, as compile-time assertions
      (`Code.compile_string/1` inside `assert_raise`-style helpers won't work post-fix —
      assert on the *generated schema* instead). Cover: blockless object, block object with
      a param declared before it, 3-arg + block, `items :object`, and both component forms.
      These must fail before the fix.
- [ ] `dsl.ex:454` — replace `@mcp_current_tool_params param_def` with the read-modify-write
      from `:431-432`.
- [ ] `dsl.ex:475` — same.
- [ ] `dsl.ex:508` — replace `@mcp_current_nested_params field_def` with read-modify-write.
- [ ] `dsl.ex:538` — same.
- [ ] Confirm the `[]` seeds at `dsl.ex:441`, `:518`, `:566` remain correct under
      read-modify-write (they do — do **not** switch to `accumulate: true`, which would
      require dropping the seeds and changing reversal order; the report and the existing
      `Component.Schema` implementation both favour read-modify-write).
- [ ] `schema_builder.ex:232` — default `nested_params` to `[]`. Yields
      `{"type":"object","properties":{}}` for an open object, which is correct JSON Schema.
- [ ] `schema_builder.ex` — add a `build_items_schema(nil)` clause returning an
      unconstrained item schema; keep `%{type: :object, nested: nil}` safe via the same
      `|| []` default at `:271`.
- [ ] `schema_converter.ex:86` — `defp convert_type(:object), do: {:map, :any, :any}`.
      **Not** `{:map, :string, :any}` — see RC3.
- [ ] Add a validation test that exercises a nested object with a **non-interning** key
      (e.g. `"zzq_not_an_atom_9f3"`) *and* an interning key (`"name"`) in the same payload,
      so the RC3 regression can't hide behind atom-table luck.
- [ ] Verify: `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix test`

### Phase 2 — Close the arity trap in both DSLs `[dsl]`

- [ ] `dsl.ex:420` — add a guard or an explicit `param(name, type, description, [do: _])`
      clause that raises a `CompileError` naming the file/line and telling the user to pass
      `opts` explicitly (`param :bag, :object, "d", [] do ... end`) or use the 4-arg form.
- [ ] `schema.ex:128` — same for `Component.Schema.field/5`.
- [ ] Decide and document whether 3-arg + block should instead be made to **work** rather
      than raise. Making it work is friendlier and is what users will try first; it needs
      the `[do: _]`-detecting clause to forward to the block implementation with `opts: []`.
      Recommendation: make it work, and keep a raise only for genuinely ambiguous input.
- [ ] Add tests asserting the chosen behaviour for both DSLs.
- [ ] Verify (same gate as Phase 1).

### Phase 3 — `Component.Schema` array items `[schema]`

- [ ] Add an `items/1` and `items/2` macro to `ConduitMcp.Component.Schema` mirroring
      `ConduitMcp.DSL.items/1,2`, or import the DSL's.
- [ ] Make `field :x, :array, ... do ... end` reject a block containing bare `field` calls
      instead of silently leaking them into `:component_fields` (RC6).
- [ ] Tests for `field :rows, :array, "d", [] do items :object do field ... end end`.
- [ ] Verify.

### Phase 4 — Nested runtime validation: decide, then act `[validation]`

Blocked on the open decision below. Whichever branch is chosen, this is required:

- [ ] Fix `schema_converter.ex:18` — the moduledoc claim `:object -> :map (with nested
      validation)` is false today and stays false under option B1.
- [ ] Either wire or delete the dead `convert_validation_opt({:fields, fields}, acc)`
      bridge at `schema_converter.ex:158-162`. Leaving unwired "future support" code in
      place is what let RC4 go unnoticed.

### Phase 5 — `additionalProperties` (optional scope) `[schema]`

- [ ] Honour `opts[:additional_properties]` in `schema_builder.ex` `build_property/1` for
      `:object`, so callers can describe an open bag precisely instead of relying on the
      empty-`properties` convention.
- [ ] Tests for `additional_properties: true | false | %{...}`.
- [ ] Verify.

## Open decision — nested runtime validation (Phase 4)

Phase 1 makes objects pass validation as opaque maps. The JSON Schema still advertises
nested `required` fields, so the server tells clients about constraints it does not
enforce. Three ways to resolve:

- **B1 — Document, don't enforce.** Fix the lying moduledoc, delete the dead `:fields`
  bridge, note that nested shape is advisory. Smallest change, ships with Phase 1, honest.
- **B2 — Wire nested schemas through NimbleOptions.** Requires deterministic key types,
  which `convert_keys_to_atoms/1` does not provide (RC3). Would mean normalising
  object-typed values to string keys *before* validation — a real change to
  `validation.ex`'s key handling with blast radius beyond objects.
- **B3 — Hand-roll nested validation** against the `nested:` tree in `SchemaConverter`,
  independent of NimbleOptions. Most control, most new code, and a second validation path
  to keep in sync with the JSON Schema builder.

Recommendation: **B1 now**, B2/B3 as a separate plan once objects are actually in use.
Shipping B2 inside the unblock couples a key-handling change to a crash fix.

## Split decision

One plan, phases 1–3 as a single PR (they are all "object params work"), Phase 4 folded in
if B1 is chosen, Phase 5 separate. Rationale: phases 2–3 are the same class of defect as
phase 1 and touch the same two files; splitting them means two rounds of the same tests.
Phase 5 is additive API surface and reviews better alone.

If you'd rather land the unblock immediately: Phase 1 alone is a coherent, shippable PR.

## Risks

- **The fix is mechanical but the feature is unproven.** Nothing has ever exercised this
  path, so the tests written in Phase 1 define the contract for the first time. Expect the
  generated JSON Schema shape to need a judgement call (e.g. whether an open object emits
  `"properties": {}` or omits the key).
- **`{:map, :any, :any}` is permissive by design.** It accepts any map. That is correct
  given RC3, but it means a typo'd nested key reaches the handler silently until Phase 4
  resolves. Worth stating in the release notes.
- **Two DSLs, one schema pipeline.** `ConduitMcp.DSL` and `ConduitMcp.Component.Schema`
  both feed `SchemaBuilder` and `SchemaConverter`. Every Phase 1 fix in the shared
  pipeline must be tested from *both* front ends or the component path will drift again —
  it already has (RC6).
- **Version/compat.** This is a public library at 0.9.7. Phase 2's arity-trap change alters
  behaviour for code that currently crashes, so it is not a breaking change; Phase 5 adds
  opts. A patch or minor bump is fine.

## Self-check

- *Does the plan cover every finding in the source report?* Yes — see the completeness
  matrix below, plus 8 findings the report did not have.
- *Is anything in the plan unverified?* No. Every file:line and every failure mode was
  reproduced in this tree. The only unverified items are the design options in Phase 4,
  which are explicitly a decision, not a claim.
- *What would make this plan wrong?* If the intended contract for `:object` is
  "atom-keyed map" rather than "JSON object", then RC3's fix is wrong and the real fix is
  in `convert_keys_to_atoms/1`. The handler-facing contract
  (`convert_keys_to_strings/1` at `validation.ex:220`) says string keys, so JSON object is
  the right reading — but a maintainer should confirm.

## Completeness matrix

Every finding from the source report, plus first-party additions. No finding is dropped.

| Source finding | Where addressed |
|---|---|
| Bug 1 — accumulators never registered (`dsl.ex:69-71` + 4 write sites) | Phase 1 (RC1) |
| Bug 2 — `nested: nil` reaches schema builder (`schema_builder.ex:232`) | Phase 1 (RC2) |
| Bug 2b — same latent nil in `build_items_schema/1` (`:271`) | Phase 1 (RC2) |
| Bug 3 — `:object` → `:map` (`schema_converter.ex:86`) | Phase 1 (RC3) |
| Minor — arity trap on 3-arg + block | Phase 2 (RC5) |
| Enhancement — no `additionalProperties` | Phase 5 |
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

## Verification gate (every phase)

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix dialyzer
```

Baseline on `master`: all green, 648 tests.

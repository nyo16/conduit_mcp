# Testing Reviewer — Full Suite Review (2026-06-11)

⚠️ EXTRACTED FROM AGENT MESSAGE (see scratchpad) — agent's Write was denied in sandbox.

**Summary**: suite broadly well-structured — async safety mostly correct, `TelemetryTestHelper`
registers `on_exit` detach properly, no `Process.sleep`, no Mox/Ecto concerns.

## Critical

**`validation_test.exs:2` — `async: true` with global validation-config mutation**
Test at line 201 calls `Validation.update_validation_config(runtime_validation: false)`; the `after`
block resets it, but `after` does not run if the test process is killed (e.g., timeout). Same pattern
in `endpoint_test.exs:552-563` (also async). Concurrent async tests reading that global config can
flake non-deterministically. Fix: `async: false`, or per-call config injection.

## Warnings

**Raw `:telemetry.attach` without `on_exit` — handler leak on test failure**
- `test/conduit_mcp/session/janitor_test.exs:41`, `:78`
- `test/conduit_mcp/tasks/janitor_test.exs:29`
- `test/conduit_mcp/cancellation_test.exs:78`
If `assert_receive` times out before cleanup, the handler stays attached and sends into a dead PID
for the rest of the run. Route through `TelemetryTestHelper.attach_event_handlers/2` or add `on_exit` detach.

**`conduit_mcp_test.exs:2`** — missing `async: true` (doctest-only module; harmless but serialises a runner slot).

**`endpoint_test.exs:552` / `endpoint_integration_test.exs:216`** — `after` used for global teardown;
prefer `on_exit/1` which survives test-process kill.

**`tasks/store_dispatch_test.exs:171`** — nested describe `setup` calls
`Application.put_env(:conduit_mcp, :tasks_store, MinimalStore)` without explicit restore; relies on
outer module setup save/restore — verify it applies to nested describes.

**`sse_test.exs:67`** — 200ms silence window used as proof of keep-alive loop entry; flaky on loaded
CI. Raise to 1000ms or add a coordination primitive.

## Suggestions

- `cancellation_test.exs` cleanup block doesn't assert telemetry emission (inconsistent with cancel/2 block).
- `session/janitor_test.exs:77` — `refute_receive` 200ms window with 50ms janitor interval; wall-clock coupling.
- No OAuth key rollover/rotation tests — `oauth_test.exs` covers only `KeyProvider.Static` and
  `ResourceMetadata.build/1`; no dynamic key refresh / cache invalidation coverage.
- `conduit_mcp_test.exs` is doctest-only; add smoke tests as the top-level module grows.

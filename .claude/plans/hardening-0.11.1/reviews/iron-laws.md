# Iron Law Violations Report — hardening/0.11.1

**Verdict: PASS WITH WARNINGS.** No BLOCKERs. Two WARNINGs, both about the always-on tasks janitor, which is new. The rest are SUGGESTIONs.

## Summary
- Files scanned: 46 Elixir files (`lib/` 32, `test/` 15 incl. new `body_limit_test.exs`, `examples/` 5, `mix.exs`). YAML, shell and markdown were read for context only.
- Iron Laws checked: 19 generic laws (LiveView #1-3, #11, #12, #17 and Ecto #4-6, #14 and Oban #7-9b don't apply, because the diff has no LiveView, Ecto or Oban code) plus the CLAUDE.md project laws. Those cover Secrets/`format_status`, config validated at init, ETS owners create-and-idle, telemetry in `events/0`, no `Process.sleep`, test timeouts ≥200 ms, the "user code never in library processes" principle and clean cutover.
- Violations found: 0 BLOCKER, 2 WARNING, 8 SUGGESTION.

Checked against new code and found nothing: `String.to_atom` (none added), `:persistent_term.put` on a request path (none; the test-only use is S6), `Process.sleep` added (none; three sleep-polling helpers were removed from `sse_test.exs` and two from `jwks_test.exs`), raising for config errors on the request path (`:before_auth`, `:max_body_bytes` and `:expected_issuers` all raise at `init/1` or `Config.new!`; `parse_body` raises only `Plug.Parsers` 413/400 exceptions, which is correct), per-request `init` (`Plug.Parsers.init/1` runs once, inside `shared_private/3`), unbounded ETS (the `swap/3` match spec now binds the key, so it is a lookup and not a scan), missing `@impl` (`Manager.format_status/1` has `@impl GenServer`), and telemetry (`[:conduit_mcp, :tasks, :cleanup]` metadata `[:store]` in `events/0` matches both emitters, and PromEx `extract_store_tag/1` exists).

---

## BLOCKER

None.

---

## WARNING

### W1. The tasks janitor that now always runs can override a host's own longer `ConduitMcp.Tasks.Janitor` TTL without saying so
- **File**: `lib/conduit_mcp/application.ex:211-222`, `CHANGELOG.md:69-74`, `lib/conduit_mcp/tasks/janitor.ex:10-13`
- **Confidence**: LIKELY
- **What's wrong**: Before 0.11.1 the documented way to sweep tasks was to start `{ConduitMcp.Tasks.Janitor, ttl: ..., interval: ...}` in the host's own tree; both examples did this until this diff. The library now always starts a second sweeper under a different name:
  ```elixir
  defaults = [store: Tasks, ttl: :timer.hours(1), interval: :timer.minutes(5),
              name: Tasks.Janitor.Default, ...]
  owner ++ janitor(:tasks_janitor, defaults, Tasks.Janitor.Default)
  ```
  The names don't collide, so both janitors run, and the shortest TTL wins. A host that kept terminal tasks for 24 h (`ttl: :timer.hours(24)`) loses them after 1 h once it upgrades, and nothing warns at boot.

  The comment this diff deleted from `application.ex` described exactly this hazard for sessions ("shortest sweep wins, and the janitor cannot see per-transport config"). The CHANGELOG breaking-change entry says only "Terminal ... tasks older than one hour are removed every five minutes". The `Tasks.Janitor` moduledoc says "Start this module yourself only for a second sweep with other settings", which implies that a longer TTL there would take effect.
- **Fix**: State it in the CHANGELOG breaking-change bullet and in the `Tasks.Janitor` moduledoc: "If you already start `ConduitMcp.Tasks.Janitor` with a longer `:ttl`, set `config :conduit_mcp, :tasks_janitor, ttl: <same>` or `false`; the shorter sweep wins." Optionally, log a warning from `ConduitMcp.Tasks.Janitor.init/1` when `Process.whereis(ConduitMcp.Tasks.Janitor.Default)` is alive and its TTL is shorter.

### W2. A custom `:tasks_store`'s `cleanup/1` (host code, typically an Ecto Repo) now runs, unrescued, inside `ConduitMcp.Supervisor`
- **File**: `lib/conduit_mcp/application.ex:198-222` (new), together with `lib/conduit_mcp/session/janitor.ex:92-107` (unchanged)
- **Confidence**: REVIEW (the pattern already existed for custom session stores; the new part is turning it on by default for custom task stores)
- **What's wrong**: The `tasks_children/0` comment says "Then the tasks janitor, for any store". `Session.Janitor.handle_info(:cleanup, ...)` calls `store.cleanup(ttl)` with no `rescue`:
  ```elixir
  if cleanup_exported?(store) do
    removed = store.cleanup(ttl)
  ```
  For the Oban example (`Examples.ObanTasks.Store`), that is a Repo query running in `:conduit_mcp`'s tree. That tree starts before the host's Repo and stops after it. At the default 5-minute interval a raising store only crashes and restarts the janitor. With a short `interval:` (under ~1.7 s) and a store that keeps raising (DB outage, Repo not started in a `mix` task), it exceeds `ConduitMcp.Supervisor`'s default intensity (3 restarts in 5 s). The supervisor then exits, and in a release, where deps start `:permanent`, the node goes down.

  The examples' comment ("first sweep after five minutes, by which time the Repo is up") depends on timing, not on supervision order.
- **Fix** (choose one):
  1. In `Session.Janitor.handle_info/2`, wrap the call: `rescue e -> Logger.error(...); 0` (and `catch :exit, _`). Then emit `removed: 0` and reschedule, so a failing store never takes down the library tree. This also hardens the existing custom-session-store path.
  2. Start the default tasks janitor only for `Tasks.EtsStore`, and document that custom stores supervise `ConduitMcp.Tasks.Janitor` after their Repo, as the examples did before this diff.

---

## SUGGESTION

### S1. `Hub.Manager.format_status/1` doesn't clear the `:sys` debug `:log`
- **File**: `lib/conduit_mcp/client/hub/manager.ex:66-77`
- **Confidence**: REVIEW
- **Evidence**: The function redacts `:state.config` and `:message` `{:add, id, _}`. When `:sys.trace/log` debugging is on, the `:log` entries keep `{:in, {:"$gen_call", from, {:add, id, client_config}}}`. The sibling `TokenStore.ETS.format_status/1` already does `Map.replace(:log, [])`.
- **Fix**: Add `|> Map.replace(:log, [])` (`replace`, not `update`, so no key is added). The risk is low now that plain `env:` and `headers:` values are `Secret`s, but OAuth `:auth` options in `client_config` can still hold credentials.

### S2. `inspect/1` of `ConduitMcp.Client.Config` still prints `:assigns`
- **File**: `lib/conduit_mcp/client/config.ex:470-471`
- **Confidence**: REVIEW
- **Evidence**: `@derive {Inspect, except: [:transport]}`. `Client.Connection.format_status/1` treats every `assigns` as sensitive (guides/client_security.md: "redacts ... every `assigns`"), but an inspected `Config` shows them.
- **Fix**: `@derive {Inspect, except: [:transport, :assigns]}`.

### S3. Clean cutover: `Stdio.child_env/3` still types and handles plain-string env values
- **File**: `lib/conduit_mcp/client/transport/stdio.ex:495-498, 525-526`
- **Confidence**: REVIEW
- **Evidence**: `validate_env/1` now always returns `{name, Secret.new(value)}`. Even so, `child_env/3` keeps `@spec ... [{String.t(), String.t() | Secret.t()}]` and `defp expose(value) when is_binary(value), do: value`. Only `stdio_test.exs:136` (`{"HOME", "/srv"}`) reaches that clause.
- **Fix**: Narrow the spec to `[{String.t(), Secret.t()}]`, drop the binary `expose/1` clause (or call `Secret.expose/1` directly), and wrap the test value in `Secret.new/1`.

### S4. `ConduitMcp.Plugs.OAuth.validate_claims/2` made public only for tests
- **File**: `lib/conduit_mcp/plugs/oauth.ex:390-395`
- **Confidence**: REVIEW
- **Evidence**: `# ... so those clauses are a second line that only a direct call reaches; public for the tests.` followed by `def validate_claims(claims, opts)`.
- **Fix**: The repo has precedent (`Application.janitor/3`, `tasks_children/0`), so this is acceptable. Alternatively, cover the second line with a token signed under a Joken config that leaves out the default `nbf`/`iss` claims, and keep the function `defp`.

### S5. Endpoint dual-tuple tests were deleted, not updated for the new `%NimbleOptions{}` shape
- **File**: `test/conduit_mcp/endpoint_test.exs:299-325` (removed)
- **Confidence**: REVIEW
- **Evidence**: Two positive tests (`returns validation schema tuple for tool/prompt`) were removed. The CHANGELOG documents that "The second element of the (undocumented) `__validation_schema_for_tool__/1` tuple is now that struct", but no test pins that shape for Endpoint or DSL servers. End-to-end validation tests still run through it.
- **Fix**: Restore the two tests and assert `{full, %NimbleOptions{}} = FullEndpoint.__validation_schema_for_tool__("echo_tool")` plus `Keyword.has_key?(full, :text)`. Add the same assertion for a DSL server.

### S6. `body_limit_test.exs` puts and erases a `:persistent_term` key in every test
- **File**: `test/conduit_mcp/transport/body_limit_test.exs:31-35`
- **Confidence**: REVIEW
- **Evidence**:
  ```elixir
  :persistent_term.put({RecordingServer, test}, self())
  on_exit(fn -> :persistent_term.erase({RecordingServer, test}) end)
  ```
  Each `erase` triggers a global GC scan of all processes. The module is `async: true`, so this adds latency to unrelated concurrent tests. It is cheap here (4 tests), but it is the pattern the Iron Laws warn about.
- **Fix**: Register the test pid in a test `Registry` keyed by `test` (or `ConduitMcp.Client.Registry` with a unique tuple key), and look it up in `handle_call_tool/3`.

### S7. Change-narration and ticket tags in comments (Law #19)
- **Confidence**: REVIEW
- `test/conduit_mcp/client/secret_scan_test.exs:184`: `# SEC-M1: \`env:\` and \`headers:\` values given as plain strings...`. The audit ticket tag belongs in the commit or PR. Fix: drop `SEC-M1:` and keep the sentence.
- `lib/conduit_mcp/transport/streamable_http.ex:213-215`: `` # `session: [ttl: ...]` appeared in this library's own docs but was never read ... because the key was copied from those docs. `` This is history. Fix: `# session: [ttl:] is accepted for compatibility but ignored; the session janitor's TTL expires sessions.`
- Kept as fine: the CVE references in `mix.exs` dependency floors and `jwks.ex` `@private_members`. They are lasting reasons for the floor or the strip, not narration of the change.

### S8. `rate_limit:` given as a non-keyword term fails at init with `FunctionClauseError`, not with an `ArgumentError` naming the key
- **File**: `lib/conduit_mcp/transport/shared.ex:251-252`
- **Confidence**: REVIEW (it was already like this before: `RateLimit.init/1`'s `Keyword.get` failed the same way)
- **Evidence**: `case Keyword.get(config, :before_auth, false) do`. With `rate_limit: %{backend: X}` this raises `FunctionClauseError` in `Keyword.get/3`. That still happens at boot, but CLAUDE.md asks for errors that name the key.
- **Fix**: Add a `resolve_rate_limit(config) when not is_list(config)` clause that raises `ArgumentError, ":rate_limit must be a keyword list; got #{inspect(config)}"`. Inspecting is safe here, because rate-limit options hold no secrets.

---

## PRE-EXISTING (not analysed further)
- `lib/conduit_mcp/session/janitor.ex:92-107`: no rescue around `store.cleanup/1` for custom session stores (the root of W2).
- `lib/conduit_mcp/transport/shared.ex:376-386`: "warns once per boot" holds only when `init/1` runs once. Under Phoenix `plug_init_mode: :runtime` (dev), `init/1` runs per request, so `warn_if_origins_unset` and the new `warn_session_ttl` log per request, and `Plug.Parsers.init/1` also runs per request.

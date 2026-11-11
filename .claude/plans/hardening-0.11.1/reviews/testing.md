# Test Review: hardening/0.11.1 (uncommitted diff vs `master`, test/ only)

**Verdict: REQUIRES CHANGES.** One removed test has no replacement (B1). Everything else is a warning or a suggestion. B1 takes about 10 lines to fix.

## Summary

The new pipeline-order tests are discriminating, meaning they fail if the fix is reverted:

- In auth and rate-limit, "no credential + bad body = 401" and "denied + bad body = 429" would fail on `master`.
- `:max_body_bytes 10` with an 11-byte body checks 401 before auth and 413 after it.
- The SEC-H1 config test and the JWKS private-member test pin their fixes.
- The SSE `eventually/2` rewrites are correct. The FIFO mailbox-content assertion is stronger than the old length check.

The problems are these:

- The precompiled-schema change has no test pinning it.
- Two concurrency tests can flake: secret-scan `await_ready` after `:sys.terminate`, and the JWKS waiter gate.
- Two tests pass with their fix reverted (ext/tasks concurrent swap, SEC-H1 "outside issuers").
- Some boundary cases of the new behaviour are untested: the `before_auth` key fallback, chunked bodies, a `:client_credentials` config through the client and hub `child_spec`, and a custom `:tasks_store`.

Conventions check:

- No `Process.sleep` in the new code. `eventually/2` polls with `receive after 5`.
- The new timeouts are ≥ 200 ms.
- The real-socket test (`body_limit_test.exs`) is tagged `:integration` and uses `port: 0` and `ip: :loopback`.
- Modules that touch app env, global ETS or telemetry are `async: false`.

## Iron Law Violations

None. No Mox, no `Process.sleep` was added, and the files that change global state (`application_test`, `ext/tasks_test`, `jwks_test`, `secret_scan_test`, `streamable_http_test`, `endpoint_test`) are `async: false`.

---

## BLOCKER

### B1. `test/conduit_mcp/endpoint_test.exs:301-308`: the deleted shape tests have no replacement, so the precompiled-schema change is untested

Two tests were deleted: "returns validation schema tuple for tool" and "…for prompt". They asserted `is_list(clean_schema)`, which is now false because `SchemaBuilder.dual/1` returns `{keyword(), NimbleOptions.t()}`. They were deleted instead of updated. Only the `nil` cases are left:

```elixir
test "returns nil for unknown tool" do
  assert is_nil(FullEndpoint.__validation_schema_for_tool__("nonexistent"))
end
```

Nothing else in `test/` matches `%NimbleOptions` or `SchemaBuilder.dual` (I grepped for both). `ConduitMcp.Validation` accepts any `{_full, _clean}` tuple (`validation.ex:186,199`), and `precomputed_clean || SchemaConverter.strip_markers(full_schema)` hides the difference. So if `dual/1` goes back to `{schema, SchemaConverter.strip_markers(schema)}`, in either Endpoint or DSL mode (`schema_builder.ex:505-517`), every test still passes. The change this was meant to deliver (no per-call compile and meta-validate; the bench halved at 20 params) can then regress silently. The review policy treats "removed tests without replacement coverage" as Critical.

**Fix:** restore the two tests with the new shape, and add the same check for a DSL server:

```elixir
test "returns {full, compiled} for a known tool" do
  assert {full, %NimbleOptions{} = clean} =
           FullEndpoint.__validation_schema_for_tool__("echo_tool")

  assert Keyword.has_key?(full, :text)
  assert Keyword.has_key?(clean.schema, :text)
end
# …same for "code_review_prompt", and for a `use ConduitMcp.Server` DSL module.
```

---

## WARNING

### W1. `test/conduit_mcp/client/secret_scan_test.exs:220,233-234`: `await_ready` can reach the dying connection, so the test can flake with `connection_down`

```elixir
:ok = :sys.terminate(conn, :scan_crash)
…
assert :ok = Client.await_ready(http, 5_000)
assert :ok = Client.await_ready(stdio, 5_000)
```

`:sys.terminate/2` returns before the process exits. OTP 29.1 `stdlib/src/sys.erl:838-840` replies first and only then calls `Mod:system_terminate/4`:

```erlang
{{terminating, Reason}, Reply, NDebug, NMisc} ->
    _ = gen:reply(From, Reply),
    Mod:system_terminate(Reason, Parent, NDebug, NMisc)
```

`Client.await_ready/2` calls `Request.call/3`, which does `Registry.lookup({:client, name})` and then monitors that pid (`lib/conduit_mcp/client/request.ex:193-201`). A connection that is still in `terminate/3` (it runs `Requests.fail_all` and `Data.close_transport`), or that is dead but not yet removed from the Registry, answers `{:DOWN, …}`. That becomes `{:error, connection_down}`, and `assert :ok =` fails. CLAUDE.md says: "After killing a process, wait for its replacement — the Registry drops a dead process's entry asynchronously."

The only barrier is the `eventually` on the **manager's** replacement (l.228-231). The comment there says it waits for "their replacements", but it waits for the manager only. The window is small, and it gets wider under coveralls or a loaded CI.

**Fix:** for each connection, wait for it to die and be replaced before `await_ready`:

```elixir
ref = Process.monitor(conn)
:ok = :sys.terminate(conn, :scan_crash)
assert_receive {:DOWN, ^ref, :process, ^conn, :scan_crash}, 5_000
eventually(fn -> connection(client) != conn end)   # helper at l.475
```

`connection/1` pattern-matches `{:ok, …}`, so guard it for the brief window with no entry, or use `match?/2` on `Registry.lookup/1`. Do the same for the manager (monitor plus `assert_receive :DOWN`). That also makes the "crash report is in" barrier explicit, because the crash report is written before the exit signal.

### W2. `test/conduit_mcp/oauth/jwks_test.exs:290` (and `:513`): the waiter gate is a 200 ms wait, and the stale-age test can flake

```elixir
waiters = for _ <- 1..3, do: Task.async(fn -> JWKS.fetch_keys(config) end)
assert Enum.all?(Task.yield_many(waiters, 200), &match?({_task, nil}, &1))
send(fetcher, :publish)
…
refute_received {:fetching, _}
```

`yield_many/2` returning `nil` does not mean a task is waiting on the lock. A task that has not been scheduled yet also yields `nil`. With `refresh_cooldown: 0` (l.283), a waiter that first runs after `:publish` sees no lock and no cooldown (`jwks.ex:200`). It then goes to `fetch_and_cache`, wins `insert_new`, calls the stub, and sends `{:fetching, _}`, so `refute_received` at l.294 fails. The test comment at l.280-282 relies on all three waiters reaching `await_refresh/3` within 200 ms. That holds most of the time, but it is a wall-clock assumption, which is what removing `Process.sleep(80)` was meant to get rid of.

In the 25-task test (l.513) the same gap goes the other way. A late task finds a fresh cache and returns `{:ok, @keys}` without fetching. The test passes, but "every task raced the winner" is not actually proved for that task.

**Fix:** wait until each waiter is inside the lock wait (`await_refresh/3`, which polls with `Process.sleep(25)`) before publishing:

```elixir
in_wait? = fn %Task{pid: pid} ->
  case Process.info(pid, :current_stacktrace) do
    {:current_stacktrace, st} -> Enum.any?(st, &match?({JWKS, :await_refresh, 3, _}, &1))
    nil -> false
  end
end

eventually(fn -> Enum.all?(waiters, in_wait?) end, 5_000)
```

Keep the `yield_many` check as well, as the proof that the waiters did not return early.

### W3. `test/conduit_mcp/transport/rate_limit_integration_test.exs:267,276`: `before_auth` keys are never asserted, so the documented fallback is untested

```elixir
assert_received {:hit, _key}
refute_received {:hit, _key}
```

The new `RateLimit` moduledoc ("Failed authentications") says that with `before_auth: true` "No principal is assigned at that point, so `&ConduitMcp.Principal.rate_limit_key/1` falls back to the client bucket". It also says per-user buckets need the after-auth position (scratchpad C1). No test sets `key_func:` together with `before_auth`, and every assertion uses `_key`. If someone makes the fallback crash on a missing principal, or key on `nil`, or makes `before_auth: true` keep the principal key, the suite stays green, and the result is either every request getting a 500 or every client sharing one bucket.

**Fix:** add `key_func: &ConduitMcp.Principal.rate_limit_key/1` to `before_auth_opts/3` and assert the actual key:

- `before_auth: true`, with both `"right-token"` and `"wrong-token"`: `assert_received {:hit, key}` and `assert key == ConduitMcp.Principal.client_bucket(conn)`. For `Plug.Test` that is the bucket of `{127, 0, 0, 1}`, with no `"user:"` prefix.
- `before_auth: false` with `"right-token"`: `assert_received {:hit, "user:" <> _}` (`principal.ex:293-296`).

### W4. `test/conduit_mcp/ext/tasks_test.exs:110`: "concurrent updates of different tasks" passes with PERF-M5 reverted

The change in `lib/conduit_mcp/ext/tasks/ets_store.ex` is performance-only: the key moved from a guard into the match head, and `write_concurrency: true` was added. The old spec `{{:"$1", :"$2"}, [{:"=:=", :"$1", {:const, task_id}}, …]}` also updates both rows correctly, so this test passes on `master`. The `:ready`/`:go` barrier starts both writers together, but they touch different keys, so there is nothing to race. Neither part of the change is pinned:

- the key bound in the head (the table scan was 244.6 µs, now 0.64 µs);
- `write_concurrency: true` rather than `:auto` (the code comment explains why `:auto` is wrong).

**Fix:** pin the decision you can observe:

```elixir
assert {:write_concurrency, true} in EtsStore.table_opts()
refute {:write_concurrency, :auto} in EtsStore.table_opts()
```

Then either drop the concurrency framing (the existing CAS test at l.87 already covers `swap/3` with a head-bound key) or rename the test so it does not claim to cover the change. A wall-clock regression guard for the head-bound key would break the flakiness rules. Accept that it is not pinned, and say so in the `swap/3` comment.

### W5. `test/conduit_mcp/client/oauth/flow_test.exs:595`: "outside :expected_issuers gets nothing" passes on `master`; the SEC-H1 client and hub config path is untested

The test passes `expected_issuers: [real.issuer]` explicitly. `Discovery.select_issuer/2` already enforced the list before this branch (`test/conduit_mcp/client/oauth/discovery_test.exs:142-151`), so the test does not depend on the fix. The only SEC-H1 regression guard is `OAuth.Config.new!` (l.572).

The behaviour users see is "raises at config time" when the config goes through `ConduitMcp.Client.child_spec/1` with `transport: {StreamableHTTP, url: …, auth: {:client_credentials, …}}`, or through a hub server entry. `[INFERENCE]` That path goes through `lib/conduit_mcp/client/transport/streamable_http.ex:317-332` (`oauth_config/1` → `OAuth.Config.new/1`). No test calls it without `:expected_issuers`. The four existing callers were all updated to pass it, so a regression in how the transport builds options (for example `:expected_issuers` dropped while being forwarded) would go unnoticed.

**Fix:** add:

```elixir
assert_raise ArgumentError, ~r/expected_issuers/, fn ->
  ConduitMcp.Client.child_spec(
    name: :x,
    transport:
      {StreamableHTTP,
       url: "https://mcp.example.com",
       auth: {:client_credentials, client_id: "svc", client_secret: "s"}}
  )
end
```

Add the equivalent for `ConduitMcp.Client.Hub.child_spec/1`. Keep the end-to-end test, but don't count it as the regression guard.

### W6. `test/conduit_mcp/transport/body_limit_test.exs:40-53`: only `content-length` bodies are tested; the path the header comment worries about is not

The header says "Bandit 1.14's `read_body` may return more than `:length` bytes". For `content-length`, Bandit reads exactly `min(unread_content_length, length)` (`deps/bandit/lib/bandit/http1/socket.ex:437`). The chunked path (`do_read_chunked_data!/5`, l.457-485) is the one that compares a whole chunk against `max_to_read`. Two things are untested over a real socket:

- a `transfer-encoding: chunked` body over the limit (as one large chunk, and as many small ones);
- a custom `:max_body_bytes`. The only small-limit test is `auth_integration_test.exs` (max 10), and it runs through `Plug.Test`, whose adapter does not read bodies the way Bandit does.

**Fix:** add a chunked variant of `post/3` (send `"transfer-encoding: chunked"` and hex-size framing) that expects 413 and `refute_received :handler_ran`. Also add one case that starts the transport with `max_body_bytes: 1_024` and posts 1 025 bytes.

---

## SUGGESTION

- **S1. `test/conduit_mcp/plugs/oauth_test.exs:525-546`:** `validate_claims/2` was made public (`@doc false`) only so these tests can call it. The lib comment says these clauses are "a second line that only a direct call reaches". The tests pin branches the plug cannot reach, through a function that exists only for the tests. Either delete the redundant `nbf`/`iss` re-checks (Joken's default claims already enforce them) or keep them private and untested. Don't widen the API for coverage.
- **S2. `test/conduit_mcp/application_test.exs:157`:** the `:tasks_janitor` contract (`application.ex` `tasks_children/0`) says the janitor runs "for any store" and the owner only for the default store. Add `Application.put_env(:conduit_mcp, :tasks_store, SomeStore)` (restored in `on_exit`) and assert `[%{id: ConduitMcp.Tasks.Janitor.Default}]` with no owner. Also cover `true`, which should give the defaults (`interval: :timer.minutes(5)`, `ttl: :timer.hours(1)`).
- **S3. `test/conduit_mcp/client/secret_scan_test.exs:238`:** `assert log =~ "terminating"` only shows that *some* crash report was captured. The surface that actually leaked was the manager's GenServer crash report (scratchpad 4.1; on OTP 29 the `:gen_statem` connections log none). Assert that this report is present, for example `assert log =~ "Hub.Manager"` together with `"terminating"`. Otherwise a change that stops capturing that report turns the log scan into a no-op that still passes.
- **S4. `rate_limit_integration_test.exs:239`:** in ":message_rate_limit still sees the parsed body", both limiters answer 429, so the status alone doesn't say which one fired. Add `assert_received {:hit, _}` (the HTTP limiter allowed the request) before relying on the 429.
- **S5. `auth_integration_test.exs:300-314` / `rate_limit_integration_test.exs:310-324`:** the same `status/3` and `post/2` helpers appear twice. Move them to `test/support/`. For the 400/413 cases, consider `assert_raise Plug.Parsers.ParseError` / `Plug.Parsers.RequestTooLargeError` instead of mapping any exception through `Plug.Exception.status/1`. A different exception with the same `plug_status` would currently pass.
- **S6. `test/conduit_mcp/client/oauth/flow_test.exs:676-702`:** the loopback plug tests build the plug's internal opts map by hand (`%{path:, once: :atomics.new(1, []), owner:, ref:}`), copying `loopback.ex:100`. If the shape changes, these tests break or drift. Consider a small `@doc false` constructor that both use. Also add a `POST /cb` case, which should be 404 because only `GET` is answered.
- **S7. `body_limit_test.exs:91-93`:** `[INFERENCE]` On Linux, if Bandit closes the socket while request bytes are still unread, the kernel sends RST instead of FIN, and the client can lose the 413 before `recv` (`{:error, :econnreset}` → `flunk`). At limit+1 Bandit has normally read everything, so the risk is low. If it ever flakes on CI, accept `:econnreset` *only* in the 413 case.

## PRE-EXISTING

- `test/conduit_mcp/transport/sse_test.exs:280`: `SSE.active_connections() == before + 1` reads a node-wide counter in an `async: true` module. The rewrite kept the old `slots_reach?/2` logic. PRE-EXISTING.
- `test/conduit_mcp/endpoint_integration_test.exs:238-242`: `update_validation_config/1` writes `:persistent_term` (global GC) from a test. It is snapshotted and restored. PRE-EXISTING.

# Elixir Review: hardening/0.11.1 (uncommitted diff vs master)

**Verdict: PASS WITH WARNINGS.** No blockers. Two warnings: a compile-time strictness change in a patch release, and a hardening claim that does not hold when the transport is mounted under a Phoenix endpoint.

Things I checked and found correct:
- The `Plug.Parsers.init/1` output survives `Macro.escape` (a tuple of lists, MFAs, atoms and integers).
- `Plug.Parsers.call/2` on an unparsed conn behaves the same as before.
- No library plug between `:match` and `:parse_body` reads `conn.params`, `conn.query_params` or `conn.body_params`. `Plugs.Auth` and `Plugs.OAuth` read only headers.
- In `Ext.Tasks.EtsStore.swap/3`, a literal binary key in the match-spec head is a key lookup. The only caller is `update/3`, after `get/2`'s `is_binary` guard.
- `write_concurrency: true` without `:auto` leaves decentralized counters off for a `:set`, as the comment says.
- Every reader of `:env` and `:headers` exposes the `Secret` at the wire or spawn: `Stdio.child_env/3` → `expose/1`, and `Client.HTTP.open` → `expose/1`. The listener, Exchange and DELETE paths all go through `Client.HTTP`. `Secret.new/1` is idempotent.
- OTP 27.2 `gen:format_status/4` only rejects a map that *drops* keys. So `Map.update(:message, nil, …)` adding a key is harmless, and a call's `:message` is the inner request `{:add, id, cfg}`.
- `Session.Janitor` over `ConduitMcp.Tasks` emits `%{store: ConduitMcp.Tasks}`, which matches `Telemetry.events/0` and the PromEx tag.
- `Tasks.create/3` and `Tasks.owner/1` exist with the signatures the examples use.

---

## BLOCKER

None.

---

## WARNING

### W1. `lib/conduit_mcp/dsl/schema_builder.ex:534` (and `lib/conduit_mcp/endpoint.ex:457,470`): `dual/1` turns a tolerated invalid schema into a hard compile error

```elixir
def dual(schema), do: {schema, NimbleOptions.new!(SchemaConverter.strip_markers(schema))}
```

The DSL deliberately treats an invalid NimbleOptions schema as a **warning**:

```elixir
# lib/conduit_mcp/dsl.ex:1974
defp log_schema_validation_warnings(reversed_tools, reversed_prompts) do
  case ConduitMcp.DSL.SchemaBuilder.validate_all_schemas(...) do
    ...
    {:error, errors} -> Logger.warning("Validation schema compilation warnings: ...")
```

`SchemaConverter.convert_type/1` passes unknown types through unchanged (`defp convert_type(type) when is_atom(type), do: type` and `defp convert_type(type), do: type`). Nothing at DSL time rejects a type like `param :when, :date` or `param :x, "string"`. Before this diff such a module compiled. With `config :conduit_mcp, :validation, runtime_validation: false`, or for a tool nobody calls, it worked. Now `NimbleOptions.new!` raises `ArgumentError "invalid NimbleOptions schema. Reason: …"` inside `@before_compile`. That error does not name the tool, and the compile fails in a 0.11.1 patch release. It also makes `log_schema_validation_warnings/2` effectively dead, since the compile now fails anyway. No test covers an invalid-schema DSL module (`grep "schema compilation warnings" test/` finds nothing).

**Fix (either):**
- Keep the old contract: precompile only when the schema is valid, and otherwise fall back to the keyword list. `Validation.validate_with_schema/3` already accepts a keyword clean schema (`precomputed_clean || strip_markers(full)`).
  ```elixir
  def dual(schema) do
    clean = SchemaConverter.strip_markers(schema)
    compiled =
      try do
        NimbleOptions.new!(clean)
      rescue
        ArgumentError -> clean   # already reported by log_schema_validation_warnings/2
      end
    {schema, compiled}
  end
  ```
- Or make it a deliberate break: raise a `CompileError` naming the module and tool, delete `log_schema_validation_warnings/2`, and add a CHANGELOG "Changed" entry.

### W2. `lib/conduit_mcp/transport/shared.ex:120,514` and `guides/rate_limiting.md:75`: the "no body read before auth" and `:max_body_bytes` guarantees do not hold under a Phoenix endpoint

```elixir
def parse_body(conn), do: Plug.Parsers.call(conn, conn.private[:body_parsers])
```

`Plug.Parsers.call/2` only reads the body while `body_params` is `%Plug.Conn.Unfetched{}`. Otherwise it takes the second clause (`deps/plug/lib/plug/parsers.ex:325`) and just merges. The README's own Phoenix setup (`README.md:292`, `forward "/", ConduitMcp.Transport.StreamableHTTP, …`) sits behind a stock Phoenix endpoint. That endpoint runs `plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"]` with the 8 MB default. So in the most common deployment:
- the body is read and decoded before `:authenticate` and `:rate_limit`;
- `:max_body_bytes` has no effect.

The new docs state both guarantees without qualification: the `Shared` moduledoc, the `:max_body_bytes` docs in `streamable_http.ex`/`sse.ex`, and `guides/rate_limiting.md:75` ("answered before its body is read").

**Fix:** document it next to `:max_body_bytes` and in the README Phoenix section. Under Phoenix, the endpoint's `Plug.Parsers` (its `:length`) decides the limit, and it runs before auth. Either scope the MCP path out of the endpoint parser (for example a `Plug.Parsers` `body_reader`/path guard) or set `:length` there.

---

## SUGGESTION

### S1. `lib/conduit_mcp/client/config.ex:471`: `@derive {Inspect, except: [:transport]}` still prints `:assigns`
`Connection.format_status/1` redacts every `assigns` as host data (`connection.ex:162-166`), but `inspect(%Client.Config{})` still prints them, for example in a supervisor child-spec report. Fix: `@derive {Inspect, except: [:transport, :assigns]}`.

### S2. `lib/conduit_mcp/client/hub/manager.ex:67-77`: `:log` and `:reason` are not redacted
`OAuth.TokenStore.ETS.format_status/1` also does `Map.replace(:log, [])`. With `:sys` debug on, `:log` holds `{:in, {:add, id, client_config}, from}` events. A `FunctionClauseError` in `handle_call/3` puts the call args (`{:add, id, cfg}` and the state with `:config`) into the `:reason` stacktrace. Fix: add `|> Map.replace(:log, [])`. Prefer `Map.replace_lazy/3` over `Map.update(key, nil, …)` so absent keys aren't inserted. The latter is harmless per `gen.erl:772`, but misleading.

### S3. `lib/conduit_mcp/client/oauth/config.ex:342`: `describe/1` cutover is incomplete
```elixir
def new(other), do: {:error, "expected OAuth options as a keyword list, got: #{inspect(other)}"}
```
This is the most credential-heavy option set. `OAuth.Config.new/1` is public, so a map of OAuth options with `client_secret:` is printed verbatim. Fix: `"got #{ConduitMcp.Client.Config.describe(other)}"`. Lower risk, same class: `client/transport/streamable_http.ex:1055,1061` print the whole URL (query or fragment may carry a token).

### S4. `lib/conduit_mcp/client/oauth/config.ex:331` and `client/transport/streamable_http.ex:320,1141`: a pre-built `%OAuth.Config{}` skips the SEC-H1 check
`new(%__MODULE__{} = config), do: {:ok, config}` and `validate_auth({:oauth, %OAuth.Config{}})` accept a struct as-is. So `%OAuth.Config{credentials: %{…client_credentials…}, expected_issuers: nil}` built by hand gets past the new `:expected_issuers` requirement. Hand-building is unlikely, but the check would be airtight if it ran where the grant is used: `ClientCredentials.request/3`, or re-checked in `new/1`'s struct clause.

### S5. `lib/conduit_mcp/plugs/oauth.ex:395`: a private function made public only for coverage
The new comment says the `nbf` and `iss` clauses are "a second line that only a direct call reaches; public for the tests". So `validate_claims/2` becomes API surface purely to cover branches that are unreachable through `call/2`. Acceptable, since the repo already does this for `Application.janitor/3`, but consider testing through a token Joken lets through (custom `token_config`) instead of widening the module.

### S6. `lib/conduit_mcp/transport/streamable_http.ex:213-225`: "Warned once, at boot" is not accurate under `forward`
`Plug.Router.forward/2` and Phoenix `forward` call `init/1` at **compile time**. There the warning appears once during `mix compile` of the host router and never at boot (and not in a release). Reword the comment and CHANGELOG, or say "when `init/1` runs (compile time under `forward`)".

### S7. `CHANGELOG.md:68-70`: the breaking-change note names only `conn.body_params`
Before this diff, `Plug.Parsers` ran before `:rate_limit`, so a `key_func` also saw fetched `conn.query_params` and `conn.params`. Both are now `%Plug.Conn.Unfetched{}`, and `conn.params["x"]` raises `UndefinedFunctionError` because `Unfetched` has no `Access`, giving a 500 on every request. Mention all three, or call `Plug.Conn.fetch_query_params/1` before `:rate_limit_before_auth` (cheap, no body read).

### S8. `lib/conduit_mcp/application.ex:217-231`: the always-on tasks janitor now runs host code under `ConduitMcp.Supervisor`
- `Session.Janitor.handle_info(:cleanup, …)` (`session/janitor.ex:96`) has no rescue. A custom `:tasks_store` whose `cleanup/1` raises (a Repo that is down, as in the Oban example) crashes a library child every 5 minutes. That will not exceed restart intensity, but the crash reports come from the library's tree. Consider rescuing, logging and emitting `removed: 0`.
- PRE-EXISTING, now load-bearing: `lib/conduit_mcp/tasks.ex:153` uses `function_exported?(mod, :cleanup, 1)` without `Code.ensure_loaded?`. In interactive mode a custom store not yet loaded is silently swept as 0.

### S9. `lib/conduit_mcp/client/config.ex:616`: `describe/1` mislabels non-binary bitstrings
A bitstring like `<<1::3>>` falls through to "a pid, port or reference". Add an `is_bitstring/1` clause (e.g. "a bitstring") before the catch-all.

---

## PRE-EXISTING (not analysed further)
- `lib/conduit_mcp/transport/shared.ex:226`: `Keyword.get(opts, :rate_limit) || endpoint_config[:rate_limit]`. `rate_limit: false` on the transport cannot switch off an Endpoint-declared limiter.
- `lib/conduit_mcp/tasks.ex:153`: `function_exported?/3` without `Code.ensure_loaded?/1` (see S8).
- `README.md:295`: `token: System.get_env(...)` inside a Phoenix `forward` is evaluated at compile time.

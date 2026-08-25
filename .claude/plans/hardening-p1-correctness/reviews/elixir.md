# Elixir idioms & correctness review — P1 hardening (round 2)

**Verdict:** incorrect · confidence 0.88

Two reproduced blockers in the P1 hardening change. (1) ConduitMcp.Reflect.text/2 — the module whose whole purpose is to make client-supplied text safe to reflect — rescues only Protocol.UndefinedError, but to_string/1 on a JSON array raises ArgumentError or UnicodeConversionError. Cancellation.insert_cancellation/3 pipes the raw client `reason` through it on the notification path, which has no rescue, so `notifications/cancelled` with `"reason": [1.5]` raises uncaught out of Handler.handle_request/3 (verified via mix run). (2) RC3's move to resolving plugs in Shared.init/1 embeds ConduitMcp.Plugs.RateLimit's default local function capture in the router's init opts, so Plug.Router.forward — which escapes the init result at compile time — now fails to compile for any rate-limited mount; this compiled at HEAD. Three warnings (the Reflect bug also downgrades -32602 to -32603; endpoint.ex:386/397 still reflect the raw client URI, so RC13 is unapplied in Endpoint mode; validate_tool_params/3's public return contract changed without its @doc following) and three suggestions. Full report at .claude/plans/hardening-p1-correctness/reviews/elixir.md.

## Findings

### P0 — Handle lists in Reflect.text/2 — to_string/1 raises ArgumentError, not Protocol.UndefinedError

`lib/conduit_mcp/reflect.ex:86-92` (confidence 0.95)

`stringify/1`'s fallback rescues only `Protocol.UndefinedError`. `to_string/1` on a list raises `ArgumentError` (`[1.5]`, `[%{}]`) or `UnicodeConversionError` (`[-1]`), and JSON can put an array anywhere a scalar is expected. `Cancellation.insert_cancellation/3` (cancellation.ex:160) pipes the raw client `params["reason"]` through `truncate_reason/1` -> `Reflect.text(reason, 200)` (cancellation.ex:295), and the notification path has no rescue: `handle_notification/3` is reached from the `cond` in `handle_request/3` (handler.ex:69-73), outside `do_handle_method/5`'s rescue. Reproduced with `mix run`: `%{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{"requestId" => "abc", "reason" => [1.5]}}` raises ArgumentError out of `Handler.handle_request/3`. Any client that can POST gets a 500 with a stacktrace instead of a JSON-RPC reply on both transports. Same input class is live and uncaught at transport/shared.ex:371-374 (behind Logger's level check). Fix: add `defp stringify(value) when is_list(value), do: inspect(value, limit: 10, printable_limit: 256)` and widen the fallback rescue to `_ in [Protocol.UndefinedError, ArgumentError, UnicodeConversionError]`.

### P0 — Restore Plug.Router.forward support — init/1 now embeds a non-escapable closure

`lib/conduit_mcp/transport/shared.ex:247-249` (confidence 0.92)

`Shared.init/1` returns initialised plug options inside the router opts (`resolve_plug(mod, config) -> {mod, mod.init(config)}`), and `Plugs.RateLimit.init/1` puts a local function capture in that map (rate_limit.ex:103, `key_func: Keyword.get(opts, :key_func, &default_key_func/1)`; identically message_rate_limit.ex:120). `Plug.Router.forward/2` calls `target.init(opts)` at compile time and escapes the result into `@plug_forward_opts`, which cannot escape a closure. Reproduced: `forward "/mcp", to: ConduitMcp.Transport.StreamableHTTP, init_opts: [server_module: Srv, allowed_origins: "*", rate_limit: [backend: FakeBackend, limit: 5]]` fails with `cannot inject attribute @plug_forward_opts ... cannot escape #Function<0.10520185/1 in ConduitMcp.Plugs.RateLimit.default_key_func>`. At HEAD this compiled: `StreamableHTTP.init/1` returned `opts` verbatim and each plug's `init/1` ran per request. The same mount without `:rate_limit` compiles, and a remote capture (`verify: &V.verify/1`) compiles — the trigger is the default `key_func`, i.e. the configuration a consumer gets by writing nothing. Fix: promote `default_key_func/1` to a public function in both plugs and capture it as `&__MODULE__.default_key_func/1` (remote captures are escapable), and state in shared.ex:26-33 that `forward` requires configured callbacks to be remote captures.

### P1 — Reflect the URI in Endpoint-mode Resource not found errors

`lib/conduit_mcp/endpoint.ex:384-398` (confidence 0.9)

Every other `Resource not found` site touched by this change routes the URI through `ConduitMcp.Reflect.text/1` (dsl.ex:1352, dsl.ex:1653, endpoint.ex:188, server.ex:272). The two emitted by `generate_resource_clause/1` still interpolate `#{uri}` raw — and those are the reachable ones in Endpoint mode: endpoint.ex:188 is only emitted when `parts.resource_clause` is `nil`, i.e. when the endpoint declares no resources at all. RC13 is therefore not applied to Endpoint mode: a URI up to the transports' `length: 1_000_000` parser cap is reflected verbatim into the error message, and control characters (NUL, ANSI escapes, U+202E bidi overrides) are not stripped — exactly the log- and response-forging surface `ConduitMcp.Reflect` was introduced to close. Fix: `"Resource not found: #{ConduitMcp.Reflect.text(uri)}"` at both sites.

### P2 — Unknown tool returns -32603 instead of the documented -32602 for a non-scalar name

`lib/conduit_mcp/handler.ex:497-504` (confidence 0.9)

`unknown_target_error/3` and `task_not_found/2` (handler.ex:789-794) reflect client-supplied `name`/`taskId` through `Reflect.text/1`. With a JSON array they raise, are swallowed by `do_handle_method/5`'s rescue (handler.ex:174-183), and the client receives `-32603 Internal server error` plus a spurious `[error] Error handling method` log line. Reproduced: `tools/call` with `"name" => [1.5]` returns `%{"error" => %{"code" => -32603, "message" => "Internal server error"}}`, not the `-32602 Unknown tool` the comment at handler.ex:493-497 promises. Contradicts the MCP-spec error contract this change deliberately introduced and converts routine client mistakes into operator error-log noise. Resolved by the reflect.ex fix; worth a regression test alongside it.

### P2 — Document the new :tool_not_found / :prompt_not_found returns of validate_tool_params/3

`lib/conduit_mcp/validation.ex:33-58` (confidence 0.82)

`validate_tool_params/3` and `validate_prompt_args/3` now propagate `{:error, :tool_not_found}` / `{:error, :prompt_not_found}` — a bare atom where the second element was always a list of error maps. The `@doc` still says "`{:error, validation_errors}` with detailed error information" and both examples show only the list shape. `format_validation_errors/1` is guarded `when is_list(errors)` (validation.ex:128), so a consumer doing the documented `case validate_tool_params(...) do {:error, errs} -> format_validation_errors(errs)` now gets a `FunctionClauseError` instead of a formatted payload. Both functions are public and documented, so this is a silent breaking change at an upgrade boundary for anyone driving validation outside `ConduitMcp.Handler` (custom transports, stdio bridges, tests). Fix: document the two atoms in both `@doc`s and either add an `is_atom` clause to `format_validation_errors/1` or state that the atoms must be matched first.

### P3 — Re-raise in EtsOwner.claim/3 when the table name is not actually taken

`lib/conduit_mcp/ets_owner.ex:55-68` (confidence 0.8)

`:ets.new/2` raises `ArgumentError` for two unrelated reasons and the rescue cannot tell them apart: `:ets.new(:t, [:naned_table, :public])` raises `ArgumentError "2nd argument: invalid options"`, and a duplicate `:named_table` raises `ArgumentError` too (both verified). A typo or unsupported option in a caller's `table_opts` is therefore logged as "the name is already taken, so the table belongs to another process", `claim/3` returns `:ok`, and the Agent starts healthy while owning nothing — every subsequent `ensure_table/0` then also fails and the operator chases a non-existent ownership race. The module's whole purpose is to make table ownership diagnosable, and the one message it emits can be actively wrong. Fix: `rescue e in ArgumentError -> if :ets.whereis(table) == :undefined, do: reraise(e, __STACKTRACE__); Logger.warning(...); :ok`.

### P3 — Exclude handler-less resources from build_scope_map/2 so scope order matches dispatch order

`lib/conduit_mcp/dsl.ex:1386-1398` (confidence 0.75)

`build_scope_map/2` collects every entry carrying a `:scope`, while `generate_resource_clauses/1` first drops entries with `handler: nil` (dsl.ex:1576-1579). So `resource "a://{id}" do scope "x" end` with no `read` contributes a template to `__scope_for_resource__/1`'s ordered scan but no dispatch clause. If that template overlaps a later scoped-and-handled template, the scan stops at the handler-less one and enforces its scope while `handle_read_resource/2` runs the other's handler — the exact mismatch the comment at dsl.ex:1382-1385 says the ordering fix prevents. Narrow (needs overlapping templates plus a handler-less scoped resource) and it fails closed, but it silently enforces the wrong scope. Fix: filter `handler: nil` entries out of `build_scope_map/2` the same way `generate_resource_clauses/1` does, so both lists derive from one predicate.

### P3 — Document that handle_request/3 can return an error map for a notification

`lib/conduit_mcp/handler.ex:69-73` (confidence 0.78)

The notification branch changed from `handle_notification(...); :ok` to `handle_notification(request, server_module, conn)`, which returns an error map for a malformed `notifications/cancelled` (handler.ex:262-290). The moduledoc still states "Unknown notifications are logged and dropped (per JSON-RPC notification semantics)" and the `@doc` on `handle_request/3` promises "a JSON-RPC response" with no mention of `:ok`. `Shared.dispatch_post/2` handles both, but a consumer transport that pattern-matched `:ok` for every notification now falls through. Fix: document the `:ok | map()` return and the deliberate "malformed notification is answered with an id-null error" deviation on `handle_request/3` itself, not only in a private comment.

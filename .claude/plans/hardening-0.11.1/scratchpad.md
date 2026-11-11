# Scratchpad: hardening-0.11.1

## Decisions

- **Scope.** The first draft held 13 findings (the three HIGH ones and release gating). On 2026-11-10 the user
  pulled in nine more groups: SEC-M1; SEC-M5 + SEC-L3 + D8; the rest of D2; ARCH-09 + SEC-M7; the rest of SEC-M2;
  PERF-M5; PERF-M7; T1 + T6 + T7; T15 + ARCH-29. Everything not picked stays deferred (87 findings).
- **SEC-H1: raise at config time, no opt-out.** Confirmed by the user. Rejected alternatives:
  - Trust on first use (remember the first issuer seen): the first contact is with the attacker's server.
  - Warn now, raise in 0.12: leaves the secret leak on by default in the release that is meant to fix it.
- **C1: move the parser, not the limiter.** `rate_limit → authenticate → parse` as the default would throttle
  failed authentications, but `ConduitMcp.Plugs.RateLimit`'s moduledoc documents
  `key_func: &ConduitMcp.Principal.rate_limit_key/1` for per-user limits, which needs the principal that
  `:authenticate` assigns. Moving the limiter first by default silently turns every per-user bucket into a
  per-address one.
- **Failed-auth throttle: `rate_limit: [before_auth: true]`.** One new boolean on an existing option, no new
  plug and no third limiter. The host picks the position. Per-user limits remain available through
  `:message_rate_limit`, which always runs after authentication.
- **Tasks janitor.** The application starts `Session.Janitor` over `ConduitMcp.Tasks` under the name
  `ConduitMcp.Tasks.Janitor.Default`. `ConduitMcp.Tasks.Janitor` is kept: it is documented, and a host that
  supervises it registers it under the module name, so the default child must not use that name.
- **Precompiled schemas: generators only.** A manual server's bare keyword schema is still compiled per call.
  The audit suggested caching it in `:persistent_term`, but `validate_with_schema/3` runs on the request path and
  a `put` there triggers a global GC. Security already lists one such site as a known issue (`dsl.ex`).
- **`session: [ttl:]` warns, does not raise.** The key was copied from this library's own docs. Raise in 0.12.

## Dead ends

- **`"authfail:"` bucket in `Shared.authenticate/1`** (SEC-M2's non-breaking alternative, and what the first
  version of the health report recommended). The auth plugs send the 401 and halt, so the hit happens after the
  guess was evaluated and answered. The backend contract is `hit(key, scale, limit)`, which always increments;
  there is no way to ask "is this bucket already over?" before verifying the credential. The bucket would count
  failures and block none. Rewriting the response in a `register_before_send` callback does not help either: a
  correct guess is answered 200, so the attacker still learns it.
- **Peeking at the backend before verifying.** Hammer 7 has no portable read: `hit/4` is an optional callback
  whose increment is specified as positive, the sliding-window algorithm has no increment at all, and `get` takes
  `(key, scale)` for windows but `(key)` for buckets. The library's contract is "a module with `hit/3`".
- **A third limiter option (`auth_rate_limit:`).** Works, but adds a third limiter config next to two plugs the
  audit already wants merged (ARCH-13). `before_auth: true` gets the same effect with one key.
- **Splitting the auth plugs into verify and respond.** Would allow a failure-only bucket, but it is a refactor
  of two public plugs. Not for a patch release.

## Facts gathered while planning (checked in the code, 2026-11-10)

- `transport/shared.ex`: plugs in order are `Plug.Logger`, `SecurityHeaders`, `OriginValidation`,
  `:add_cors_headers`, `:match`, `Plug.Parsers`, `:authenticate`, `:rate_limit`, `:classify_era`,
  `:message_rate_limit`, extra plugs, `:dispatch`.
- Readers of `conn.body_params`: `Shared.classify_era/1` (through `Plugs.HeaderValidation`),
  `Plugs.MessageRateLimit.call/2` (passes an unfetched body through), `Shared.dispatch_post/2`, and helpers in
  `streamable_http.ex`. None runs before `:classify_era`.
- No plug in `lib/conduit_mcp/plugs/` reads `conn.params` or `conn.query_params`. A `:function` auth strategy's
  `verify` receives only the credential, never the conn.
- `Plugs.RateLimit.init/1` reads its options with `Keyword.get/3` and skips `OPTIONS` requests.
- Transport integer options are validated in `Shared.stream_private/1` from `@stream_defaults`.
- No test covers the 413 path today.
- Client-credentials configs without `:expected_issuers` in tests: `client/secret_scan_test.exs`,
  `client/token_leak_test.exs`, `client/oauth/connection_test.exs` (2), `client/oauth/flow_test.exs` (`cc_config/2`).
- `OptionalDeps` restates requirements in `@joken_deps`, `@req_deps`, `@jsv_deps`, `@finch_deps`.
- `Stdio.child_env/3` and `Client.HTTP.expose/1` already accept `Secret` values. `format_status/1` exists on
  `Client.Connection`, `TokenStore.ETS` and the stdio port owner, not on `Hub.Manager`.
- `Application.janitor/3` builds a `Session.Janitor` child from `true | false | keyword` and raises naming the
  key otherwise. `ConduitMcp.Tasks.cleanup/1` exists and delegates to the configured store.
- `Telemetry.events/0`: `[:conduit_mcp, :tasks, :cleanup]` has measurements `[:removed]` and no metadata keys;
  the session and ext-tasks cleanup events carry `[:store]`.
- `Tasks.create/3` takes the owner as its third argument.
- The generators' tuple is `{schema, clean_schema}`; `NimbleOptions.validate/2` accepts a `%NimbleOptions{}`.
- `ConduitMcp.TestRateLimiter` is `use Hammer, backend: :ets`; the plug tests also define recording and
  always-deny backends inline.
- `mix hex.audit` exits 1 on the current lock (Hex 2.6.0).
- Dialyzer on Elixir 1.18.3 / OTP 27.2 works with `MIX_BUILD_PATH=/private/tmp/...`; the `/tmp/...` form in
  `CLAUDE.md` fails on macOS. `/tmp/cm_build_118_dev/lib/abnf_parsec/priv` is a dangling link from the failed try.

## Open questions

- Does Bandit 1.14.1 reset a long-lived HTTP/2 SSE stream that leaves `{:bandit, _}` messages unread? (task 1.4)
- Does jsv 0.27.0 pass the client schema-validation tests? (task 1.3)
- Which of the four SEC-M1 surfaces actually print a plain credential today? (task 4.1)
- Can a token pass Joken and still fail the plug's own `nbf` / issuer checks, or must `validate_claims/2` be
  called directly? (task 6.1)
- Is CI on GitHub already red on the `audit` job? (user)

## Results (fill in during work)

- Lock diff: exactly the five packages, no transitive movement. bandit 1.13.1 → 1.14.1, jose 1.11.12 → 1.11.13,
  jsv 0.26.1 → 0.27.0, plug_crypto 2.2.0 → 2.2.1, ssl_verify_fun 1.1.7 → 1.1.9. `mix hex.audit` exit 0,
  `mix deps.audit` "No vulnerabilities found", `mix deps.unlock --check-unused` exit 0. Local toolchain here is
  Elixir 1.20.0 / OTP 29.
- Bandit 1.14.1 spike (`research/h2_spike.exs`, raw h2c over `:gen_tcp` with Bandit's frame modules): **the stream
  is reset (RST_STREAM 0xB ENHANCE_YOUR_CALM).**
  - A, adversarial burst of stream-level WINDOW_UPDATE (increment 1), keep-alive 15 s, after the first event:
    n=50 no reset on either stream; n=99 tools/call reset, listen not; n=100/101/150 both reset. Keep-alive
    20 ms, n=150: 71 more DATA frames, then reset. Only the flooding peer's own stream dies.
  - B, emulated client answering every DATA frame with a stream + connection WINDOW_UPDATE, tool emitting 1000
    progress events in a burst: reset after 592 / 624 DATA frames (two runs).
  - C, Mint HTTP/2 (Finch's stack), same tool: 200, completed, 133 106 bytes. Mint refills by threshold, not per
    frame.
  - D, the B client against a plain `send_chunked` + 1000 × `chunk/2` plug with no ConduitMcp code: reset after
    628 DATA frames. **The reset is Bandit-wide**, not caused by `SSEStream.await/5` leaving `{:bandit, _}`
    unread: a stream consumes at most one queued message per `send_data` (`receive … after 0`), so a burst of
    sends that outruns the peer's WINDOW_UPDATEs leaves them queued, and 100 queued resets the stream.
  - Mechanism, Bandit 1.14.1 `http2/connection.ex` `@max_queued_stream_messages 100`, `deliver_to_stream/5`;
    `http2/stream.ex` `do_send_data/4`, consumption reported every 16 (`@consumed_messages_report_interval`).
  - **User decision (2026-11-10): accept Bandit 1.14.1 and document it.** Guide: `protocol_eras.md`, "Under
    HTTP/2 (Bandit 1.14)". CHANGELOG must carry it too.
- 1.4 item 1: the over-limit body is 413 on both transports over a real HTTP/1.1 socket, with no handler run
  (`body_limit_test.exs`, plus an exactly-at-limit control that is handled).
- 1.4 item 3: no test or guide assumes more than 500 streams on one connection. `:max_streams` is node-wide across
  connections; Bandit's 500 is per connection. Noted in the same guide section.
- 1.4 suite: seeds 1, 2, 3 each 2429 passed (61 doctests, 40 properties, 2328 tests). 1.5 bare consumer: OK.
- SEC-H1 repro (`research/sec_h1_repro_test.exs`): **reproduced.** PRM on the real AS host names a second fake
  AS; with no `:expected_issuers`, `OAuth.token_for/2` posted to the attacker's `/token` with
  `authorization: "Basic c3ZjOnMzY3JldA=="` (`svc:s3cret`). After 2.2 the same config raises at `Config.new!`.
- PERF-H1 before / after (Plug.Test through `StreamableHTTP.call/2`, logger `:error`, 500 iterations after 50
  warm-up, Elixir 1.20.0 / OTP 29, mean per request; "before" = `shared.ex` stashed back to master):
  | rejection | before | after |
  |---|---|---|
  | unauthenticated, small body | 9.5 µs | 8.3 µs |
  | unauthenticated, 734 KB body | 270.6 µs | 8.0 µs |
  | rate-limited, small body | 10.3 µs | 9.6 µs |
  | rate-limited, 734 KB body | 272.2 µs | 9.3 µs |
  Large/small ratio ≈ 28× before (the audit measured 5.29 ms vs 10.2 µs, ≈ 520×, on its toolchain), ≈ 1.0× after.
  Script deleted.
- SEC-M1 surfaces (4.1, before the fix; plain `headers:` value on an HTTP client, plain `env:` value on a stdio
  client, both also as hub servers): **leaking** — the captured log (the header, in `Hub.Manager`'s GenServer crash
  report, `State:`), `:sys.get_status/1` of `Hub.Manager` (env and header), and all 7 malformed-config messages
  (`Client.child_spec/1` ×3, `Hub.child_spec/1` ×4). **Not leaking** — `:sys.get_status/1` of either connection
  (`format_status/1` already redacts). The audit's `[INFERENCE]` about supervisor reports: Elixir drops SASL
  supervisor reports by default, so the observed log leak is the manager's crash report. Note: on OTP 29
  `:sys.terminate/2` of the `:gen_statem` connection logs no crash report at all; a GenServer's does.
- PERF-M5 at 10 000 rows (throwaway `elixir` script, one table with the new `table_opts/0`, 2 000 swaps of one key,
  Elixir 1.20.0 / OTP 29): guard-bound key (before) **244.6 µs** per swap; head-bound key (after) **0.64 µs**.
- `mix bench validation` before / after (mean, Elixir 1.20.0 / OTP 29):
  | case | before | after | memory before → after |
  |---|---|---|---|
  | 1 param (echo) | 1.26 µs | 0.87 µs | 3.70 → 2.52 KB |
  | 5 params (create_user) | 4.55 µs | 2.53 µs | 12.54 → 7.15 KB |
  | 20 params (bulk_import) | 20.06 µs | 10.21 µs | 45.27 → 20.73 KB |
  | manual server (no schemas) | 0.35 µs | 0.38 µs | unchanged |
  The 20-parameter full pipeline halves (the auditor's 15 312 → 2 688 ns was the validate step alone).
- Action tag → SHA (newest tag on the major already in use, `git ls-remote`; all three are lightweight tags on
  commits): `actions/checkout` v6.1.0 → `d23441a48e516b6c34aea4fa41551a30e30af803`; `erlef/setup-beam` v1.24.1 →
  `54075bcc5e249e4758d363f27d099f55d843f124`; `actions/cache` v5.1.0 → `caa296126883cff596d87d8935842f9db880ef25`.
  Newer majors exist (checkout v7, cache v6); not taken, Dependabot will propose them.
- 7.4: the plan's "same `grep` and `cut` `release.sh` uses" is broken: `grep '@version' mix.exs` matches three
  lines (`@version "…"`, `version: @version,`, `source_ref: "v#{@version}"`), so `VERSION` was three lines and the
  check could never pass (and `release.sh` built a multi-line tag name). Both now use
  `grep -E '^[[:space:]]*@version "' mix.exs | head -n 1 | cut -d'"' -f2`.
- Final gate (2026-11-10, local Elixir 1.20.0 / OTP 29 unless noted): `mix compile --warnings-as-errors` dev and
  test ✓ · `mix format --check-formatted` ✓ · `mix credo --strict` 0 issues · `mix test` seeds 1, 2, 3: 2465 passed
  each (61 doctests, 40 properties, 2364 tests) · `MIX_ENV=test mix coveralls` 90.4 % · `mix sobelow --config
  --exit` ✓ · `mix hex.audit` exit 0 · `mix deps.audit` no vulnerabilities · `mix deps.unlock --check-unused`
  exit 0 · `mix docs` no warnings · `mix hex.build` ✓ (0.11.1) · bare-consumer check OK · CI toolchain
  (Elixir 1.18.3 / OTP 27.2, `MIX_BUILD_PATH="$PWD/_build/ci_118_dev"`, the 8.1 recipe verbatim):
  `mix compile --warnings-as-errors` ✓, `mix dialyzer` "Total errors: 0 … done (passed successfully)" · tag
  check dry run: v0.11.1 passes, v0.11.2 and `v0.11.1#{1}` exit 1.
- Review cycle 1 (5 agents): 2 regressions, both fixed with red-first tests. (1) `NimbleOptions.new!` in
  `@before_compile` broke DSL servers with an unknown param type → `dual/1` falls back to the keyword schema.
  (2) After a pre-parse 401/429, Bandit 1.14.1's `ensure_completed/1` drains the unread body (default `length:
  8_000_000`) on keep-alive → `Shared.close_if_body_left_unread/1` sends `connection: close`, which Bandit's
  `handle_keepalive/3` honours (`keepalive: false`, drain skipped). After: 2470 tests green on seeds 1–3,
  coverage 90.5 %, Dialyzer 0 (1.18.3/27.2). Open review warnings: unpinned precompiled schema, Phoenix
  `forward` parses before the transport, default tasks janitor vs a host's longer TTL, `HEX_API_KEY` scope,
  secret-scan restart barrier, SEC-M1 gaps (`OAuth.Config.new/1` inspect, `:assigns`, manager `:log`), test gaps.

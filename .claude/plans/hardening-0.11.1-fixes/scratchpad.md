# Scratchpad: hardening-0.11.1-fixes

## Decisions

- No research agents: planned from a triage file (plan skill Iron Law 7); the five review reports are the research.
- One plan, not split: 16 small items on one uncommitted branch for one release.
- W3: restore shape tests (user), knowingly pinning an internal detail: the precompiled schema is a performance
  property no behavioural test can see.
- S9: `ConduitMcp.Plugs.OAuth.Claims` outside the Joken guard; pure map checks.
- S6: rescue + `catch :exit` in `Session.Janitor` (user); no telemetry on failure, `events/0` unchanged.
- S8: delete the ext-tasks concurrency test rather than rewrite it: the guard-key and head-key specs behave the
  same, so no deterministic test distinguishes them; the 244.6 → 0.64 µs measurement is the evidence.
- W4 workaround: a plug above `Plug.Parsers` in the Phoenix endpoint calling `Plug.forward/4` on the MCP prefix.

## Facts (checked 2026-11-10)

- `client/oauth/config.ex:331` `new(%__MODULE__{} = config), do: {:ok, config}` — the struct path skips
  `credentials/1`; `:342` inspects a non-keyword term.
- `client/transport/streamable_http.ex:295` `validate_options/1` → `oauth_config/1` (`:317`) is where
  `auth: {:oauth | :client_credentials, ...}` becomes an `OAuth.Config`.
- `oauth/key_provider/jwks.ex:339` waiters loop in `await_refresh/3` (`Process.sleep(@lock_wait_step)`), so
  `:current_stacktrace` shows `{JWKS, :await_refresh, 3, _}` while blocked.
- `session/janitor.ex:96` `removed = store.cleanup(ttl)` is unguarded.
- README "Phoenix Integration" (`README.md:288`) mounts the transport with `forward` in the router.

## Dead ends

- **`:sys.get_status/1` with no marker anywhere** (1.1 acceptance as written). `sys.erl` `get_status/5` returns the
  raw `Debug` list (the `:sys.log` events) verbatim; `format_status/1` only governs the formatted part and crash
  reports. The test asserts on the formatted (5th) element.

## Results (2026-11-10, Elixir 1.20.0 / OTP 29 unless noted)

- 1.3: a Static RSA JWK with a malformed `p` made jose raise `CaseClauseError` in `create_signer/2` (not rescued:
  only `Joken.Error` is); with `KeyProvider.public_key/1` in `fetch_signing_key/2` it verifies.
- 2.1: forwarding plug above `Plug.Parsers` → unauthenticated 401 body unread; authenticated 2 KB over a 100-byte
  limit 413. Below it (= router `forward`) → 401 body read; 200, limit ignored.
- 2.4: before parsing, a `key_func` sees `conn.params == %{}`, `query_params`/`body_params` unfetched.
- Gate: `mix format --check-formatted` ✓ · `mix compile --warnings-as-errors --force` dev and test ✓ ·
  `mix credo --strict` 0 issues · `mix test` seeds 1, 2, 3: 2485 passed each (61 doctests, 40 properties,
  2384 tests) · `MIX_ENV=test mix coveralls.json` 90.5 % (claims.ex future-nbf, malformed-nbf, wrong-iss
  clauses hit) · `mix docs` 0 warnings · bare-consumer check OK · `mix hex.audit` exit 0 · `mix sobelow --config
  --exit` 0 · CI toolchain (Elixir 1.18.3 / OTP 27.2, `MIX_BUILD_PATH="$PWD/_build/ci_118_dev"`): compile
  `--warnings-as-errors` ✓, `mix dialyzer` "Total errors: 0 … passed successfully" · secret-scan test 10/10 seeds
  and `--max-cases 4` · jwks + ext tasks seeds 1–3 and `--max-cases 4`.

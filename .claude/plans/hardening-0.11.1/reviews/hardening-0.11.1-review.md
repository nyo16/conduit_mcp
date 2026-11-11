# Review: hardening-0.11.1 (cycle 1)

**Verdict: REQUIRES CHANGES → both must-fixes resolved (2026-11-10); warnings 3–9 open.** Two regressions introduced
by this branch; the rest are warnings and suggestions.

**Resolution.** (1) `SchemaBuilder.dual/1` keeps the keyword schema when `NimbleOptions.new!/1` raises; regression
test `dsl_test.exs` "a param type NimbleOptions does not know" (red before: `ArgumentError ... unknown type :date`).
(2) `Shared.close_if_body_left_unread/1` registers a before-send that adds `connection: close` when the request has
a body and `body_params` is still unfetched; tests in `body_limit_test.exs` (rejected 4 MB-announced body → 401 with
`connection: close` and the socket closed; a body-less 401 keeps the connection), red before. Docs and CHANGELOG
corrected. Re-verified: seeds 1–3 green (2470), credo 0, coverage 90.5 %, Dialyzer 0 on 1.18.3/27.2, docs clean,
bare consumer OK.
Panel: elixir-reviewer, security-analyzer, testing-reviewer, iron-law-judge, requirements-verifier (per-agent files
in this directory). Verification-runner skipped: the full gate passed in this session.

## Requirements Coverage

Plan `.claude/plans/hardening-0.11.1/plan.md`: **MET 33 / PARTIAL 2 / UNMET 0 / UNCLEAR 0** (`requirements.md`).
- PARTIAL 5.3: two endpoint tests deleted rather than rewritten (plan said "suite passes unchanged").
- PARTIAL 5.5: `examples/oban_tasks_server/test/telemetry_test.exs:23` still calls `Tasks.create/2` (recorded, test setup).

## Must fix (regressions)

1. **Invalid DSL param schemas now fail compilation** — `lib/conduit_mcp/dsl/schema_builder.ex:534`,
   `lib/conduit_mcp/endpoint.ex:457,470` (elixir W1; **reproduced**). `dual/1` calls `NimbleOptions.new!` in
   `@before_compile`. A tool with a param type NimbleOptions rejects (e.g. `:date`) used to compile with a warning
   (`dsl.ex:1974`) and worked under `runtime_validation: false`; it now raises
   `ArgumentError ... unknown type :date` with no tool name. Fix: fall back to the keyword schema (compiled per
   call, as before) when `new!` raises, or make it a deliberate `CompileError` naming the tool plus a Breaking
   changes bullet.
2. **A rejected request's body is still read, up to 8 MB, on HTTP/1.1 keep-alive** — `lib/conduit_mcp/transport/shared.ex`
   (security W1; **verified in Bandit 1.14.1** `http1/socket.ex:869-874`, `:437`). After a 401/429 the body is
   unread, so Bandit's `ensure_completed/1` drains it with its default `length: 8_000_000`. Before, `Plug.Parsers`
   stopped at 1 MB, raised 413 and the connection closed. CPU per rejection fell (PERF-H1 holds); peak memory per
   unauthenticated connection rose up to 8×. The docs/CHANGELOG claim "a rejected request costs no body read" is
   wrong on HTTP/1.1. Fix: when the pipeline halts before `:parse_body` with a body pending, send
   `connection: close` (Bandit then sets `keepalive: false` and skips the drain); add an `:integration` test that
   sends an oversized body without credentials over a real socket; correct the docs and CHANGELOG.

## Warnings

3. **Precompiled schema is unpinned** (testing B1, elixir S, requirements PARTIAL 5.3). Nothing fails if `dual/1`
   reverts to a keyword list. Main-agent view: this is a performance property, not behaviour; the plan asked for
   bench numbers, which are recorded. Testing-reviewer rates it BLOCKER; listed here as a warning.
4. **Phoenix `forward` setups get no body limit or ordering benefit** (elixir W2). A Phoenix endpoint's own
   `Plug.Parsers` (8 MB) runs before the forwarded transport, and `Plug.Parsers.call/2` is a no-op on a parsed
   body. Document it in `guides/rate_limiting.md` and the transport docs.
5. **Default tasks janitor overrides a host janitor's longer TTL** (iron-law W1). Shortest sweep wins; a host that
   runs `ConduitMcp.Tasks.Janitor` with `ttl: 24h` now loses terminal tasks after 1 h. Say so in the CHANGELOG
   breaking bullet and the `Tasks.Janitor` moduledoc (`config :conduit_mcp, :tasks_janitor, false` or a matching
   `ttl:`).
6. **`HEX_API_KEY` scope** (security W2, user action). `environment: hex-release` protects the key only if it is an
   environment secret; as a repository secret any branch job can read it. Add to "For the user".
7. **Flake risk in the new SEC-M1 test** (testing W1). `secret_scan_test.exs:233-234` waits for the manager's
   replacement but not for each terminated connection's; `Client.await_ready/2` may resolve a stale Registry entry.
   Monitor each connection, `assert_receive :DOWN`, then await readiness. (Green on 4 runs so far.)
8. **SEC-M1 completeness** (elixir S, security S). `ConduitMcp.Client.OAuth.Config.new/1` still `inspect`s a
   non-keyword options term (`client/oauth/config.ex:342`); `inspect/1` of `Client.Config` still prints `:assigns`;
   `Hub.Manager.format_status/1` leaves the `:sys` debug `:log`.
9. **Test gaps** (testing W3, W5, W6). `before_auth` tests never check which key is hit; no test goes through
   `Client.child_spec/1` / `Hub.child_spec/1` with client credentials and no `:expected_issuers`; no real-socket
   chunked-body or custom `:max_body_bytes` case (chunked is where Bandit can return more than `:length`).

## Suggestions

- A hand-built `%OAuth.Config{}` passed to `OAuth.Config.new/1` skips the `:expected_issuers` check (elixir, security).
- Strip private JWK members in the OAuth plug too, covering Static and custom key providers (security).
- With `before_auth: true`, document that `key_func` must not key on caller-asserted identity (security).
- Publish job: `persist-credentials: false` on checkout; check the tagged commit is on `master` (security).
- `release.sh` may print a remote URL that embeds a token (security).
- A custom store's `cleanup/1` now runs unrescued under `ConduitMcp.Supervisor` (iron-law W2, elixir). At the 5-min
  default interval a crash loop cannot exceed the supervisor's intensity; only a tiny configured interval could.
- `describe/1` labels bitstrings "a pid, port or reference"; the session `:ttl` warning fires at compile time under
  `forward` (comment says "at boot"); CHANGELOG could add that `key_func` also sees unparsed `conn.params`.
- `ext/tasks_test.exs:110` passes with PERF-M5 reverted (testing W4; the plan asked for that case); jwks waiters
  are not proven to be on the lock (testing W2); `validate_claims/2` public for tests only.

## Pre-existing (not in this diff)

See the per-agent files; e.g. a non-keyword `rate_limit:` fails with `FunctionClauseError` (iron-law S8).

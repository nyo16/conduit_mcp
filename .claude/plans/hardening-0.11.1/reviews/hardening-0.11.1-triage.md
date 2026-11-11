# Triage: hardening-0.11.1 (review cycle 1)

Source: `reviews/hardening-0.11.1-review.md`. Must-fixes 1–2 were already resolved before triage.
Decided by the user, 2026-11-10: **16 to fix, 0 skipped, 0 deferred.** No open finding is an Iron Law violation.

## Fix Queue

### Warnings (7)

- [x] **W3 — Pin the precompiled schema.** `lib/conduit_mcp/dsl/schema_builder.ex:539`, `test/conduit_mcp/endpoint_test.exs`.
  User: *restore shape tests*. Assert `__validation_schema_for_tool__/1` / `_prompt__/1` return
  `{keyword, %NimbleOptions{}}` for an Endpoint and a DSL server, and a keyword list for an unknown param type.
- [x] **W4 — Phoenix `forward` caveat.** `guides/rate_limiting.md:75`, transport moduledocs. A Phoenix endpoint's own
  `Plug.Parsers` runs first, so `:max_body_bytes` and parse-after-auth have no effect there; say so and how to avoid
  it (route the transport outside the endpoint's parser, or skip the parser for that path).
- [x] **W5 — Default tasks janitor vs a host's longer TTL.** `lib/conduit_mcp/application.ex:206`, `Tasks.Janitor`
  moduledoc, CHANGELOG breaking bullet: shortest sweep wins; use `config :conduit_mcp, :tasks_janitor, ttl: ...`
  or `false`.
- [x] **W6 — `HEX_API_KEY` scope.** `.github/workflows/ci.yml:263`. User: *document it*. Comment on the publish job
  and a release-checklist line: move the key to the `hex-release` environment's secrets, delete the repository
  secret, restrict the environment to `v*` tags.
- [x] **W7 — secret-scan restart barrier.** `test/conduit_mcp/client/secret_scan_test.exs:220-233`. Monitor each
  terminated connection, `assert_receive :DOWN`, then wait for the replacement before `await_ready/2`.
- [x] **W8 — SEC-M1 gaps.** `lib/conduit_mcp/client/oauth/config.ex:342` (describe, don't inspect, a non-keyword
  options term); `lib/conduit_mcp/client/config.ex:471` (`Inspect` also omits `:assigns`);
  `lib/conduit_mcp/client/hub/manager.ex:67` (`format_status/1` clears the `:sys` `:log`).
- [x] **W9 — Test gaps.** `before_auth` tests assert which key is hit (client bucket fallback); a
  `Client.child_spec/1` / `Hub.child_spec/1` case for `{:client_credentials, ...}` without `:expected_issuers`; a
  real-socket chunked body and a custom `:max_body_bytes` case in `body_limit_test.exs`.

### Suggestions (9)

- [x] **S1 — Hand-built `%OAuth.Config{}` bypass.** `client/oauth/config.ex`: re-check `:expected_issuers` for a
  `:client_credentials` struct passed to `new/1`.
- [x] **S2 — Strip private JWK members in the OAuth plug** too (Static and custom key providers), not only in JWKS.
- [x] **S3 — `before_auth` `key_func` doc.** `plugs/rate_limit.ex` moduledoc, `guides/rate_limiting.md`: don't key
  on caller-asserted identity before authentication (a caller could exhaust a victim's bucket).
- [x] **S4 — Publish job hardening.** `ci.yml` publish: `persist-credentials: false` on checkout; fail unless the
  tagged commit is on `master`.
- [x] **S5 — `release.sh` token in URL.** `scripts/release.sh:79`: strip userinfo from the remote URL before printing.
- [x] **S6 — Rescue a store's cleanup.** `lib/conduit_mcp/session/janitor.ex:96`. User: *rescue and log in
  `Session.Janitor`*; the janitor keeps its schedule after a failed sweep.
- [x] **S7 — Wording nits.** `client/config.ex:616` `describe/1` bitstrings; the session `:ttl` warning comment ("at
  boot" vs compile time under `forward`); CHANGELOG: a `key_func` also sees unparsed `conn.params`.
- [x] **S8 — Weak concurrency tests.** `test/conduit_mcp/ext/tasks_test.exs:110` passes with PERF-M5 reverted;
  `jwks_test.exs` waiters not proven to be blocked on the lock.
- [x] **S9 — `validate_claims/2` public for tests.** `plugs/oauth.ex:395`. User: *move to a small claims module*
  (`@moduledoc false`) that both the plug and the tests call; the plug keeps no test-only public function.

## Skipped

None.

## Deferred

None.

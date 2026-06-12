# Security Analyzer — Whole-Codebase Audit (2026-06-11)

⚠️ EXTRACTED FROM AGENT MESSAGE (see scratchpad) — agent's Write was denied in sandbox.

**Baseline (positive)**: session IDs via `:crypto.strong_rand_bytes`; static creds via
`Plug.Crypto.secure_compare`; validation uses `String.to_existing_atom`; catch-all errors return
generic "Internal server error" (no stack-trace leak); 1MB body cap.

## Findings

**1. WARNING — JWT alg not pinned to allow-list** `plugs/oauth.ex:174-247` (CWE-347)
Algorithm derived from the key (`oct→HS256`, `%{"alg"=>alg}→alg`), not pinned to an operator
allow-list nor cross-checked against the peeked token header `alg` (line 100). A JWKS returning a
symmetric/attacker-influenced key enables forgery/downgrade. Fix: `:algorithms` allow-list option +
header/alg consistency check. (Orchestrator note: deriving alg from the key rather than the token
header already blocks the classic RS/HS confusion; this is defense-in-depth against a hostile or
misconfigured JWKS.)

**2. WARNING — JWKS fetch lacks transport hardening** `oauth/key_provider/jwks.ex:95-112` (CWE-918)
`Req.get(jwks_uri)` with no HTTPS enforcement, redirect limit, timeout, or response-size cap; failed
refresh silently serves stale cached keys. Operator-config, not client input — a footgun, not a direct
vuln. Fix: require https, `max_redirects: 0`, timeouts, size limit.

**3. WARNING — Origin validation off by default** `plugs/origin_validation.ex:25-27`; transports
default `allowed_origins: nil` + `cors_origin: "*"` (CWE-350). MCP spec wants Origin validation
against DNS rebinding. Also: requests with no Origin header always pass even when an allow-list is
set (line 36) — defensible for non-browser MCP clients, but document it. Fix: secure defaults for
loopback binds; log a warning when unset.

**4. PERSISTENT (KNOWN/DEFERRED) — Tasks lack owner scoping** `handler.ex:506-556` (CWE-639/BOLA)
`tasks/list` returns all tasks; any caller can get/result/cancel any leaked taskId. Deliberately
deferred from PR #14 triage. Re-scope before tasks leave experimental.

**5. SUGGESTION — Header values built from unvalidated input** `plugs/oauth.ex:274-321`
(resource_uri → WWW-Authenticate), `transport/sse.ex:237-242` (client Host echoed into SSE endpoint
event) (CWE-113/644). Strip CRLF / use configured base URL.

**6. SUGGESTION — Session ID not required for non-initialize POSTs** `transport/streamable_http.ex:161-163`
POSTs lacking `Mcp-Session-Id` pass through without checking method == initialize.

**7. SUGGESTION — SSE keep-alive connections unbounded** `transport/sse.ex:255-267`
No concurrent-connection cap; rate-limit plug throttles request rate, not held connections.

**8. SUGGESTION (low) — `String.to_atom/1`** `validation/schema_converter.ex:324`
Field name derived from defined-field error message (bounded), but prefer `to_existing_atom`.
(Deduped with iron-law-judge #10 — iron-law version kept in consolidated review.)

**Noted as theoretical**: cross-client cancellation needs ID collision (low); `:public` ETS tables;
unsupported-version error reflects `client_version` (JSON-encoded, not XSS).

**Recommended manual runs**: `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`.

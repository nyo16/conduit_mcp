# Security review — P1 hardening (round 2)

**Verdict:** PASS WITH WARNINGS

No auth bypass, no injection and no confidentiality leak found in the new code.
The two round-1 blockers (JWKS stale-serve on the waiter path, unsupervised SSE
counter) are fixed; neither is PERSISTENT. What remains is one fail-open on a
resource cap, one sustained unauthenticated cross-tenant denial of service
against cancellation, two incomplete guards, and two hardening gaps — all in
code introduced by this change.

## Findings

### WARNING — `:max_connections` fails **open** when the counter table is unavailable
`lib/conduit_mcp/transport/sse.ex:288-295` · NEW

```elixir
defp update_active(delta) do
  :ets.update_counter(@connections_table, :active, {2, delta}, {:active, 0})
rescue
  ArgumentError -> 0
end
```

`acquire_connection_slot/1` (`sse.ex:265-275`) then evaluates
`if update_active(1) > max`, i.e. `0 > 1_000` → `false` → **slot granted**.
Every failure mode of the counter is therefore read as "the server is idle", and
the cap that exists because each stream "pins a process, a socket and a
`Plug.Conn` for the life of the connection" (`sse.ex:27-28`) is silently
disabled rather than enforced.

This is coupled to the next finding: `ConduitMcp.Transport.SSE.Owner` no longer
raises when it loses the table — it logs and returns `:ok`
(`ets_owner.ex:56-70`). In that state the table belongs to whichever stream
process created it; when that one client disconnects the table is destroyed, and
the next `acquire_connection_slot/1` either resets `:active` to 0 via
`ensure_connections_table/0` (`sse.ex:316-324` — the exact round-1 defect) or
trips this rescue and admits unconditionally.

**Why it matters:** for a resource cap, "I could not read the counter" must mean
"no". The project's own stated rule is that rate limiting fails closed when
configured; this fails open. Reachable path: `GET /sse` with
`Accept: text/event-stream` in a loop against a node whose SSE Owner degraded.
Each admitted stream is held until `:max_connection_lifetime` (default 1 h), so
the real ceiling becomes memory rather than `:max_connections`.

**Minimal fix:** return a value that denies the slot instead of one that grants
it:

```elixir
rescue
  # Counter unreadable: deny the slot rather than disabling the cap.
  ArgumentError -> :unavailable
end
```

and have `acquire_connection_slot/1` treat `:unavailable` as `false`. The
release path has its own separate `rescue` (`sse.ex:277-286`) and is unaffected.

---

### WARNING — `EtsOwner.claim/3` degrades permanently, with no retry and no ownership check
`lib/conduit_mcp/ets_owner.ex:56-70` · NEW

Rescuing is the right call for supervisor stability — three raises in five
seconds does take down the consumer's application, and the moduledoc's reasoning
holds. But the degrade is **terminal**: `claim/3` returns `:ok`, the Agent idles
forever, `Supervisor` reports a healthy tree, and nothing ever re-attempts the
claim. The racer the moduledoc itself names is a request or janitor process that
exits seconds later, taking the table with it — at which point the name is free
again and the Owner could have it, but never asks.

Worst reachable outcome, per table:

| table | consequence of losing the claim |
|---|---|
| `:conduit_mcp_sse_connections` | **security-relevant** — reinstates the round-1 `:max_connections` bypass, plus the fail-open above |
| `:conduit_mcp_sessions` | all sessions vanish when the owning request exits → clients get 404 "Session not found". Availability only, and it fails *closed* |
| `:conduit_mcp_cancellations` | in-flight cancellations forgotten → tools run to completion. Availability only |
| JWKS cache | refetch on the next request. **Not** a confidentiality issue: a destroyed cache cannot serve stale keys, so this cannot resurrect the round-1 blocker |
| tasks | rows lost → `Tasks.get/2` 404s. Fails closed |

So degrading is safe for confidentiality and integrity — no table is ever
*shared* wrongly, only made *short-lived* — and only the SSE counter turns loss
of ownership into a bypass. Boot-time reachability is nil (all Owners start in
`always_started/0`, `application.ex:64-66`, before any listener accepts), so
this is a WARNING and not a blocker; it becomes reachable only if an Owner is
killed and restarted while traffic is live.

**Why it matters:** the change traded a loud failure (supervisor shutdown) for a
silent one, and one of the five tables has a security invariant riding on
ownership. The operator gets a single `Logger.warning` and no way to observe or
recover the degraded state.

**Minimal fix:** make the degrade recoverable rather than terminal. Keep the
warning, but schedule a bounded re-claim — the Agent can
`Process.send_after(self(), :claim, 1_000)` and retry `:ets.new/2` until
`:ets.info(table, :owner) == self()`. That preserves the "never raise" property
while closing the permanent-degrade window.

---

### WARNING — the global cancellation cap re-introduces exactly the cross-tenant DoS the per-scope quota was added to prevent
`lib/conduit_mcp/cancellation.ex:146-150` and `269-273` · NEW

```elixir
cond do
  at_capacity?() -> {:error, :cancellation_limit_reached}              # global, 10_000
  scope_at_capacity?(scope) -> {:error, :cancellation_limit_reached}   # per-scope, 256
  true -> insert_cancellation(scope, id, reason)
end
```

The moduledoc states the design intent verbatim at `cancellation.ex:57-65`: *"a
global cap alone is a cross-tenant denial of service, because one
unauthenticated client filling the table stops every other client's
cancellations from being recorded."* The implementation then checks the global
cap **first and unconditionally**, so a caller whose own scope holds zero rows is
refused as soon as anybody has filled the table. The per-scope quota bounds one
scope to 256 rows; nothing bounds how many scopes one client may own.

**Concrete exercise** — server configured `session: []` (any list) with no
`:auth`, the documented posture for a local/dev server:

1. `POST /` × 40, body
   `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}`.
   Each response carries a distinct `mcp-session-id`; `sessions_max_rows`
   defaults to 100 000 (`session/ets_store.ex:70`), so 40 is free.
2. For each id, 256 × `POST /` with header `mcp-session-id: <that id>`,
   `content-type: application/json`, body
   `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":<1..256>}}`.
   Each session is a distinct `scope/1` — `cancellation.ex:124` prefers
   `conn.private[:mcp_session_id]` — so each gets its own 256-row quota:
   40 × 256 = **10 240 rows > the 10 000 default `:cancellations_max_rows`**.
3. Every *other* client's `notifications/cancelled` now returns
   `{:error, :cancellation_limit_reached}`.

The janitor TTL is 5 min on a 1 min interval (`application.ex:94-95`), so the
window closes by itself — but ~10 000 small POSTs/min from one client sustains
it indefinitely, and because these ids have no in-flight request, `clear/2` never
runs to reclaim them.

**Why it matters:** victims lose the ability to cancel long-running tool calls,
which is the only control MCP gives a client over a tool that is burning CPU or
upstream model tokens. The attacker needs no credential.

**Minimal fix:** never let the global cap deny a scope that is under its own
quota. Check `scope_at_capacity?/1` first, and when `at_capacity?/0` fires,
evict rather than refuse — the table is an `ordered_set`, so deleting the oldest
`"cancelled_at"` row from the largest scope is cheap — then insert. Failing
that, derive the global cap from the observed scope count so it can never bind
before the per-scope quota does.

---

### WARNING — `validate_key_provider!/1` does not check `fetch_key/2`, the callback every real token actually uses
`lib/conduit_mcp/optional_deps.ex:85` (validator), `lib/conduit_mcp/plugs/oauth.ex:242` (unvalidated call site) · NEW

`ConduitMcp.OAuth.KeyProvider` declares **two** required callbacks —
`fetch_keys/1` at `key_provider.ex:57` and `fetch_key/2` at
`key_provider.ex:62-63`. The validator tests only `fetch_keys/1`.
`fetch_signing_key/2` dispatches on `kid`:

```elixir
if kid do
  opts.key_provider.fetch_key(kid, opts.key_provider_config)   # never validated
else
  case opts.key_provider.fetch_keys(opts.key_provider_config) do   # validated
```

A custom provider implementing only `fetch_keys/1` passes `init/1` cleanly and
then raises `UndefinedFunctionError` on the **first token carrying a `kid`
header** — which is every token from a real JWKS-publishing authorization
server. That is precisely the failure this module exists to prevent; its own
`@doc` says so at `optional_deps.ex:67-69`: *"dispatch is unguarded, so without
this an absent JWKS provider surfaces as an `UndefinedFunctionError` on the
first authenticated request."*

**Why it matters:** the boot-time gate RC1 added silently misses the common
branch, so the consumer sees a 500 on every authenticated request instead of an
`ArgumentError` at `init/1` naming the missing callback. It fails closed — no
`conn` is returned, so no unauthenticated request proceeds — which is why this
is a WARNING and not a blocker.

**Minimal fix:** one more clause in the existing `cond`:

```elixir
not function_exported?(mod, :fetch_key, 2) ->
  raise ArgumentError,
        "OAuth :key_provider #{inspect(mod)} does not export fetch_key/2. " <>
          "Key providers must implement the ConduitMcp.OAuth.KeyProvider behaviour."
```

---

### WARNING — the bare-consumer path guard blocks `"` and `\` but not `#{`, so the checkout path can still inject Elixir into the generated `mix.exs`
`.github/scripts/bare_consumer_check.sh:49` · NEW

```sh
if printf '%s' "$REPO_ROOT" | grep -q '["\\]'; then
```

The round-1 fix is otherwise complete, and I checked every remaining expansion:
the heredoc is quoted (`<<'EOF'`, line 44), every parameter expansion in the
file is double-quoted, the `trap` is single-quoted so `$WORKDIR` expands at trap
time (line 17), and the `sed` replacement escapes `&`, `/` and `|` (lines
53-54). With `\` already rejected by the guard, no replacement metacharacter
survives — `\n`, `\1` and `&` are all covered. A newline in the path makes `sed`
abort under `set -euo pipefail` rather than inject.

What the guard misses is that the substitution target sits inside an **Elixir
double-quoted string** (line 37 of the script):

```elixir
deps: [{:conduit_mcp, path: "@REPO_ROOT@"}]
```

`#{...}` is interpolation and needs neither a quote nor a backslash. A checkout
at `/tmp/#{File.write!("/tmp/pwn","x")}` — a legal directory name on Linux and
macOS — produces a `mix.exs` that evaluates that expression the moment
`mix deps.get` compiles it. That is the exact outcome the comment at lines 24-26
claims is impossible: *"a checkout path containing a quote cannot inject code
into the generated mix.exs (which the following `mix deps.get` would then
execute)."*

**Why it matters:** `$REPO_ROOT` is CI-controlled today, so this is not presently
exploitable — but the guard is the stated security boundary of the script and it
is one character short of holding. Anyone invoking the script locally with a
path argument inherits the gap.

**Minimal fix:** add `#` to the rejected class and to the message:

```sh
if printf '%s' "$REPO_ROOT" | grep -q '["\\#]'; then
  echo "refusing to run: checkout path contains a quote, backslash or '#': $REPO_ROOT" >&2
```

---

### SUGGESTION — `Reflect`'s bidi strip misses U+061C (ALM), the one Trojan-Source control outside its ranges
`lib/conduit_mcp/reflect.ex:36` · NEW

```elixir
@control_chars ~r/[\x00-\x1F\x7F-\x9F\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2066}-\x{2069}]/u
```

The set covers C0, DEL/C1 (so U+0085 NEL is caught), ZWSP–RLM, LS/PS, LRE–RLO
and LRI–PDI. The Unicode `Bidi_Control` set also contains **U+061C ARABIC LETTER
MARK**, which has the same log-reordering effect as U+200F RLM two ranges above
it. U+2060 (word joiner) and U+FEFF (ZWNBSP/BOM) are likewise invisible format
characters that survive.

Everything else on this surface is sound; I could not defeat it:

- **Unbounded output** — no. `binary_slice(0, max * @bytes_per_codepoint)` at
  `reflect.ex:69` caps the value at 800 bytes for the default `max` *before*
  either the regex or the grapheme walk runs, so a 400 000-combining-mark bomb,
  a 1 MB method name, and the `printable_limit`-free `inspect/2` at
  `reflect.ex:87` are all bounded.
- **Terminal escape** — no. ESC is `\x1B`, inside `\x00-\x1F`; 8-bit CSI is
  U+009B, inside `\x7F-\x9F`.
- **Log-line forging** — no. `\n`, `\r`, U+0085, U+2028 and U+2029 are all
  stripped, and nothing is appended after `String.slice/3` at `reflect.ex:78`.
- **Overlong UTF-8, lone surrogates, or a codepoint bisected by the byte clamp**
  — no. `String.replace_invalid("")` at `reflect.ex:76` runs before the `/u`
  regex at `:77`, so `:re` never sees invalid UTF-8. This was the round-1 P0 and
  it is genuinely fixed.

**Why it matters:** an operator reading
`Logger.warning("Authentication failed: #{ConduitMcp.Reflect.text(reason)}")`
(`plugs/auth.ex:227`) can still be shown a line whose rendered order differs
from the bytes logged. Narrow, but making that impossible is the module's stated
purpose.

**Minimal fix:** extend the class:

```elixir
@control_chars ~r/[\x00-\x1F\x7F-\x9F\x{061C}\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}\x{2066}-\x{2069}\x{FEFF}]/u
```

---

### SUGGESTION — `Principal.derive_id/1` does not namespace by source, so two record types sharing a primary key become one principal
`lib/conduit_mcp/principal.ex:125-129` · NEW

`resolve_subject/2` was hardened to namespace by the producing claim
(`plugs/oauth.ex:382-394`) with an explicit rationale at `oauth.ex:375-381`:
without a prefix, two different claims yielding the same scalar alias onto one
identity. `derive_id/1` — the sibling used by `Plugs.Auth`'s
`:function`/`:custom` strategies via `build_principal/3` (`plugs/auth.ex:212`)
— applies no namespace at all:

```elixir
def derive_id(%{id: id}), do: scalar(id)
```

A `:verify` function that can return more than one record type — the ordinary
multi-tenant shape, e.g. `%MyApp.User{id: 42}` for a human and
`%MyApp.ApiClient{id: 42}` for a service account, each with its own integer
primary-key sequence — yields `"42"` for both. `ConduitMcp.Tasks` ownership is an
exact string compare on that value, so the service account reads and cancels the
human's tasks.

On the question as posed: an application shape **cannot** collide with an
OAuth-derived id, because every OAuth id now carries a `"<claim>:"` prefix and
the application value would have to be the literal string `"sub:alice"`. The
prefix does its job. The collision is *within* the `derive_id/1` space.

**Why it matters:** it is the same class of defect RC5/RC7 just closed on the
OAuth side, left open on the path where the shape is least predictable — the
consumer's own callback.

**Minimal fix:** namespace the struct case, the only one where a type is
available:

```elixir
def derive_id(%struct{id: id}), do: prefix(inspect(struct), scalar(id))
```

Or, if the id format is frozen for this release, state at `principal.ex:32-34`
that a `:function` verifier returning heterogeneous types must namespace `:id`
itself.

## Clean surfaces

Stated explicitly rather than omitted, as required.

- **`plugs/oauth.ex` — `resolve_subject/2` collisions.** No reachable collision.
  `claim <> ":" <> value` can only alias when one *configured claim name* equals
  another followed by `":"` plus a prefix of its value (e.g.
  `subject_claims: ["sub", "sub:tenant"]`); a colon inside a `sub` **value** is
  harmless, because `"sub:client_id:x"` is still distinct from `"client_id:x"`,
  and a URI-shaped custom claim such as `"https://acme.com/uid"` is not a prefix
  of `"sub"`. Residual: `scalar_claim/1` (`oauth.ex:396-398`) still conflates
  integer `1` with string `"1"` *within a single claim* — issuer-controlled, and
  the issuer is trusted, so not a finding.
- **`plugs/oauth.ex` — algorithm confusion.** No bypass.
  `check_alg_allowed/2` (`:252-260`) allow-lists before any key is fetched, and
  rejects a missing or non-binary `alg`, so `alg: "none"` never reaches a signer.
  HS algorithms enter `opts.algorithms` only via an explicit `:algorithms` list
  or a Static provider holding an `oct` key (`static_hs_algorithms/2`,
  `:121-130`). The classic RSA-public-key-as-HMAC-secret attack fails twice:
  `HS256` is not in the default list, and `resolve_signer_alg/2` (`:412-441`)
  requires the key's own `"alg"` to match the header exactly, or the header alg
  to fall inside the key's `kty` family — an `%{"kty" => "RSA"}` key with
  `HS256` falls to the `kty` catch-all at `:430` and returns `:alg_mismatch`.
- **`plugs/oauth.ex` — `validate_claims/2`** (`:321-368`). `exp` is mandatory and
  must be an integer (the catch-all clause returns `{:error, :expired}`), a
  present-but-malformed `nbf` is rejected rather than ignored, `iss` is an exact
  pin, and `aud` is exact-or-member-of-list. `header_safe/1` (`:519-521`) strips
  CR, LF and `"` from both `WWW-Authenticate` headers, so neither the config nor
  the scope list can split a header.
- **`cancellation.ex` — `scope/1` forgeability** (`:123-125`). Not forgeable by a
  client controlling `mcp-session-id`. `conn.private[:mcp_session_id]` is set
  only after `validate_session_header/2` confirms the id exists in the store
  (`transport/streamable_http.ex:120-165`); an unknown id is a halted 404, so a
  client cannot assert an arbitrary scope, and ids are 24 bytes of
  `:crypto.strong_rand_bytes` (`session.ex:29`). Omitting the header drops the
  caller to `Principal.id/1` — always `"<claim>:"`-namespaced under OAuth — or
  to the client IP, the residual already documented at `cancellation.ex:45-51`.
- **`transport/shared.ex` — pipeline order and CORS.** Nothing authenticates
  before `OriginValidation`: the generated pipeline is `Plug.Logger`,
  `SecurityHeaders`, `OriginValidation`, `:add_cors_headers`, `:match`,
  `Plug.Parsers`, `:authenticate`, `:rate_limit`, `:message_rate_limit`
  (`shared.ex:72-80`). `validate_cors_origin!/1` (`:192-199`) rejects a
  non-binary at boot; `add_cors_headers/1` (`:302-325`) emits nothing when
  `:cors_origin` is unset, so the `ACAO: *` + `options _` cross-origin read
  primitive is gone; and `warn_if_origins_unset/2` (`:257-270`) only warns —
  the actual decision is `OriginValidation.origin_allowed?(nil, _) -> false`,
  which fails closed.
- **`/.well-known/oauth-protected-resource` is unauthenticated by design and
  leaks nothing.** The skip at `shared.ex:339` is required by RFC 9728, and
  `ResourceMetadata.build/1` (`oauth/resource_metadata.ex:25-42`) allow-lists
  exactly four derived fields — `resource`, `authorization_servers`,
  `bearer_methods_supported`, and `scopes_supported` when non-empty. It never
  echoes `:key_provider`, so a Static provider's `oct` secret cannot reach the
  wire; non-`:oauth` configs get a 404. The match is on `conn.path_info`, which
  Plug has already split and percent-decoded without resolving `..`, so
  `//.well-known//oauth-protected-resource` reaches the same route it skips auth
  for, and `/.well-known/oauth-protected-resource/../x` does not match at all.

## Summary
0 BLOCKER · 5 WARNING · 2 SUGGESTION

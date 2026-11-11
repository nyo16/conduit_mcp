---
module: "ConduitMcp.Plugs.OAuth"
date: "2026-11-10"
problem_type: security_issue
component: authentication
symptoms:
  - "** (CaseClauseError) no case clause matching: ... raised from Joken.Signer.create(\"RS256\", key) in the OAuth plug"
  - "a Static (or custom) key provider holding a private RSA JWK with a malformed `p` crashes the request instead of verifying or returning 401"
root_cause: "jose parses every private member of an RSA JWK (d, p, q, dp, dq, qi) when building a signer, raising non-Joken errors on malformed ones, and the plug passed provider keys to Joken unstripped (only the JWKS provider stripped them)"
severity: medium
tags: [jose, joken, jwk, private-key, oauth, key-provider, signer, cve]
---

# jose crashes on a malformed private JWK member the verifier never needs

## Symptoms

A key provider that returns a full private RSA JWK (common with Static keys
copied from a signing setup) whose `p` is malformed crashes the request process:
`CaseClauseError` from jose. `create_signer/2` only rescues `Joken.Error`.

## Investigation

I probed `Joken.Signer.create("RS256", key)` and then verified a token for four
variants of the key:

| variant | result |
|---|---|
| full private | verifies |
| bad `d` | verifies (jose ignores it for verification) |
| `d` only, no CRT values | verifies, but jose factors `n` on parse: EEF-CVE-2026-65631 |
| bad `p` | **raises `CaseClauseError`** |

## Root Cause

A verifier needs only the public members, but jose parses whatever the map
holds. The JWKS provider already dropped `d p q dp dq qi oth` before caching.
Static and custom providers bypassed that, because stripping lived in
`JWKS.decode_jwks/2` and not on the plug's path.

## Solution

Move the stripping to `ConduitMcp.OAuth.KeyProvider.public_key/1` (unguarded:
plain map ops). Apply it in the plug to every provider's key before
`create_signer/2`. Leave `oct` untouched: its `k` is the HMAC secret.

```elixir
@private_members ~w(d p q dp dq qi oth)

def public_key(%{"kty" => kty} = key) when kty in ["RSA", "EC", "OKP"],
  do: Map.drop(key, @private_members)

def public_key(key), do: key
```

```elixir
# Plugs.OAuth.fetch_signing_key/2
{:ok, key} when is_map(key) -> {:ok, KeyProvider.public_key(key)}
```

Red test: Static provider with `Map.put(private_rsa_jwk, "p", "!!")` now verifies.

### Files Changed

- `lib/conduit_mcp/oauth/key_provider.ex`: `public_key/1`
- `lib/conduit_mcp/oauth/key_provider/jwks.ex`: uses it
- `lib/conduit_mcp/plugs/oauth.ex` `fetch_signing_key/2`: uses it
- `test/conduit_mcp/plugs/oauth_test.exs`: end-to-end and per-kty tests

## Prevention

- Sanitize keys at the consumer (the plug), not at one producer: a behaviour
  with user-implemented providers has no single choke point upstream.
- When rescuing a library's errors, remember that its dependencies (jose under
  Joken) raise their own exception types.

## Related

- `.claude/solutions/joken-oct-key-binary-secret.md`: HS signers need the decoded `k`, which is why `oct` keys are not stripped

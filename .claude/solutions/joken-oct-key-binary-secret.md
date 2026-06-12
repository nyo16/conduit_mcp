---
problem: HS (HMAC) JWT verification crashes with Joken.Error
component: oauth
symptoms: ["Couldn't create a signer because key is not binary", HS256 tokens crash request process]
root_cause: oct JWK map passed to Joken.Signer.create/2, which needs the raw binary secret for HS algs
solution: Base.url_decode64!(jwk["k"], padding: false) before creating the signer
date: 2026-06-11
---

# Joken HS signers need the binary secret, not the oct JWK map

`Joken.Signer.create("HS256", %{"kty" => "oct", "k" => ...})` raises
`Joken.Error` — for HMAC algorithms Joken requires the raw binary secret.
Asymmetric algorithms (RS/ES/PS) accept the JWK map directly.

**Fix** (`plugs/oauth.ex` `create_signer/2`): for `kty: "oct"` keys, decode
`"k"` with `Base.url_decode64(k, padding: false)` and pass the binary. Also
rescue `Joken.Error` so a malformed key from a misconfigured provider yields
a 401 instead of crashing the Bandit request process.

**How it was found**: writing the first-ever HS-path test. The path had
zero coverage and had never worked — a reminder that "supported" code
without a test may be broken from day one.

Related: to set `kid` in a test token's header, pass it to
`Joken.Signer.create(alg, key, %{"kid" => ...})` (3rd arg) — NOT as a third
argument to `Joken.encode_and_sign/3` (that's hooks/options).

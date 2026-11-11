# Security review: hardening/0.11.1 (uncommitted diff against `master`)

**Verdict: PASS WITH WARNINGS.** I found no blocker. SEC-H1 is complete on every path that sends credentials. One regression is new: moving the parser behind auth lets Bandit drain up to 8 MB of an unauthenticated body. One SEC-M5 gap remains: the Hex key is still a repository secret.

Scope: SEC-H1, SEC-M1, SEC-M2/C1 (transport pipeline), D2 (JWKS), T1 (`validate_claims/2`), SEC-M5/SEC-L3/D6/D7/D8 (CI, `release.sh`). I read the diffs in `reviews/.lib.diff` and the code they touch. I also read the Bandit 1.14.1 sources in `deps/bandit` to check how a body is read and drained. Nothing was run.

---

## BLOCKER

None.

---

## WARNING

### W1. On HTTP/1.1 keep-alive, a request rejected before parsing still has its body read, up to Bandit's 8 MB default (was 1 MB)

- **Where:** `lib/conduit_mcp/transport/shared.ex:112-120` (plug order). The rejection responses come from `Plugs.Auth`, `Plugs.OAuth` and `Plugs.RateLimit`. The draining is Bandit's: `deps/bandit/lib/bandit/pipeline.ex:228-229` and `deps/bandit/lib/bandit/http1/socket.ex:871-874`, `:436-440`.
- **What is wrong:** the change keeps the server from decoding JSON for a rejected request, but on a real HTTP/1.1 socket it does not keep the server from reading the body. Once the plug has answered 401 or 429, Bandit's `commit_response!` calls `ensure_completed`. For a keep-alive connection whose body is unread, that does:
  ```elixir
  def ensure_completed(%@for{} = socket) do
    case read_data(socket, []) do          # no :length → default 8_000_000
      {:ok, _data, socket} -> socket
      {:more, _data, _socket} -> request_error!("Unable to read remaining data in request body")
  ```
  ```elixir
  bytes_to_return = min(unread_content_length, Keyword.get(opts, :length, 8_000_000))
  ...
  read_exactly!(socket, buffer, bytes_to_return, read_size, read_timeout)   # accumulates iodata
  ```
  - **Before this change:** `Plug.Parsers` read at most `length: 1_000_000` and then raised `RequestTooLargeError`. Bandit's error path closes the connection, so an unauthenticated request could make the server hold at most about 1 MB.
  - **Now:** an unauthenticated client sends `Content-Length: 7_999_999` with a bad token. It gets a 401 right away, and its handler process then reads and buffers the full ~8 MB, waiting up to `read_timeout` (15 s) per `recv`. That is up to 8× more memory per connection, before authentication, across as many connections as the attacker opens. (Chunked bodies go through the same `read_data(socket, [])` path.)
  - HTTP/2 is not affected: `Stream.ensure_completed/1` only drains frames already in the mailbox.
- **Why the tests and measurements miss it:** the plan's 3.4 timing uses `Plug.Test`, which never drains. `body_limit_test.exs` only covers the authenticated 413 path. The CHANGELOG and `Shared`'s moduledoc both say a rejected request "costs no body read", which is true only under `Plug.Test` and over HTTP/2.
- **Fix:** close the connection when a pre-parse plug answers while the body is still unread. Put a `register_before_send` at the top of the pipeline, ahead of `:rate_limit_before_auth`:
  ```elixir
  plug(:close_if_body_unread)

  defp close_if_body_unread(conn, _opts) do
    Plug.Conn.register_before_send(conn, fn
      %Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn ->
        if body_expected?(conn), do: Plug.Conn.put_resp_header(conn, "connection", "close"), else: conn
      conn -> conn
    end)
  end
  # body_expected?: content-length > 0, or a transfer-encoding header present
  ```
  Bandit's `handle_keepalive/3` (`socket.ex:791-804`) honours a response `connection: close` by setting `keepalive: false`, and `ensure_completed(%{keepalive: false})` skips the drain. Add an `:integration` case next to `body_limit_test.exs`:
  - bearer auth configured, a wrong token, a body of 2 × `max_body_bytes` over `:gen_tcp`;
  - assert 401 with `connection: close`;
  - assert the socket is closed without the server reading the whole body. Bounding the body that is read is enough; there is no need to time it.

  Then correct the "costs no body read" wording in `shared.ex` (moduledoc "Pipeline order"), `streamable_http.ex` (`:max_body_bytes`) and the CHANGELOG.

### W2. SEC-M5 is incomplete while `HEX_API_KEY` is a repository secret: `environment: hex-release` does not protect it

- **Where:** `.github/workflows/ci.yml:263` and `:294` (`HEX_API_KEY: ${{ secrets.HEX_API_KEY }}`). The plan's "For the user" section (lines 481-482) and the CHANGELOG (lines 109-111) mention only reviewers and the tag ruleset.
- **What is wrong:** environment protection rules (required reviewers, deployment tag rules) only gate *environment* secrets.
  - If `HEX_API_KEY` stays a repository secret, it is available to any job, in any workflow, that names `secrets.HEX_API_KEY`.
  - So anyone who can push a branch can run a job with no `environment:` that sends the key elsewhere. This includes pushing a modified `.github/workflows/*.yml` and same-repository `pull_request` runs. No `v*` tag and no reviewer is involved.
  - The comment on line 261 ("Required reviewers and the `v*` tag ruleset are repository settings; without them this line protects nothing") names the wrong precondition: the binding precondition is where the secret lives.
- **Fix (repository settings, so for the user):**
  - Create `HEX_API_KEY` as a secret of the `hex-release` environment and delete the repository-level secret.
  - Restrict the environment's deployment branches/tags to `v*`.
  - Extend the workflow comment, the plan's "For the user" list and the CHANGELOG line to say so. The workflow YAML needs no change.

---

## SUGGESTION

### S1. D2 stripping covers only the built-in JWKS provider. `Static` and custom `KeyProvider`s still pass private members to `JOSE.JWK.from_map/1`

- **Where:** `lib/conduit_mcp/oauth/key_provider/jwks.ex:447-450` strips the members. The key is parsed at `lib/conduit_mcp/plugs/oauth.ex:338-339`:
  ```elixir
  defp create_signer(alg, key_map) do
    {:ok, Joken.Signer.create(alg, key_map)}
  ```
- **What is wrong:** the `ConduitMcp.OAuth.KeyProvider` moduledoc example (`key_provider.ex:20-40`) fetches the upstream JWKS through Redix and returns those keys unstripped. The jose `>= 1.11.13` floor is the actual fix for EEF-CVE-2026-65631, so this is defence in depth only.
- **Fix:** apply `public_only/1` in the plug, in `verify_and_validate/4` before `resolve_signer_alg/2`, for keys whose `kty` is RSA, EC or OKP. Every provider is then covered. Keep or drop the copy in `decode_jwks/2`.

### S2. SEC-H1 can be bypassed by building the struct by hand. `OAuth.Config.new/1` returns any `%Config{}` unchanged

- **Where:** `lib/conduit_mcp/client/oauth/config.ex:332`; `client/transport/streamable_http.ex:319-320` and `:1141` accept `{:oauth, %OAuth.Config{}}` as given.
  ```elixir
  def new(%__MODULE__{} = config), do: {:ok, config}
  ```
- **What is wrong:** a host that writes `%ConduitMcp.Client.OAuth.Config{grant: :client_credentials, credentials: %{...}, expected_issuers: nil}` gets the 0.11.0 behaviour. It has to build the internal `credentials` map itself, so this is unlikely.
- **Fix:** in `new(%__MODULE__{})`, re-check `grant == :client_credentials and expected_issuers in [nil, []]` and return the same error. It is cheap and runs at config time only.

### S3. SEC-M1 leftover: `OAuth.Config.new/1` still inspects the whole options term

- **Where:** `lib/conduit_mcp/client/oauth/config.ex:342`
  ```elixir
  def new(other), do: {:error, "expected OAuth options as a keyword list, got: #{inspect(other)}"}
  ```
- **What is wrong:** this is reachable only when a host calls `OAuth.Config.new/1` or `new!/1` directly with a non-list, for example a map holding `client_secret: "..."`. The transports and the `ConduitMcp.Client.OAuth` facade guard with `is_list/1` first. It is the one remaining whole-term `inspect` among the client config error paths. The others print scalars (`protocol`, `handler`, `client_info`, `policy`, `hooks`, `url`).
- **Fix:** `"... got #{ConduitMcp.Client.Config.describe(other)}"`.

### S4. `Hub.Manager.format_status/1` leaves `:log` (and `:reason`) untouched

- **Where:** `lib/conduit_mcp/client/hub/manager.ex` (the new `format_status/1`).
- **What is wrong:** with `:sys` debugging on (`debug: [:log]`, or `:sys.log/2`), the `:log` entries keep `{:in, {:"$gen_call", _, {:add, id, client_config}}}` unredacted. This is rare and opt-in. Also, `Map.update(status, :message, nil, ...)` inserts `message: nil` into `:sys.get_status/1` maps. OTP ignores the extra key, so that part is harmless.
- **Fix:** add
  ```elixir
  |> Map.update(:log, [], fn log -> Enum.map(log, &redact_log/1) end)
  ```
  and use `Map.replace_lazy/3` (or `if Map.has_key?`) instead of `Map.update/4` with a `nil` default.

### S5. `before_auth: true` with a `key_func` that keys on caller-asserted identity is a targeted lockout

- **Where:** `lib/conduit_mcp/plugs/rate_limit.ex`, "Failed authentications" section of the moduledoc.
- **What is wrong:** before authentication, any identity the client asserts is unverified: a header, a token's `sub`, an API-key prefix. If a host's `key_func` keys on one, an unauthenticated attacker can send a victim's identifier and exhaust the victim's bucket. The default `Principal.rate_limit_key/1` falls back to the client bucket and is safe. The docs say per-user limits belong in `:message_rate_limit`, but they do not warn about this.
- **Fix:** add one sentence to the moduledoc and to `guides/rate_limiting.md`: with `before_auth: true`, `key_func` must key only on what the server observes (the address or bucket), never on caller-supplied identity.

### S6. Publish job hygiene (SEC-M5/D8)

- **Where:** `.github/workflows/ci.yml:264-294`.
- **`persist-credentials: false`:** add it to the `actions/checkout` step in `publish` (and in `audit.yml`). The checkout otherwise leaves `GITHUB_TOKEN` in `.git/config` while `mix deps.get`, `mix compile` and `mix hex.publish` run third-party code. The token is read-only (`permissions: contents: read`), so this is low impact.
- **Check the tag's commit:** the job does not verify that the tagged commit is on `master`, so a `v*` tag on any pushed commit publishes once CI is green. The tag ruleset in W2 is the main control. As a backstop, use `fetch-depth: 0` and add `git merge-base --is-ancestor "$GITHUB_SHA" origin/master || exit 1`.
- **The tag comparison itself is safe:**
  - `GITHUB_REF` is expanded as a shell variable inside double quotes, never as a `${{ }}` expression, so there is no script injection.
  - Expanded text is not re-evaluated, so a tag containing `$(...)` is inert.
  - The `echo` line starts with `Tag v`, so GitHub cannot read it as a `::` workflow command.
  - No tag text is written into `mix.exs`. SEC-L3 is fixed.

### S7. `scripts/release.sh` could print a remote URL with credentials in it

- **Where:** `scripts/release.sh`, the `REPO_URL=$(git remote get-url origin | sed ...)` line.
- **What is wrong:** a remote of the form `https://user:token@github.com/...` is echoed to the terminal with the token. Cosmetic otherwise; `ssh://` remotes print a wrong URL.
- **Fix:** add `s#^https://[^@/]*@#https://#` to the `sed`. D7 is otherwise fixed: `hex.publish` is gone, the pre-checks and tag rollback are kept, and `VERSION` is read from one quoted line.

---

## What I checked and found correct

- **SEC-H1, every path that sends credentials.**
  - `credentials/1` (`oauth/config.ex:385-399`) rejects `expected_issuers` `nil` and `[]` for `:client_credentials` after the `auth_method == :none` check. The message names the key and carries no values.
  - Every token-endpoint call uses `context.metadata["token_endpoint"]` (`client_credentials.ex:74`, `session.ex:267`). `context` is set only by `Session.ensure_context/2` → `Fetch.discover/2` → `Discovery.select_issuer(prm, expected_issuers: config.expected_issuers)` (`fetch.ex:59`).
  - Every context reset re-runs that same discovery: `oauth.ex:131` (`authorize_url`) and `connection/authorize.ex:205` (fresh check).
  - Step-up (`session.ex:165`), refresh (`:199`), `token/2` (`:182`), `check/2` (`:134`), the `invalid_grant` fallback (`:238-242`) and the private-key assertion (`aud` = the same `token_endpoint`) all reuse that context.
  - `set_auth/3` goes through `Credential.replace` → `validate_options` → `OAuth.Config.new`, so the check runs there too.
  - The hub builds each server through `Client.Config.new!`, so the check applies to hub servers as well.
  - The tests assert `:issuer_not_allowed` and zero `POST /token` on the attacker's fake.
- **SEC-M1.**
  - `validate_env/1` and `validate_headers/1` wrap values in `Secret`. `Secret.new/1` is idempotent, so re-validation on `set_auth` is safe.
  - Values are exposed only at the wire: `client/http.ex:150`, `oauth/http.ex:124` and `Stdio.child_env/3:513`.
  - No reader JSON-encodes or logs validated headers or env. `JSON.encode!` call sites in `lib/conduit_mcp/client` take message, schema or argument terms only.
  - `exchange.ex` `spec_header/2` reads response headers only.
  - `@derive {Inspect, except: [:transport]}` and `except: [:servers]` cover the `Client`, `Connection` and hub child-spec start arguments, all of which are `%Config{}`.
  - `describe/1` never prints contents.
- **Transport pipeline.**
  - Nothing between `:match` and `:parse_body` reads params. The only readers are `HeaderValidation`, `MessageRateLimit`, `classify_era` helpers and dispatch, all after the parser.
  - `Plugs.Auth` passes only the token to `:verify`, and `resolve_auth_plug` admits only `Auth` and `OAuth`, so no auth code sees `Unfetched` params.
  - With `before_auth`, exactly one limiter position is active. The value is validated as a boolean, and `Endpoint` passes the key through (`endpoint.ex:134`).
  - `body_parsers/1` is validated at init.
  - Bandit 1.14.1's HTTP/1 Content-Length and chunked reads, and its HTTP/2 `do_read_data`, return `{:ok, _}` only when the body fits within `:length`. Otherwise they return `{:more, _}`, which becomes a 413, so `:max_body_bytes` cannot be bypassed. (A `{:more, acc}` may overshoot `:length` by one frame; that does not matter here.)
- **D2:** `public_only/1` runs on the only JWKS ingestion path (`do_fetch` → `decode_jwks`). The stale-key fallback serves only keys that were already cached, and so already stripped.
- **T1:** `validate_claims/2` is now public, `@doc false` and claims-only. Joken's signature verification still runs before it on the request path, so making it public adds no bypass.
- **CI:** every `uses:` is pinned to a SHA (provenance is recorded in the scratchpad, lines 140-142; I did not re-resolve them). `audit.yml` has `permissions: contents: read`, uses no cache and no secrets. `dependabot.yml` covers `github-actions`.

## PRE-EXISTING (not introduced here)

- `lib/conduit_mcp/client/transport/streamable_http.ex:1055,1068`: `validate_url/1` inspects the whole URL on scheme and `URLPolicy` errors, so a secret in a query string (`?api_key=`) reaches the error message.
- `lib/conduit_mcp/transport/shared.ex:514`: when a host mounts the transport behind Phoenix's own `Plug.Parsers`, the body is already parsed. `:max_body_bytes` and the parse-after-auth ordering then do not apply. Worth one sentence in the `:max_body_bytes` docs.
- `lib/conduit_mcp/plugs/oauth.ex:166-170`: a host that sets `algorithms:` to include `HS*` with a JWKS provider would accept a published `oct` key as an HMAC secret. This is opt-in misconfiguration, and the defaults exclude HS for JWKS.

## Checks for Main to consider

- After W1: an `:integration` test that a wrong-token POST with a body of 2 × `max_body_bytes` gets `connection: close` and a closed socket, on both transports.
- W2 needs the user's repository settings: move `HEX_API_KEY` to the `hex-release` environment, then delete the repository secret.

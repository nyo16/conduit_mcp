# Client OAuth

MCP servers reached over Streamable HTTP may require OAuth 2.1 (the MCP
authorization spec, both protocol eras). `ConduitMcp.Client` handles the
protocol side of that: discovery, client registration, PKCE, token requests,
refresh, step-up and attaching the bearer token. Your application handles
the parts that involve a person: sending the user to the authorization
server, receiving the redirect, and storing what has to survive between the
two.

```elixir
{ConduitMcp.Client,
 name: :docs,
 transport:
   {ConduitMcp.Client.Transport.StreamableHTTP,
    url: "https://mcp.example.com/mcp",
    auth:
      {:oauth,
       redirect_uri: "https://app.example.com/oauth/mcp/callback",
       client_metadata_url: "https://app.example.com/oauth/client.json",
       on_authorization_required: &MyApp.MCPAuth.required/1}}}
```

The OAuth modules need the optional `:finch` dependency, which the Streamable
HTTP transport needs anyway. `private_key_jwt` client authentication also
needs `:jose`. Each is checked when the options are validated, so a missing
dependency raises at boot. OAuth is not available over stdio, and servers
without Protected Resource Metadata (the 2025-03-26 fallback) are not
supported.

For the client in general see [client.md](client.md). For the server side
of OAuth (protecting your own MCP server) see
[authentication.md](authentication.md).

## What the client does on its own

- **Sends the bearer token** on every request to the MCP server, including
  `server/discover`, and only to it. Metadata, registration and token
  requests never carry it. Redirects are refused unless the transport has
  `redirect: :same_origin`, which follows them only to the same origin.
- **Refreshes** an access token that expires within `refresh_skew` seconds
  before sending it, and again after a 401. Refreshes are single-flight
  across every process sharing the token store, and rotated refresh tokens
  are stored before the lock is released.
- **Discovers the authorization server**: Protected Resource Metadata
  (RFC 9728) from the challenge's `resource_metadata` URL or the well-known
  URLs, then the authorization server's metadata (RFC 8414 / OpenID Connect
  Discovery). See `ConduitMcp.Client.OAuth.Discovery.Fetch`.
- **Chooses a client identity**: pre-registered, a Client ID Metadata
  Document, or dynamic registration (see "Client registration").
- **Steps up** on a 403 `insufficient_scope` (see "Step-up").

The client never opens a browser and never blocks a request waiting for a
person.

## Options

`auth: {:oauth, opts}` on `ConduitMcp.Client.Transport.StreamableHTTP`.
The options are validated into a `ConduitMcp.Client.OAuth.Config` when the
client's child spec is built, so a bad option raises an `ArgumentError`
naming it. The transport fills in `:server_url` from its `:url`.

| Option | Default | Meaning |
|---|---|---|
| `:redirect_uri` | `nil` | Where the authorization server sends the user back: `https`, or `http` on a loopback host (RFC 8252); no fragment. Needed for the interactive flow unless `authorize_url/2` or `Loopback` supplies one |
| `:client_metadata_url` | `nil` | The `https` URL, with a path, of your Client ID Metadata Document (CIMD). Used as the client id when the authorization server supports CIMD |
| `:client_metadata` | `[]` | Sent in a dynamic registration request: `:client_name`, `:application_type` (`:native` or `:web`; default `:native` for a loopback or custom-scheme redirect URI, else `:web`), `:client_uri`, `:logo_uri` |
| `:pre_registered` | `%{}` | Clients registered out of band: `%{issuer => [client_id: ..., client_secret: ..., ...]}`, keyed by the authorization server's exact `issuer` |
| `:store` | `nil` | The token store as `{module, opts}`. `nil`: an in-memory `ConduitMcp.Client.OAuth.TokenStore.ETS` started under the client's supervisor, or a hub's shared one |
| `:on_authorization_required` | `nil` | `fn challenge -> ... end`, called in a task with a `ConduitMcp.Client.OAuth.Challenge` when the user must authorize |
| `:max_step_up_attempts` | `2` | Step-up authorizations per resource and scope set |
| `:refresh_skew` | `30` | Seconds before expiry at which an access token is refreshed |
| `:expected_issuers` | `nil` | An allowlist of authorization-server issuers (exact strings). `nil` accepts the one the server names |
| `:principal` | `nil` | The user or tenant this client acts for. Part of every token-store key and of the identity private cached results are keyed by; switch with `ConduitMcp.Client.set_auth/3` (see "Private results and credentials" in [client.md](client.md)) |
| `:scopes` | `[]` | Scopes to request when neither the challenge nor the server's metadata names any |
| `:allow_insecure_oauth` | `false` | Development and tests: admit plain `http` metadata and authorization-server URLs on loopback hosts |
| `:allow_private` | `[]` | CIDRs the URL policy admits for OAuth requests although they are private |
| `:resolver` | `nil` | The DNS resolver the URL policy uses (tests) |
| `:transport_opts` | `[]` | TLS options for OAuth requests (Mint `:transport_opts`, for example `cacerts:`). Certificates are always verified: `verify:` other than `:verify_peer`, and `verify_fun:`, are refused |
| `:request_timeout` | `10_000` | Milliseconds for each OAuth HTTP request |
| `:clock` | `nil` | `fn -> unix_seconds end` (tests) |

The client-credentials options (`:client_id`, `:client_secret`,
`:private_key`, `:private_key_alg`, `:private_key_kid`,
`:token_endpoint_auth_method`) are covered in "Machine to machine".

## Interactive authorization

### What happens on a 401

When the server answers 401, the connection enters `:authorizing`
(`ConduitMcp.Client.status/1` reports `state: :authorizing`). A task runs
discovery and looks in the token store for a usable token: a newer one than
the server refused, or one it can refresh. If it finds one, the refused
request is sent again and the caller never sees the 401.

If there is none, the user must authorize:

1. The refused request, and any that were waiting, fail with
   `{:error, %ConduitMcp.Client.Error{kind: :auth, reason:
   :authorization_required, data: %{challenge: challenge}}}`.
2. `on_authorization_required` is called with the challenge, in a task
   under the client's `Task.Supervisor`, once per episode. A callback that
   raises is logged and otherwise ignored.
3. The connection stays in `:authorizing`. Every new request fails at once
   with `:authorization_required`; nothing waits for a person.

Every request that arrives in `:authorizing` first re-reads the store, so
tokens stored by any means are picked up by the next request.
`ConduitMcp.Client.authorized/1` triggers that check at once, and
`handle_callback/3` with `client:` calls it for you. Once tokens are found,
the connection finishes its handshake (or returns to `:ready`) without a
reconnect.

Other OAuth failures end the episode differently. Unreachable metadata,
registration or token endpoints (`:no_protected_resource_metadata`,
`:no_authorization_server_metadata`, `:registration_failed`,
`:token_request_failed`) make the client reconnect with backoff. Refusals
such as a `resource` mismatch, a missing `S256` or a blocked URL close the
connection with `kind: :auth` and that reason;
`ConduitMcp.Client.reconnect/1` tries again.

### The two steps

Interactive authorization is two calls with a redirect in between:

```elixir
# 1. Start: discovery, registration, PKCE and state.
{:ok, url, pending} = ConduitMcp.Client.OAuth.authorize_url(:docs, challenge: challenge)
# store `pending` server-side, keyed by its state, then send the user to `url`

# 2. The redirect arrives: take `pending` back (and delete it), then finish.
{:ok, tokens} = ConduitMcp.Client.OAuth.handle_callback(pending, params, client: :docs)
```

`authorize_url/2` always runs discovery again, so if the server has moved to
another authorization server since the client last looked, the new one is
used (and pre-registered credentials for the old one are not; see "Client
registration"). Its options:

- `:challenge` - the challenge the client reported. Its `resource_metadata`
  URL and `scope` are used.
- `:scopes` - the scopes to request. Default: the challenge's, else the
  server's `scopes_supported`, else the configured `:scopes`. When all are
  empty, no `scope` parameter is sent.
- `:redirect_uri` - overrides the configured one.
- `:principal` - the identity to bind the flow and its tokens to. Default:
  the configured `:principal`.

`handle_callback/3` validates the response before any token request (see
`ConduitMcp.Client.OAuth.Callback`): `state` in constant time, the
principal, the expiry, and the RFC 9207 `iss` parameter. It then redeems
the code with the same `redirect_uri`, `resource` and PKCE verifier, stores
the tokens under `{principal, issuer, resource}`, and with `client:` tells
the connection. Pass `config:` (a `ConduitMcp.Client.OAuth.Config`)
instead of `client:` to complete a flow without a running client; tokens
then reach a client only through a store they share.

`ConduitMcp.Client.OAuth.token_for/2` returns the current tokens for a
principal, refreshed first when they expire within `refresh_skew`, or
`:authorization_required`; a client-credentials configuration requests a
token instead. `ConduitMcp.Client.OAuth.refresh/2` refreshes now. Both are
single-flight. The first argument of `authorize_url/2`, `token_for/2` and
`refresh/2` may be a running client's name (its discovered context is
reused), a `ConduitMcp.Client.OAuth.Config`, or OAuth options including
`:server_url` (discovery runs on every call).

### Storing the pending authorization

`ConduitMcp.Client.OAuth.Pending` is plain data: the PKCE verifier,
`state`, the issuer, resource, redirect URI, scopes, client id, token
endpoint and principal. It expires after 10 minutes. `Pending.to_map/1`
turns it into a map of strings, integers, booleans and lists (and the
principal as given), and `Pending.from_map/1` validates one and restores
the struct.

Two rules:

- **The map holds secrets in plain text** (`state` and `code_verifier`).
  Keep it server-side, or encrypt it (`Plug.Crypto.encrypt/4`). Signing
  alone does not hide it.
- **`state` is single use, and enforcing that is your job.** `Pending` is
  data, so the library cannot see a second copy being presented. Look the
  entry up by `state` and delete it in the same step, before calling
  `handle_callback/3`, whether the callback then succeeds or fails.

A signed or encrypted cookie session does not give single use: the browser
can present an older cookie again. Prefer a database row or another
server-side store. If you JSON-encode the map, use a string principal.

### A Phoenix example

One client per user and server, with the user's id as the principal and a
persistent token store (see "Token stores"):

```elixir
defmodule MyApp.MCP do
  alias ConduitMcp.Client.Transport.StreamableHTTP

  def client(user_id, server), do: {__MODULE__, user_id, server}

  def start_client(user_id, "github") do
    DynamicSupervisor.start_child(MyApp.MCPClients, {ConduitMcp.Client,
     name: client(user_id, "github"),
     server_id: "github",
     transport:
       {StreamableHTTP,
        url: "https://mcp.github.example/mcp",
        finch: MyApp.MCPFinch,
        auth:
          {:oauth,
           principal: user_id,
           redirect_uri: "https://app.example.com/oauth/mcp/callback",
           client_metadata_url: "https://app.example.com/oauth/client.json",
           store: {MyApp.MCPTokenStore, []},
           on_authorization_required: &MyApp.MCPAuth.required(user_id, "github", &1)}}})
  end
end
```

`on_authorization_required` keeps the challenge (it carries step-up scopes)
and tells the user's UI to show a "Connect" link. The pending authorization
goes into a table keyed by a hash of `state`, encrypted:

```elixir
defmodule MyApp.MCPAuth do
  import Ecto.Query

  alias ConduitMcp.Client.OAuth.Pending
  alias MyApp.MCPAuth.PendingAuthorization
  alias MyApp.Repo

  @salt "mcp pending authorization"

  def required(user_id, server, challenge) do
    MyApp.MCPAuth.Challenges.put({user_id, server}, challenge)
    Phoenix.PubSub.broadcast(MyApp.PubSub, "user:#{user_id}", {:mcp_authorization_required, server})
  end

  def challenge(user_id, server), do: MyApp.MCPAuth.Challenges.get({user_id, server})

  def put_pending(server, %Pending{} = pending) do
    map = Pending.to_map(pending)

    Repo.insert!(%PendingAuthorization{
      state_hash: :crypto.hash(:sha256, map["state"]),
      server: server,
      data: Plug.Crypto.encrypt(secret(), @salt, map)
    })
  end

  # Delete-on-read: a second callback with the same state finds nothing.
  def take_pending(state) when is_binary(state) do
    hash = :crypto.hash(:sha256, state)
    query = from p in PendingAuthorization, where: p.state_hash == ^hash, select: p

    with {1, [row]} <- Repo.delete_all(query),
         {:ok, map} <- Plug.Crypto.decrypt(secret(), @salt, row.data, max_age: 600),
         {:ok, pending} <- Pending.from_map(map) do
      {:ok, row.server, pending}
    else
      _ -> {:error, :unknown_state}
    end
  end

  def take_pending(_state), do: {:error, :unknown_state}

  defp secret, do: MyAppWeb.Endpoint.config(:secret_key_base)
end
```

The controller starts the flow and finishes it. Both routes sit behind your
login pipeline, and `principal:` in the callback makes a response that was
started by another user fail with `:principal_mismatch`:

```elixir
defmodule MyAppWeb.MCPAuthController do
  use MyAppWeb, :controller

  alias ConduitMcp.Client.OAuth

  # GET /mcp/connect/:server
  def connect(conn, %{"server" => server}) do
    user_id = conn.assigns.current_user.id
    client = MyApp.MCP.client(user_id, server)

    case OAuth.authorize_url(client, challenge: MyApp.MCPAuth.challenge(user_id, server)) do
      {:ok, url, pending} ->
        MyApp.MCPAuth.put_pending(server, pending)
        redirect(conn, external: url)

      {:error, _error} ->
        conn
        |> put_flash(:error, "Could not start the authorization.")
        |> redirect(to: ~p"/settings/connections")
    end
  end

  # GET /oauth/mcp/callback
  def callback(conn, params) do
    user_id = conn.assigns.current_user.id

    with {:ok, server, pending} <- MyApp.MCPAuth.take_pending(params["state"]),
         {:ok, _tokens} <-
           OAuth.handle_callback(pending, params,
             client: MyApp.MCP.client(user_id, server),
             principal: user_id
           ) do
      conn |> put_flash(:info, "Connected.") |> redirect(to: ~p"/settings/connections")
    else
      _error ->
        conn
        |> put_flash(:error, "The authorization did not complete.")
        |> redirect(to: ~p"/settings/connections")
    end
  end
end
```

The `%ConduitMcp.Client.OAuth.Error{}` from `handle_callback/3` is safe to
log: its message never contains a token, code, `state` or verifier. Its
`:data` may hold the authorization server's `error_description`, which is
server text; do not render it as trusted.

Serve the Client ID Metadata Document at `:client_metadata_url` with
`ConduitMcp.Client.OAuth.CIMD.document/1`. Its `client_id` must be that URL,
and `redirect_uris` must list every redirect URI you use:

```elixir
# GET /oauth/client.json
def client_metadata(conn, _params) do
  json(conn, ConduitMcp.Client.OAuth.CIMD.document(
    client_id: "https://app.example.com/oauth/client.json",
    client_name: "My App",
    redirect_uris: ["https://app.example.com/oauth/mcp/callback"],
    application_type: :web,
    client_uri: "https://app.example.com"
  ))
end
```

The document always declares `grant_types: ["authorization_code",
"refresh_token"]`, `response_types: ["code"]` and
`token_endpoint_auth_method: "none"`. Other string-valued RFC 7591 fields
(`:logo_uri`, `:tos_uri`, `:policy_uri`, ...) are copied as given.

### CLI and desktop apps: Loopback

`ConduitMcp.Client.OAuth.Loopback.run/2` runs both steps with a one-shot
callback server on `127.0.0.1` (RFC 8252 loopback redirect). The library
never launches a browser; you pass `open:`, which receives the URL:

```elixir
cli = self()

{:ok, _pid} =
  ConduitMcp.Client.start_link(
    name: :docs,
    transport:
      {ConduitMcp.Client.Transport.StreamableHTTP,
       url: "https://mcp.example.com/mcp",
       auth:
         {:oauth,
          client_metadata_url: "https://cli.example.com/oauth/client.json",
          on_authorization_required: &send(cli, {:authorize, &1})}}
  )

receive do
  {:authorize, challenge} ->
    {:ok, _tokens} =
      ConduitMcp.Client.OAuth.Loopback.run(:docs,
        challenge: challenge,
        open: fn url ->
          IO.puts("Opening #{url}")
          System.cmd("open", [url])
        end
      )
after
  5_000 -> :already_authorized
end

:ok = ConduitMcp.Client.await_ready(:docs, 10_000)
```

`run/2` starts Bandit on the loopback address only (port `0`, any free
port, unless you give `:port`; path `:path`, default `"/callback"`), builds
the URL with redirect URI `http://127.0.0.1:<port><path>`, calls `open`,
waits up to `:timeout` (5 minutes) for the redirect, answers it with a
short page and stops the server. A second request gets `410 Gone`. The
pending authorization never leaves the calling process, so `state` is used
once by construction. `:challenge`, `:scopes` and `:principal` are passed to
`authorize_url/2`.

Whether a random port is accepted depends on the authorization server
(RFC 8252 lets it ignore the port for loopback redirect URIs). If yours
matches exactly, pass `port:` and list that URI in your CIMD document. With
dynamic registration, a stored registration is reused only while its
`redirect_uris` include the redirect URI, so a new random port registers a
new client each time: give a fixed `port:` there too.

`Loopback.start/1`, `await/2` and `stop/1` are the server's halves, for a
host that runs the flow itself.

## Step-up

A 403 with `error="insufficient_scope"` fails that request with
`:authorization_required` and a challenge whose `scope` is the **union** of
the scopes the current token holds and the challenged ones (MCP 2026-07-28;
applied to both eras). `on_authorization_required` is called with it; you
authorize again as above, passing the challenge so the union is requested.
The connection stays `:ready` meanwhile, because other requests may be
within scope.

Step-ups are counted per resource and scope set, order and duplicates
ignored. After `max_step_up_attempts` (2) for the same set, the request
fails with `kind: :auth, reason: :step_up_limit` and the host is not asked
again. This stops a server from looping the client through the
authorization server. A client-credentials client steps up by itself: it
requests a token for the union and sends the request again.

## Client registration

For each authorization server, the client picks its identity in this order
(`ConduitMcp.Client.OAuth.Registration`):

1. **Pre-registered**: `pre_registered[issuer]`, matched on the exact
   issuer string.
2. **Client ID Metadata Document**: when the authorization server's
   metadata has `client_id_metadata_document_supported: true` and
   `:client_metadata_url` is set, that URL is the client id. Nothing is
   registered, and the same id works with every authorization server that
   supports CIMD. This is the MCP spec's preferred method.
3. **Dynamic client registration** (RFC 7591; deprecated in MCP 2026-07-28,
   kept for older authorization servers): when the metadata has a
   `registration_endpoint`. The request declares `application_type`,
   `grant_types: ["authorization_code", "refresh_token"]`,
   `response_types: ["code"]` and `token_endpoint_auth_method: "none"`, plus
   your `:client_metadata`. The registered client is stored in the token
   store under the issuer and reused while its `redirect_uris` include the
   redirect URI.
4. Otherwise the flow fails with `:no_registration_method`.

**Credentials are bound to their issuer.** When you configured
`pre_registered` clients but none is for the issuer the server now names,
the flow stops with `:authorization_server_changed` instead of falling back
to CIMD or registration, which would silently give the client a new
identity. Registered clients are stored by issuer, so a client registered
with one authorization server is never presented to another. Add
`expected_issuers` to refuse any authorization server you did not list
(`:issuer_not_allowed`).

```elixir
auth:
  {:oauth,
   redirect_uri: "https://app.example.com/oauth/mcp/callback",
   pre_registered: %{
     "https://auth.example.com" => [
       client_id: "my-app",
       client_secret: {:system, "MCP_CLIENT_SECRET"}
     ]
   },
   expected_issuers: ["https://auth.example.com"]}
```

A pre-registered client takes the same credential options as a
client-credentials client (below); with neither a secret nor a key it is a
public client.

## Machine to machine

`auth: {:client_credentials, opts}` uses the OAuth `client_credentials`
grant (the MCP `io.modelcontextprotocol/oauth-client-credentials`
extension): no user and no browser.

```elixir
{ConduitMcp.Client,
 name: :reports,
 transport:
   {ConduitMcp.Client.Transport.StreamableHTTP,
    url: "https://mcp.example.com/mcp",
    auth:
      {:client_credentials,
       client_id: "reporting-service",
       client_secret: {:system, "MCP_CLIENT_SECRET"},
       scopes: ["reports:read"]}}}
```

| Option | Default | Meaning |
|---|---|---|
| `:client_id` | required | The client id |
| `:client_secret` | `nil` | A string, a `ConduitMcp.Client.Secret`, or `{:system, "VAR"}`: read from the environment on every token request and never kept. An unset variable fails the request with `:client_secret_unavailable` |
| `:private_key` | `nil` | A private JWK (map) or PEM string for `private_key_jwt` (RFC 7523). Needs `:jose` |
| `:private_key_alg` | `"RS256"` | The JWS algorithm of the client assertion |
| `:private_key_kid` | `nil` | The `kid` header of the client assertion |
| `:token_endpoint_auth_method` | inferred | `:private_key_jwt` with a key, `:client_secret_basic` with a secret; `:client_secret_post` on request |

One of `:client_secret` and `:private_key` is required. With a key, the
client signs an assertion whose `aud` is the token endpoint:

```elixir
auth:
  {:client_credentials,
   client_id: "reporting-service",
   private_key: File.read!("/run/secrets/mcp_client_key.pem"),
   private_key_alg: "ES256",
   private_key_kid: "2026-10"}
```

Discovery is the same as for the interactive flow, except that `S256` and an
`authorization_endpoint` are not required. The token request carries
`resource` and `scope` (the configured `:scopes`, else the server's
`scopes_supported`). Tokens are stored like any other and replaced by a new
token request when they expire, single-flight. The other OAuth options
(`:store`, `:principal`, `:expected_issuers`, `:refresh_skew`,
`:max_step_up_attempts`, and the development options) apply as well.

## Token stores

Tokens are stored under `{principal, issuer, resource}`, so a token is never
sent to another server, issued by another authorization server, or used for
another user, even when two servers trust the same authorization server.
Registered clients are stored under the issuer alone.

The default `ConduitMcp.Client.OAuth.TokenStore.ETS` is in memory. A client
without `:store` starts one under its own supervisor; it is lost when the
client stops. Its table is `:protected`: any process may read it, only the
store process writes it. To share one between standalone clients, start it
yourself and name it in each:

```elixir
children = [
  {ConduitMcp.Client.OAuth.TokenStore.ETS, name: :mcp_tokens},
  {ConduitMcp.Client,
   name: :docs,
   transport:
     {ConduitMcp.Client.Transport.StreamableHTTP,
      url: "https://docs.example.com/mcp",
      auth: {:oauth, store: {ConduitMcp.Client.OAuth.TokenStore.ETS, name: :mcp_tokens}}}}
]
```

### Writing a persistent store

Implement `ConduitMcp.Client.OAuth.TokenStore`. Each callback gets the
`opts` from `store: {module, opts}` as its last argument:

| Callback | Returns |
|---|---|
| `fetch_tokens(key, opts)` | `{:ok, %ConduitMcp.Client.OAuth.Tokens{}}` or `:error` |
| `put_tokens(key, tokens, opts)` | `:ok` or `{:error, reason}` |
| `fetch_client(issuer, opts)` | `{:ok, client_map}` or `:error` |
| `put_client(issuer, client_map, opts)` | `:ok` or `{:error, reason}` |
| `delete(key_or_issuer, :tokens \| :client, opts)` | `:ok` |
| `transaction(key, fun, opts)` (optional) | what `fun.()` returns |

`ConduitMcp.Client.OAuth.Tokens` holds `access_token` and `refresh_token` as
`ConduitMcp.Client.Secret`s, `expires_at` (Unix seconds or `nil`), `scopes`
and `token_type`; `Tokens.new/1` wraps plain strings. A client map is
string-keyed: `"client_id"`, `"client_secret"` (a `Secret` or `nil`),
`"token_endpoint_auth_method"` and `"redirect_uris"`. Expose secrets with
`ConduitMcp.Client.Secret.expose/1` only to encrypt them, and wrap them
again on the way back.

An Ecto sketch, with `MyApp.Vault` standing for your encryption (Cloak, a
KMS, ...) and string principals:

```elixir
defmodule MyApp.MCPTokenStore do
  @behaviour ConduitMcp.Client.OAuth.TokenStore

  import Ecto.Query

  alias ConduitMcp.Client.OAuth.Tokens
  alias ConduitMcp.Client.Secret
  alias MyApp.MCP.{OAuthClient, OAuthToken}
  alias MyApp.{Repo, Vault}

  @impl true
  def fetch_tokens({principal, issuer, resource}, _opts) do
    case Repo.get_by(OAuthToken, principal: to_string(principal), issuer: issuer, resource: resource) do
      nil ->
        :error

      row ->
        {:ok,
         Tokens.new(
           access_token: Vault.decrypt!(row.access_token),
           refresh_token: row.refresh_token && Vault.decrypt!(row.refresh_token),
           expires_at: row.expires_at,
           scopes: row.scopes
         )}
    end
  end

  @impl true
  def put_tokens({principal, issuer, resource}, %Tokens{} = tokens, _opts) do
    row = %{
      principal: to_string(principal),
      issuer: issuer,
      resource: resource,
      access_token: Vault.encrypt!(Secret.expose(tokens.access_token)),
      refresh_token: tokens.refresh_token && Vault.encrypt!(Secret.expose(tokens.refresh_token)),
      expires_at: tokens.expires_at,
      scopes: tokens.scopes
    }

    {1, _} =
      Repo.insert_all(OAuthToken, [row],
        on_conflict: {:replace, [:access_token, :refresh_token, :expires_at, :scopes]},
        conflict_target: [:principal, :issuer, :resource]
      )

    :ok
  end

  @impl true
  def fetch_client(issuer, _opts) do
    case Repo.get_by(OAuthClient, issuer: issuer) do
      nil ->
        :error

      row ->
        {:ok,
         %{
           "client_id" => row.client_id,
           "client_secret" => row.client_secret && Secret.new(Vault.decrypt!(row.client_secret)),
           "token_endpoint_auth_method" => row.token_endpoint_auth_method,
           "redirect_uris" => row.redirect_uris
         }}
    end
  end

  @impl true
  def put_client(issuer, client, _opts) do
    secret = client["client_secret"]

    row = %{
      issuer: issuer,
      client_id: client["client_id"],
      client_secret: secret && Vault.encrypt!(Secret.expose(secret)),
      token_endpoint_auth_method: client["token_endpoint_auth_method"],
      redirect_uris: client["redirect_uris"]
    }

    {1, _} =
      Repo.insert_all(OAuthClient, [row],
        on_conflict: {:replace_all_except, [:issuer]},
        conflict_target: [:issuer]
      )

    :ok
  end

  @impl true
  def delete({principal, issuer, resource}, :tokens, _opts) do
    Repo.delete_all(
      from t in OAuthToken,
        where: t.principal == ^to_string(principal) and t.issuer == ^issuer and t.resource == ^resource
    )

    :ok
  end

  def delete(issuer, :client, _opts) do
    Repo.delete_all(from c in OAuthClient, where: c.issuer == ^issuer)
    :ok
  end

  # Single-flight across nodes: a transaction-scoped advisory lock on the key.
  @impl true
  def transaction({principal, issuer, resource}, fun, _opts) do
    lock = Enum.join([to_string(principal), issuer, resource], "\n")

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock])
        fun.()
      end)

    result
  end
end
```

### Single-flight refresh

When many processes find the same expired token, only one should refresh
it: an authorization server that rotates refresh tokens invalidates the old
one on first use. The client runs every refresh (and every
client-credentials token request) through `transaction/3`. Inside the lock
it reads the store again, and uses a token another process has just stored
instead of refreshing. A rotated refresh token is written before the lock is
released.

`transaction/3` is optional. Without it the lock is a node-local
`:global.trans/4` on the key, which is enough for the ETS store and for any
store used from one node. A store shared by several nodes should implement
it with its own lock, like the advisory lock above or
`SELECT ... FOR UPDATE`. The callback runs in the requesting process, and
`fun` performs the token request, so the lock is held for one HTTP round
trip.

A refused refresh (`invalid_grant`) deletes the tokens, and the user must
authorize again. If `put_tokens/3` returns an error, a warning is logged and
the new tokens still serve the current request; the next request
re-authorizes.

## Using OAuth in a Hub

A `ConduitMcp.Client.Hub` starts one in-memory token store and gives it to
every server whose OAuth options name no `:store`. Tokens stay per resource,
but servers behind the same authorization server share one dynamic
registration (when they use the same redirect URI), and a server client the
hub restarts, or one removed and added again, finds its tokens and needs no
new authorization. The store lives as long as the hub; for tokens that
outlive it, give each server a persistent `:store`.

Each server is a client named `{:hub_server, hub, server_id}`
(`ConduitMcp.Client.Hub.client/2`), so the flow is the same:

```elixir
{ConduitMcp.Client.Hub,
 name: {MyApp.Hub, user_id},
 policy: MyApp.Policy.for(user_id),
 servers: [
   github: [
     transport:
       {ConduitMcp.Client.Transport.StreamableHTTP,
        url: "https://mcp.github.example/mcp",
        auth:
          {:oauth,
           principal: user_id,
           redirect_uri: "https://app.example.com/oauth/mcp/callback",
           client_metadata_url: "https://app.example.com/oauth/client.json",
           on_authorization_required: &MyApp.MCPAuth.required(user_id, "github", &1)}}
   ]
 ]}

client = ConduitMcp.Client.Hub.client({MyApp.Hub, user_id}, "github")
{:ok, url, pending} = ConduitMcp.Client.OAuth.authorize_url(client, challenge: challenge)
```

While a server awaits authorization, `ConduitMcp.Client.Hub.status/1`
reports it as `:authorizing` and its tools are left out of
`ConduitMcp.Client.Hub.list_tools/2`, which only offers `:ready` servers.
Run one hub per user, as for any per-user credential (see
[client_hub.md](client_hub.md)).

## Development and tests

- `allow_insecure_oauth: true` admits plain `http` metadata and
  authorization-server URLs on loopback hosts, connected by name without the
  address check. `https` URLs are always checked.
- `allow_private: ["10.0.0.0/8"]` admits private addresses for OAuth
  requests, for an authorization server on your own network.
- `resolver:` replaces DNS for the URL policy.
- `transport_opts: [cacerts: ...]` trusts a private CA. The transport's
  `insecure_skip_tls_verify` does not apply to OAuth requests.
- `clock:` fixes the time for expiry checks.
- The transport refuses `auth:` over plain `http` to a non-loopback host at
  start.

## Security properties

| Area | Behaviour |
|---|---|
| PKCE | `S256` only, with a 32-byte verifier. An authorization server that does not list `S256` in `code_challenge_methods_supported` is refused before any authorization request (`:pkce_unsupported`) |
| `state` | 32 random bytes, bound to the principal, 10 minute lifetime, compared in constant time. Single use is the host's job (see "Storing the pending authorization") |
| Authorization response | RFC 9207 `iss` checked by exact comparison before any token request; required when the authorization server advertises it. On a `state`, principal or `iss` failure nothing from the response is surfaced |
| Resource | The canonical server URI is sent as `resource` (RFC 8707) in authorization and token requests. Protected Resource Metadata must name exactly that resource (`:resource_mismatch`) |
| Issuer | Authorization-server metadata must name exactly the issuer its URL was built from (`:issuer_mismatch`); `expected_issuers` limits which issuers are accepted; credentials are bound to their issuer (`:authorization_server_changed`) |
| Endpoints | Every endpoint in the metadata must be `https` (`:insecure_endpoint`), which also refuses `javascript:`, `file:` and `data:` |
| Metadata and token fetches | Every URL passes `ConduitMcp.Client.URLPolicy` `:public_only`: the host is resolved once and refused if any address is internal (`:url_blocked`), then the request connects to exactly that address, so DNS rebinding cannot redirect it. No redirects, no compressed bodies, 256 KiB body cap, `:request_timeout` per request |
| Bearer token | Sent only to the MCP server's URL, never to metadata, registration or token endpoints, never across a redirect to another origin, never over plain `http` to a non-loopback host |
| Secrets in memory | Tokens, client secrets, private keys, `state`, the verifier and the code are `ConduitMcp.Client.Secret`s (`#Secret<redacted>` in `inspect/1`). Crash reports of the connection and of the ETS store redact OAuth state |
| Token store | The default ETS table is `:protected`: other processes can read it but not plant or swap tokens |
| Errors and telemetry | Never carry a token, code, `state`, verifier, secret, URL or issuer |

## Errors

The `ConduitMcp.Client.OAuth` functions return
`{:error, %ConduitMcp.Client.OAuth.Error{reason: reason, data: data}}`, or a
`ConduitMcp.Client.Error` when the named client cannot be reached. Client
requests return `%ConduitMcp.Client.Error{kind: :auth, reason: reason}`:
`:authorization_required` and `:step_up_limit` carry
`data: %{challenge: challenge}`, other OAuth reasons carry the
`OAuth.Error`, and `ConduitMcp.Client.authorized/1` on a client without
OAuth returns `:oauth_not_configured`.

`ConduitMcp.Client.OAuth.Error.reasons/0` is the closed set:

| Reason | Meaning |
|---|---|
| `:invalid_challenge` | A `WWW-Authenticate` header is malformed or over a limit |
| `:invalid_url` | A URL does not parse, has no host, carries user info, or an issuer has a query or fragment; also a missing redirect URI |
| `:insecure_url` | A URL that must be `https` is not |
| `:resource_mismatch` | Protected Resource Metadata names another resource |
| `:no_authorization_server` | Protected Resource Metadata lists no authorization server |
| `:issuer_not_allowed` | The authorization server is not in `expected_issuers` |
| `:invalid_metadata` | A metadata document is not an object, or a field has the wrong type |
| `:issuer_mismatch` | Authorization-server metadata names another issuer |
| `:pkce_unsupported` | The authorization server does not support `S256` |
| `:insecure_endpoint` | A metadata endpoint is not `https` |
| `:invalid_state` | The response's `state` is missing or wrong |
| `:principal_mismatch` | The callback is completed by another principal than the one that started it |
| `:state_expired` | The pending authorization is older than 10 minutes |
| `:iss_mismatch` | The response's `iss` is not the issuer |
| `:iss_missing` | The authorization server advertises `iss` but sent none |
| `:missing_code` | The response has neither `code` nor `error` |
| `:invalid_pending` | A stored `Pending` map could not be restored; `:data` names the field |
| `:access_denied`, `:invalid_request`, `:unauthorized_client`, `:unsupported_response_type`, `:invalid_scope`, `:server_error`, `:temporarily_unavailable` | The authorization server returned that error |
| `:authorization_error` | The authorization server returned another error code (in `:data`) |
| `:authorization_required` | The user must authorize |
| `:no_protected_resource_metadata` | No Protected Resource Metadata URL answered |
| `:no_authorization_server_metadata` | No authorization-server metadata URL answered |
| `:authorization_server_changed` | Pre-registered credentials exist, but none for the issuer the server names now |
| `:no_registration_method` | No pre-registered client, CIMD or dynamic registration applies |
| `:registration_failed` | Dynamic registration was refused |
| `:invalid_grant` | The token endpoint rejected the code or refresh token |
| `:token_request_failed` | The token endpoint failed otherwise |
| `:step_up_limit` | `max_step_up_attempts` reached for this resource and scope set |
| `:url_blocked` | The URL policy refused a server-supplied URL before connecting |
| `:client_secret_unavailable` | A `{:system, "VAR"}` client secret names an unset variable |

`Exception.message/1` renders only the reason and a fixed description, so it
is safe to log.

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:conduit_mcp, :client, :oauth, op, :start]` | `:monotonic_time`, `:system_time` | `:client`, `:server_id`, `:principal` |
| `[:conduit_mcp, :client, :oauth, op, :stop]` | `:duration`, `:monotonic_time` | as `:start`, plus `:status` (`:ok`, `:error`) and `:reason` (an `OAuth.Error` reason or `nil`) |
| `[:conduit_mcp, :client, :oauth, op, :exception]` | `:duration`, `:monotonic_time` | as `:start`, plus `:kind` |
| `[:conduit_mcp, :client, :oauth, :authorization_required]` | `:count` | `:client`, `:server_id`, `:principal`, `:reason` (`:unauthorized`, `:step_up`) |

`op` is `:discovery`, `:registration` (`:stop` adds `:method`:
`:pre_registered`, `:cimd`, `:dcr` or `nil`), `:token_exchange` (adds
`:grant`: `:authorization_code` or `:client_credentials`), `:refresh` or
`:step_up`. `:client` is `nil` for a standalone configuration, and
`:principal` is whatever you configured, so do not use it as a metric tag
unless it is low-cardinality. Spans run in the process doing the work: a
request process, the connection's authorization task, or your caller;
`:step_up` and `:authorization_required` run in the connection, so handlers
must be fast. See `ConduitMcp.Telemetry` for the full reference.

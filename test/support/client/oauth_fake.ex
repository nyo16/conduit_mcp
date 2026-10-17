defmodule ConduitMcp.Test.Client.OAuthFake do
  @moduledoc """
  A fake OAuth authorization server (and protected-resource metadata host)
  on Bandit port 0, for the client OAuth tests.

  Every request is recorded, in order, with its method, path, query,
  `authorization` header and form/JSON body, so tests can assert the
  probe order and that no `Authorization` header reached a metadata or
  authorization-server URL. Routes are functions of the recorded request;
  `serve_as/2` installs a complete authorization server (metadata,
  `/authorize`, `/token`, `/register`) that checks PKCE, `redirect_uri`,
  `resource` and client authentication like a real one, and rotates
  refresh tokens.

  `serve_mcp/3` hosts one of this library's own MCP servers protected by
  `ConduitMcp.Plugs.OAuth` (Static key provider holding the fake's signing
  key), so tokens the fake mints are accepted end to end.

  All URLs are `http://127.0.0.1:<port>`: the client runs with
  `allow_insecure_oauth: true`.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias ConduitMcp.Test.Client.OAuthFake.Plug, as: FakePlug

  defstruct [:url, :agent, :issuer]

  @type t :: %__MODULE__{url: String.t(), agent: pid(), issuer: String.t()}

  @doc """
  Starts the fake. Options: `:issuer_path` (default `""`), `:expires_in`
  (default 3600), `:iss` (send `iss` in the authorization response, default
  true), `:jwt` (mint JWT access tokens with an ES256 key, default false),
  `:sub` (default `"user-1"`), `:rotate` (rotate refresh tokens, default true).
  """
  def start(opts \\ []) do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})

    state = %{
      log: [],
      routes: %{},
      codes: %{},
      refresh: %{},
      clients: %{},
      n: 0,
      jwk: jwk,
      opts:
        Map.merge(
          %{expires_in: 3600, iss: true, jwt: false, sub: "user-1", rotate: true},
          Map.new(opts)
        )
    }

    agent = start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> state end]}})

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {FakePlug, agent}, port: 0, ip: :loopback, startup_log: false},
          id: make_ref()
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    issuer = url <> Keyword.get(opts, :issuer_path, "")
    Agent.update(agent, &Map.merge(&1, %{url: url, issuer: issuer}))
    %__MODULE__{url: url, agent: agent, issuer: issuer}
  end

  # --- routes --------------------------------------------------------------

  @doc """
  Routes `method path` to `handler`: a `{status, body}` /
  `{status, headers, body}` tuple, or a function of the recorded request
  (and the fake) returning one. A map body is JSON-encoded.
  """
  def route(%__MODULE__{agent: agent}, method, path, handler) do
    Agent.update(agent, &put_in(&1.routes[{method, path}], handler))
  end

  @doc "Serves Protected Resource Metadata at `path` for `resource`."
  def serve_prm(fake, path, resource, opts \\ []) do
    document =
      %{
        "resource" => resource,
        "authorization_servers" => Keyword.get(opts, :authorization_servers, [fake.issuer])
      }
      |> maybe_put("scopes_supported", Keyword.get(opts, :scopes_supported))

    route(fake, "GET", path, {200, document})
  end

  @doc """
  Installs the authorization server: its metadata (at the OAuth
  path-inserted well-known URL unless `:metadata_path` says otherwise,
  merged with `:metadata`), `/authorize`, `/token` and `/register`.
  """
  def serve_as(fake, opts \\ []) do
    path = Keyword.get(opts, :metadata_path, default_metadata_path(fake))
    route(fake, "GET", path, {200, metadata(fake, Keyword.get(opts, :metadata, %{}))})
    route(fake, "POST", "/token", &token/2)
    route(fake, "POST", "/register", &register/2)
    route(fake, "GET", "/authorize", &authorize/2)
    fake
  end

  def default_metadata_path(fake) do
    case URI.parse(fake.issuer).path do
      nil -> "/.well-known/oauth-authorization-server"
      "" -> "/.well-known/oauth-authorization-server"
      path -> "/.well-known/oauth-authorization-server" <> path
    end
  end

  @doc "Authorization-server metadata for the fake, merged with `overrides` (a `nil` value deletes)."
  def metadata(fake, overrides \\ %{}) do
    %{
      "issuer" => fake.issuer,
      "authorization_endpoint" => fake.url <> "/authorize",
      "token_endpoint" => fake.url <> "/token",
      "registration_endpoint" => fake.url <> "/register",
      "code_challenge_methods_supported" => ["S256"],
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true,
      "token_endpoint_auth_methods_supported" => [
        "none",
        "client_secret_basic",
        "client_secret_post",
        "private_key_jwt"
      ]
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  # --- inspection ---------------------------------------------------------------

  @doc "Every request received, oldest first."
  def requests(%__MODULE__{agent: agent}), do: agent |> Agent.get(& &1.log) |> Enum.reverse()

  @doc "`\"METHOD /path\"` of every request, oldest first."
  def paths(fake), do: Enum.map(requests(fake), &"#{&1.method} #{&1.path}")

  @doc "How many `method path` requests arrived."
  def count(fake, method, path),
    do: Enum.count(requests(fake), &(&1.method == method and &1.path == path))

  @doc "The fake's public signing key, as a JWK map with a `kid`."
  def public_jwk(%__MODULE__{agent: agent}) do
    jwk = Agent.get(agent, & &1.jwk)
    {_, map} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.put(map, "kid", "fake-key")
  end

  @doc "Sets fake options (`:expires_in`, `:rotate`, `:iss`, ...) for later requests."
  def set(%__MODULE__{agent: agent}, opts),
    do: Agent.update(agent, fn state -> %{state | opts: Map.merge(state.opts, Map.new(opts))} end)

  @doc "Makes every refresh token invalid (the next refresh gets `invalid_grant`)."
  def revoke_refresh_tokens(%__MODULE__{agent: agent}),
    do: Agent.update(agent, &%{&1 | refresh: %{}})

  # --- the user at the authorization endpoint ------------------------------------

  @doc """
  What the authorization server redirects back with after the user
  approves `authorize_url` (the redirect's query parameters). Records the
  code for the token endpoint. Options: `:iss` (override, `false` to omit),
  `:state` (override), `:error` (an error response instead).
  """
  def approve(%__MODULE__{agent: agent} = fake, authorize_url, opts \\ []) do
    query = authorize_url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    {params, _redirect} = Agent.get_and_update(agent, &grant(&1, query, opts))
    _ = fake
    params
  end

  defp grant(state, query, opts) do
    n = state.n + 1
    code = "code-#{n}-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    params =
      case Keyword.get(opts, :error) do
        nil -> %{"code" => code}
        error -> %{"error" => error, "error_description" => "the user said no"}
      end

    params = Map.put(params, "state", Keyword.get(opts, :state, query["state"]))

    params =
      case Keyword.get(opts, :iss, if(state.opts.iss, do: state.issuer, else: false)) do
        false -> params
        iss -> Map.put(params, "iss", iss)
      end

    record = %{
      client_id: query["client_id"],
      redirect_uri: query["redirect_uri"],
      challenge: query["code_challenge"],
      method: query["code_challenge_method"],
      resource: query["resource"],
      scopes: String.split(query["scope"] || "", " ", trim: true)
    }

    state = %{state | n: n, codes: Map.put(state.codes, code, record)}
    {{params, query["redirect_uri"]}, state}
  end

  # GET /authorize: approve at once and redirect (used by the Loopback test).
  defp authorize(req, fake) do
    {params, redirect_uri} = Agent.get_and_update(fake.agent, &grant(&1, req.query, []))

    {302, [{"location", redirect_uri <> "?" <> URI.encode_query(params)}], ""}
  end

  # --- token endpoint -------------------------------------------------------------

  defp token(req, fake) do
    Agent.get_and_update(fake.agent, fn state ->
      case req.params["grant_type"] do
        "authorization_code" -> code_grant(state, req)
        "refresh_token" -> refresh_grant(state, req)
        "client_credentials" -> client_credentials_grant(state, req)
        _other -> {error(400, "unsupported_grant_type"), state}
      end
    end)
  end

  defp code_grant(state, req) do
    p = req.params

    with {:ok, record} <- Map.fetch(state.codes, p["code"] || ""),
         true <- record.client_id == client_id(req),
         true <- record.redirect_uri == p["redirect_uri"],
         true <- record.resource == p["resource"],
         true <- record.method == "S256",
         true <- challenge(p["code_verifier"]) == record.challenge do
      state = %{state | codes: Map.delete(state.codes, p["code"])}
      issue(state, record.resource, record.scopes, record.client_id)
    else
      _ -> {error(400, "invalid_grant"), state}
    end
  end

  defp refresh_grant(state, req) do
    p = req.params
    resource = p["resource"]

    case Map.fetch(state.refresh, p["refresh_token"] || "") do
      {:ok, %{resource: ^resource} = record} ->
        state =
          if state.opts.rotate,
            do: %{state | refresh: Map.delete(state.refresh, p["refresh_token"])},
            else: state

        issue(state, record.resource, record.scopes, record.client_id, not state.opts.rotate)

      _other ->
        {error(400, "invalid_grant"), state}
    end
  end

  defp client_credentials_grant(state, req) do
    if client_authenticated?(state, req) do
      scopes = String.split(req.params["scope"] || "", " ", trim: true)
      issue(state, req.params["resource"], scopes, client_id(req), true)
    else
      {error(401, "invalid_client"), state}
    end
  end

  # `secret` clients: `client_secret_basic` or `_post` against the
  # registered secret; `jwt` clients: a client assertion signed by the
  # registered public key with `aud` = the token endpoint.
  defp client_authenticated?(state, req) do
    case Map.fetch(state.clients, client_id(req)) do
      {:ok, {:secret, secret}} ->
        client_secret(req) == secret

      {:ok, {:jwt, public_jwk}} ->
        with "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" <-
               req.params["client_assertion_type"],
             assertion when is_binary(assertion) <- req.params["client_assertion"],
             {true, %JOSE.JWT{fields: claims}, _jws} <-
               JOSE.JWT.verify_strict(public_jwk, ["ES256", "RS256"], assertion) do
          claims["iss"] == client_id(req) and claims["sub"] == client_id(req) and
            claims["aud"] == state.url <> "/token"
        else
          _ -> false
        end

      :error ->
        false
    end
  end

  @doc "Registers a confidential client for the client-credentials grant."
  def register_client(%__MODULE__{agent: agent}, client_id, credential),
    do: Agent.update(agent, &put_in(&1.clients[client_id], credential))

  defp issue(state, resource, scopes, client_id, keep_refresh? \\ false) do
    n = state.n + 1
    state = %{state | n: n}
    access = access_token(state, n, resource, scopes)

    {refresh, state} =
      if keep_refresh? do
        {nil, state}
      else
        refresh = "rt-#{n}-" <> random()
        record = %{resource: resource, scopes: scopes, client_id: client_id}
        {refresh, %{state | refresh: Map.put(state.refresh, refresh, record)}}
      end

    body =
      %{
        "access_token" => access,
        "token_type" => "Bearer",
        "expires_in" => state.opts.expires_in,
        "scope" => Enum.join(scopes, " ")
      }
      |> maybe_put("refresh_token", refresh)

    {{200, body}, state}
  end

  defp access_token(%{opts: %{jwt: true}} = state, n, resource, scopes) do
    now = System.system_time(:second)

    claims = %{
      "iss" => state.issuer,
      "aud" => resource,
      "sub" => state.opts.sub,
      "scope" => Enum.join(scopes, " "),
      "iat" => now,
      "exp" => now + state.opts.expires_in,
      "jti" => "jti-#{n}"
    }

    {_, token} =
      state.jwk
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "fake-key"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp access_token(_state, n, _resource, _scopes), do: "at-#{n}-" <> random()

  # Codes and tokens are unique strings, so the secret scan can search for
  # them without matching anything else.
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp register(req, fake) do
    body = req.json || %{}

    Agent.get_and_update(fake.agent, fn state ->
      n = state.n + 1
      id = "dcr-client-#{n}@" <> URI.parse(state.url).authority

      answer =
        body
        |> Map.take(["redirect_uris", "grant_types", "token_endpoint_auth_method", "client_name"])
        |> Map.put("client_id", id)

      {{201, answer}, %{state | n: n}}
    end)
  end

  defp client_id(req) do
    case basic(req) do
      {id, _secret} -> id
      nil -> req.params["client_id"]
    end
  end

  defp client_secret(req) do
    case basic(req) do
      {_id, secret} -> secret
      nil -> req.params["client_secret"]
    end
  end

  defp basic(%{authorization: "Basic " <> encoded}) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      {URI.decode_www_form(id), URI.decode_www_form(secret)}
    else
      _ -> nil
    end
  end

  defp basic(_req), do: nil

  defp challenge(nil), do: nil

  defp challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  defp error(status, code), do: {status, %{"error" => code}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- our own MCP server behind Plugs.OAuth ---------------------------------------

  @doc """
  Starts `server_module` (`ConduitMcp.Transport.StreamableHTTP`) on its own
  Bandit port with `auth: [strategy: :oauth]`: issuer = the fake's, audience
  = the server's own URL, the fake's public key in a Static key provider.
  Every request's `authorization` header is recorded in the fake's log with
  `target: {:mcp, url}`. Returns the server URL (no trailing slash).
  """
  def serve_mcp(%__MODULE__{} = fake, server_module, opts \\ []) do
    holder = start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> nil end]}})

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {ConduitMcp.Test.Client.OAuthFake.MCP, {holder, fake.agent}},
           port: 0,
           ip: :loopback,
           startup_log: false},
          id: make_ref()
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"

    mcp_opts =
      ConduitMcp.Transport.StreamableHTTP.init(
        server_module: server_module,
        allowed_origins: "*",
        keep_alive_interval: 50,
        auth: [
          strategy: :oauth,
          issuer: fake.issuer,
          audience: url,
          resource_uri: url,
          scopes_supported: Keyword.get(opts, :scopes_supported, ["read"]),
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [public_jwk(fake)]}
        ]
      )

    Agent.update(holder, fn _ -> {url, mcp_opts} end)
    url
  end

  defmodule MCP do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, {holder, log}) do
      {url, opts} = Agent.get(holder, & &1)

      entry = %{
        target: {:mcp, url},
        method: conn.method,
        path: conn.request_path,
        query: %{},
        authorization: conn |> Plug.Conn.get_req_header("authorization") |> List.first(),
        params: %{},
        json: nil
      }

      Agent.update(log, &%{&1 | log: [entry | &1.log]})
      ConduitMcp.Transport.StreamableHTTP.call(conn, opts)
    end
  end
end

defmodule ConduitMcp.Test.Client.OAuthFake.Plug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias ConduitMcp.Test.Client.OAuthFake

  def init(agent), do: agent

  def call(conn, agent) do
    conn = fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)
    type = conn |> get_req_header("content-type") |> List.first() || ""

    req = %{
      target: :as,
      method: conn.method,
      path: conn.request_path,
      query: conn.query_params,
      authorization: conn |> get_req_header("authorization") |> List.first(),
      params:
        if(String.starts_with?(type, "application/x-www-form-urlencoded"),
          do: URI.decode_query(body),
          else: %{}
        ),
      json:
        if String.starts_with?(type, "application/json") do
          case JSON.decode(body) do
            {:ok, json} -> json
            _ -> nil
          end
        end
    }

    {routes, fake} =
      Agent.get_and_update(agent, fn state ->
        fake = %OAuthFake{url: state.url, agent: agent, issuer: state.issuer}
        {{state.routes, fake}, %{state | log: [req | state.log]}}
      end)

    case Map.fetch(routes, {conn.method, conn.request_path}) do
      {:ok, handler} -> respond(conn, run(handler, req, fake))
      :error -> send_resp(conn, 404, "")
    end
  end

  defp run(handler, req, fake) when is_function(handler, 2), do: handler.(req, fake)
  defp run(response, _req, _fake), do: response

  defp respond(conn, {status, body}), do: respond(conn, {status, [], body})

  defp respond(conn, {status, headers, body}) do
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)

    if is_map(body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
    else
      send_resp(conn, status, body)
    end
  end
end

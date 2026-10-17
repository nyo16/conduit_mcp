defmodule ConduitMcp.Client.OAuth.FlowTest do
  # `ConduitMcp.Client.OAuth` against the fake authorization server on
  # Bandit port 0: discovery order, registration priority, every refusal
  # (with no token request), the code exchange, refresh, client
  # credentials and token confinement. The MCP server's URL is
  # `<fake>/mcp`; its metadata is served by the fake too.
  use ExUnit.Case, async: true

  @moduletag :integration

  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.{Challenge, Config, Error, Pending, Tokens, TokenStore}
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Test.Client.OAuthFake

  @cimd "https://app.example.com/oauth/client.json"
  @redirect "http://127.0.0.1:9/callback"
  @prm_inserted "/.well-known/oauth-protected-resource/mcp"
  @prm_root "/.well-known/oauth-protected-resource"

  defp fake(opts \\ []) do
    fake = OAuthFake.start(opts)
    OAuthFake.serve_prm(fake, @prm_inserted, fake.url <> "/mcp", scopes_supported: ["read"])
    fake
  end

  defp store do
    store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
    start_supervised!(store)
    store
  end

  defp config(fake, overrides \\ []) do
    Config.new!(
      Keyword.merge(
        [
          server_url: fake.url <> "/mcp",
          redirect_uri: @redirect,
          client_metadata_url: @cimd,
          allow_insecure_oauth: true,
          store: store()
        ],
        overrides
      )
    )
  end

  defp resource(fake), do: fake.url <> "/mcp"

  defp no_token_calls(fake) do
    assert OAuthFake.count(fake, "POST", "/token") == 0
    assert OAuthFake.count(fake, "GET", "/authorize") == 0
  end

  defp authorized(fake, config, opts \\ []) do
    {:ok, url, pending} = OAuth.authorize_url(config, opts)
    params = OAuthFake.approve(fake, url)
    {:ok, tokens} = OAuth.handle_callback(pending, params, config: config)
    tokens
  end

  # --- discovery ----------------------------------------------------------------

  describe "discovery" do
    test "the challenge's resource_metadata comes first" do
      fake = fake() |> OAuthFake.serve_as()
      OAuthFake.serve_prm(fake, "/custom/prm", resource(fake))

      challenge = %Challenge{
        scheme: "bearer",
        params: %{"resource_metadata" => fake.url <> "/custom/prm"}
      }

      assert {:ok, _url, %Pending{}} = OAuth.authorize_url(config(fake), challenge: challenge)

      assert OAuthFake.paths(fake) == [
               "GET /custom/prm",
               "GET /.well-known/oauth-authorization-server"
             ]
    end

    test "then the path-inserted, then the root well-known URL, skipping 4xx and 5xx" do
      fake = OAuthFake.start() |> OAuthFake.serve_as()
      OAuthFake.route(fake, "GET", @prm_inserted, {500, "boom"})
      OAuthFake.serve_prm(fake, @prm_root, resource(fake))

      challenge = %Challenge{
        scheme: "bearer",
        params: %{"resource_metadata" => fake.url <> "/gone"}
      }

      assert {:ok, _url, _pending} = OAuth.authorize_url(config(fake), challenge: challenge)

      assert OAuthFake.paths(fake) == [
               "GET /gone",
               "GET " <> @prm_inserted,
               "GET " <> @prm_root,
               "GET /.well-known/oauth-authorization-server"
             ]
    end

    test "authorization-server metadata: OAuth path-insert, OIDC path-insert, OIDC path-append" do
      fake = fake(issuer_path: "/tenant")

      OAuthFake.serve_as(fake, metadata_path: "/tenant/.well-known/openid-configuration")
      OAuthFake.route(fake, "GET", "/.well-known/oauth-authorization-server/tenant", {404, ""})

      assert {:ok, _url, pending} = OAuth.authorize_url(config(fake))
      assert pending.issuer == fake.url <> "/tenant"

      assert OAuthFake.paths(fake) == [
               "GET " <> @prm_inserted,
               "GET /.well-known/oauth-authorization-server/tenant",
               "GET /.well-known/openid-configuration/tenant",
               "GET /tenant/.well-known/openid-configuration"
             ]
    end

    test "an issuer without a path: OAuth, then OIDC" do
      fake = fake()
      OAuthFake.serve_as(fake, metadata_path: "/.well-known/openid-configuration")

      assert {:ok, _url, _pending} = OAuth.authorize_url(config(fake))

      assert OAuthFake.paths(fake) == [
               "GET " <> @prm_inserted,
               "GET /.well-known/oauth-authorization-server",
               "GET /.well-known/openid-configuration"
             ]
    end

    test "no metadata anywhere" do
      fake = OAuthFake.start()

      assert {:error, %Error{reason: :no_protected_resource_metadata}} =
               OAuth.authorize_url(config(fake))

      fake = fake()

      assert {:error, %Error{reason: :no_authorization_server_metadata}} =
               OAuth.authorize_url(config(fake))
    end

    test "a redirect is never followed (HT-4)" do
      fake = OAuthFake.start() |> OAuthFake.serve_as()
      OAuthFake.route(fake, "GET", @prm_inserted, {302, [{"location", fake.url <> "/evil"}], ""})
      OAuthFake.serve_prm(fake, @prm_root, resource(fake))

      assert {:ok, _url, _pending} = OAuth.authorize_url(config(fake))
      assert OAuthFake.count(fake, "GET", "/evil") == 0
    end

    test "a server-supplied URL resolving to a private address is refused before connecting (HT-6)" do
      fake = fake() |> OAuthFake.serve_as()
      test = self()

      resolver = fn host ->
        send(test, {:resolved, host})
        {:ok, [{10, 0, 0, 1}]}
      end

      challenge = %Challenge{
        scheme: "bearer",
        params: %{"resource_metadata" => "https://metadata.example/prm"}
      }

      # Skipped (refused, never connected), then the well-known URL works.
      assert {:ok, _url, _pending} =
               OAuth.authorize_url(config(fake, resolver: resolver), challenge: challenge)

      assert_received {:resolved, "metadata.example"}

      # With nothing else to try, the refusal is the answer.
      lone = OAuthFake.start()

      assert {:error, %Error{reason: :url_blocked, data: {:blocked_address, {10, 0, 0, 1}}}} =
               OAuth.authorize_url(config(lone, resolver: resolver), challenge: challenge)
    end

    test "no Authorization header ever reaches metadata or the authorization server" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake)
      authorized(fake, config)
      assert {:ok, _} = OAuth.refresh(config, nil)

      assert OAuthFake.requests(fake) != []
      assert Enum.all?(OAuthFake.requests(fake), &(&1.authorization == nil))
    end
  end

  # --- refusals -------------------------------------------------------------------

  describe "refusals, each before any authorization or token request" do
    test "missing or plain-only PKCE (OA-1)" do
      for methods <- [nil, ["plain"]] do
        fake = fake()
        OAuthFake.serve_as(fake, metadata: %{"code_challenge_methods_supported" => methods})
        assert {:error, %Error{reason: :pkce_unsupported}} = OAuth.authorize_url(config(fake))
        no_token_calls(fake)
      end
    end

    test "an issuer that differs from the one the metadata URL was built from (OA-4)" do
      fake = fake()
      OAuthFake.serve_as(fake, metadata: %{"issuer" => fake.url <> "/"})
      assert {:error, %Error{reason: :issuer_mismatch}} = OAuth.authorize_url(config(fake))
      no_token_calls(fake)
    end

    test "PRM naming another resource (OA-4)" do
      fake = OAuthFake.start() |> OAuthFake.serve_as()
      OAuthFake.serve_prm(fake, @prm_inserted, fake.url <> "/other")
      assert {:error, %Error{reason: :resource_mismatch}} = OAuth.authorize_url(config(fake))
      no_token_calls(fake)
      assert OAuthFake.count(fake, "GET", @prm_root) == 0
    end

    test "javascript: and file: endpoints (OA-7)" do
      for {field, url} <- [
            {"authorization_endpoint", "javascript:alert(1)"},
            {"token_endpoint", "file:///etc/passwd"}
          ] do
        fake = fake()
        OAuthFake.serve_as(fake, metadata: %{field => url})

        assert {:error, %Error{reason: :insecure_endpoint, data: %{field: ^field}}} =
                 OAuth.authorize_url(config(fake))

        no_token_calls(fake)
      end
    end

    test "an authorization server outside expected_issuers" do
      fake = fake() |> OAuthFake.serve_as()

      assert {:error, %Error{reason: :issuer_not_allowed}} =
               OAuth.authorize_url(config(fake, expected_issuers: ["https://auth.example.com"]))

      no_token_calls(fake)
    end

    test "callback refusals: iss, state, principal, expiry (OA-2, OA-3)" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake, principal: "alice")
      {:ok, url, pending} = OAuth.authorize_url(config)
      good = OAuthFake.approve(fake, url)

      cases = [
        {%{good | "iss" => String.upcase(fake.issuer)}, [], :iss_mismatch},
        {Map.delete(good, "iss"), [], :iss_missing},
        {%{good | "state" => "forged"}, [], :invalid_state},
        {good, [principal: "mallory"], :principal_mismatch}
      ]

      for {params, opts, reason} <- cases do
        assert {:error, %Error{reason: ^reason, data: nil}} =
                 OAuth.handle_callback(pending, params, [config: config] ++ opts)
      end

      expired = %{pending | expires_at: pending.created_at}

      assert {:error, %Error{reason: :state_expired}} =
               OAuth.handle_callback(expired, good, config: config)

      # An error response from a different issuer is not surfaced.
      forged_error = %{
        "error" => "access_denied",
        "error_description" => "evil",
        "state" => good["state"],
        "iss" => "http://evil"
      }

      assert {:error, %Error{reason: :iss_mismatch, data: nil}} =
               OAuth.handle_callback(pending, forged_error, config: config)

      assert OAuthFake.count(fake, "POST", "/token") == 0
    end

    test "an error response from the right issuer is typed" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake)
      {:ok, url, pending} = OAuth.authorize_url(config)
      params = OAuthFake.approve(fake, url, error: "access_denied")

      assert {:error, %Error{reason: :access_denied, data: %{"error" => "access_denied"}}} =
               OAuth.handle_callback(pending, params, config: config)

      assert OAuthFake.count(fake, "POST", "/token") == 0
    end
  end

  # --- registration ------------------------------------------------------------------

  describe "registration priority" do
    test "pre-registered wins over CIMD and DCR" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake, pre_registered: %{fake.issuer => [client_id: "pre"]})

      {:ok, url, pending} = OAuth.authorize_url(config)
      assert pending.client_id == "pre"
      assert URI.decode_query(URI.parse(url).query)["client_id"] == "pre"
      assert OAuthFake.count(fake, "POST", "/register") == 0
    end

    test "CIMD wins over DCR; the client id is the document URL" do
      fake = fake() |> OAuthFake.serve_as()
      {:ok, _url, pending} = OAuth.authorize_url(config(fake))
      assert pending.client_id == @cimd
      assert OAuthFake.count(fake, "POST", "/register") == 0
    end

    test "DCR without CIMD support: application_type, refresh_token, stored under the issuer" do
      fake = fake()
      OAuthFake.serve_as(fake, metadata: %{"client_id_metadata_document_supported" => false})
      config = config(fake, client_metadata: [client_name: "Agent"])

      {:ok, _url, pending} = OAuth.authorize_url(config)
      assert "dcr-client-" <> _ = pending.client_id

      [register] = Enum.filter(OAuthFake.requests(fake), &(&1.path == "/register"))
      assert register.json["application_type"] == "native"
      assert register.json["grant_types"] == ["authorization_code", "refresh_token"]
      assert register.json["token_endpoint_auth_method"] == "none"
      assert register.json["redirect_uris"] == [@redirect]
      assert register.json["client_name"] == "Agent"

      assert {:ok, %{"client_id" => id}} = TokenStore.fetch_client(config.store, fake.issuer)
      assert id == pending.client_id

      # Reused while the redirect URI matches.
      {:ok, _url, again} = OAuth.authorize_url(config)
      assert again.client_id == id
      assert OAuthFake.count(fake, "POST", "/register") == 1

      # The token request uses it too.
      tokens = authorized(fake, config)
      assert %Tokens{} = tokens
    end

    test "nothing applies: :no_registration_method" do
      fake = fake()

      OAuthFake.serve_as(fake,
        metadata: %{
          "client_id_metadata_document_supported" => false,
          "registration_endpoint" => nil
        }
      )

      assert {:error, %Error{reason: :no_registration_method}} =
               OAuth.authorize_url(config(fake))
    end

    test "pre-registered credentials for another issuer: :authorization_server_changed (OA-6)" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake, pre_registered: %{"https://old-as.example.com" => [client_id: "old"]})

      assert {:error, %Error{reason: :authorization_server_changed}} =
               OAuth.authorize_url(config)

      no_token_calls(fake)
    end

    test "a client registered with one authorization server is never sent to another (OA-6)" do
      store = store()
      as1 = fake()
      OAuthFake.serve_as(as1, metadata: %{"client_id_metadata_document_supported" => false})
      {:ok, _url, first} = OAuth.authorize_url(config(as1, store: store))

      # The server now names another authorization server.
      as2 = OAuthFake.start()
      OAuthFake.serve_as(as2, metadata: %{"client_id_metadata_document_supported" => false})
      OAuthFake.serve_prm(as1, @prm_inserted, resource(as1), authorization_servers: [as2.issuer])

      {:ok, url, second} = OAuth.authorize_url(config(as1, store: store))
      assert second.issuer == as2.issuer
      assert OAuthFake.count(as2, "POST", "/register") == 1
      refute second.client_id == first.client_id
      refute URI.decode_query(URI.parse(url).query)["client_id"] == first.client_id
    end
  end

  # --- code exchange and tokens -----------------------------------------------------

  describe "code exchange" do
    test "the token request repeats redirect_uri and resource and carries the verifier" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake, principal: "alice")
      {:ok, url, pending} = OAuth.authorize_url(config)
      params = OAuthFake.approve(fake, url)

      assert {:ok, %Tokens{} = tokens} = OAuth.handle_callback(pending, params, config: config)
      assert tokens.scopes == ["read"]

      [token] = Enum.filter(OAuthFake.requests(fake), &(&1.path == "/token"))
      assert token.params["grant_type"] == "authorization_code"
      assert token.params["code_verifier"] == Secret.expose(pending.verifier)
      assert token.params["redirect_uri"] == @redirect
      assert token.params["resource"] == resource(fake)
      assert token.params["client_id"] == @cimd
      assert token.authorization == nil

      assert {:ok, ^tokens} =
               TokenStore.fetch_tokens(config.store, {"alice", fake.issuer, resource(fake)})

      assert {:ok, ^tokens} = OAuth.token_for(config, "alice")
      assert {:error, %Error{reason: :authorization_required}} = OAuth.token_for(config, "bob")
    end

    test "a pending authorization survives host storage (to_map/from_map)" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake)
      {:ok, url, pending} = OAuth.authorize_url(config)

      {:ok, restored} =
        pending |> Pending.to_map() |> JSON.encode!() |> JSON.decode!() |> Pending.from_map()

      assert {:ok, _tokens} =
               OAuth.handle_callback(restored, OAuthFake.approve(fake, url), config: config)
    end
  end

  describe "refresh" do
    test "an expired token is refreshed with resource; the rotated refresh token is persisted" do
      fake = fake() |> OAuthFake.serve_as()
      now = System.os_time(:second)
      config = config(fake, clock: fn -> now end)
      tokens = authorized(fake, config)
      key = {nil, fake.issuer, resource(fake)}
      :ok = TokenStore.put_tokens(config.store, key, %{tokens | expires_at: now + 10})

      # Within refresh_skew (30 s): refreshed.
      assert {:ok, fresh} = OAuth.token_for(config, nil)
      refute Secret.expose(fresh.access_token) == Secret.expose(tokens.access_token)

      [refresh] =
        Enum.filter(OAuthFake.requests(fake), &(&1.params["grant_type"] == "refresh_token"))

      assert refresh.params["resource"] == resource(fake)
      assert refresh.params["client_id"] == @cimd

      assert {:ok, stored} = TokenStore.fetch_tokens(config.store, key)
      assert Secret.expose(stored.refresh_token) == Secret.expose(fresh.refresh_token)
      refute Secret.expose(stored.refresh_token) == Secret.expose(tokens.refresh_token)

      # Fresh now: no further refresh.
      assert {:ok, ^stored} = OAuth.token_for(config, nil)
      assert OAuthFake.count(fake, "POST", "/token") == 2
    end

    test "a refresh that returns no new refresh token keeps the old one" do
      fake = fake(rotate: false) |> OAuthFake.serve_as()
      config = config(fake)
      tokens = authorized(fake, config)
      assert {:ok, refreshed} = OAuth.refresh(config, nil)
      assert Secret.expose(refreshed.refresh_token) == Secret.expose(tokens.refresh_token)
    end

    test "invalid_grant deletes the tokens and asks for authorization" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake)
      authorized(fake, config)
      OAuthFake.revoke_refresh_tokens(fake)

      assert {:error, %Error{reason: :authorization_required}} = OAuth.refresh(config, nil)
      assert TokenStore.fetch_tokens(config.store, {nil, fake.issuer, resource(fake)}) == :error
    end
  end

  # --- client credentials ------------------------------------------------------------

  defp cc_config(fake, credentials) do
    config(fake, [grant: :client_credentials, client_id: "svc", scopes: ["read"]] ++ credentials)
  end

  describe "client credentials" do
    test "client_secret_basic, cached, re-requested when expired" do
      fake = fake() |> OAuthFake.serve_as()
      OAuthFake.register_client(fake, "svc", {:secret, "s3cret"})
      now = System.os_time(:second)
      config = cc_config(fake, client_secret: "s3cret", clock: fn -> now end)

      assert {:ok, %Tokens{} = tokens} = OAuth.token_for(config, nil)
      assert {:ok, ^tokens} = OAuth.token_for(config, nil)
      assert OAuthFake.count(fake, "POST", "/token") == 1

      [token] = Enum.filter(OAuthFake.requests(fake), &(&1.path == "/token"))
      assert token.params["resource"] == resource(fake)
      assert token.params["scope"] == "read"
      assert "Basic " <> _ = token.authorization

      key = {nil, fake.issuer, resource(fake)}
      :ok = TokenStore.put_tokens(config.store, key, %{tokens | expires_at: now})
      assert {:ok, renewed} = OAuth.token_for(config, nil)
      refute Secret.expose(renewed.access_token) == Secret.expose(tokens.access_token)
    end

    test "client_secret_post with {:system, VAR}" do
      fake = fake() |> OAuthFake.serve_as()
      OAuthFake.register_client(fake, "svc", {:secret, "from-env"})
      var = "CONDUIT_OAUTH_TEST_#{System.unique_integer([:positive])}"
      System.put_env(var, "from-env")
      on_exit(fn -> System.delete_env(var) end)

      config =
        cc_config(fake,
          client_secret: {:system, var},
          token_endpoint_auth_method: :client_secret_post
        )

      assert {:ok, _tokens} = OAuth.token_for(config, nil)
      [token] = Enum.filter(OAuthFake.requests(fake), &(&1.path == "/token"))
      assert token.params["client_secret"] == "from-env"
      assert token.authorization == nil
      refute inspect(config) =~ "from-env"
    end

    test "an unset {:system, VAR} is an error, not an empty secret" do
      fake = fake() |> OAuthFake.serve_as()
      config = cc_config(fake, client_secret: {:system, "CONDUIT_OAUTH_TEST_UNSET_VAR"})

      assert {:error, %Error{reason: :client_secret_unavailable}} = OAuth.token_for(config, nil)
      assert OAuthFake.count(fake, "POST", "/token") == 0
    end

    test "private_key_jwt: an ES256 assertion for the token endpoint" do
      fake = fake() |> OAuthFake.serve_as()
      jwk = JOSE.JWK.generate_key({:ec, "P-256"})
      {_, private} = JOSE.JWK.to_map(jwk)
      OAuthFake.register_client(fake, "svc", {:jwt, JOSE.JWK.to_public(jwk)})

      config = cc_config(fake, private_key: private, private_key_alg: "ES256")
      assert config.credentials.auth_method == :private_key_jwt
      refute inspect(config) =~ private["d"]

      assert {:ok, %Tokens{}} = OAuth.token_for(config, nil)
      [token] = Enum.filter(OAuthFake.requests(fake), &(&1.path == "/token"))
      refute Map.has_key?(token.params, "client_secret")
    end

    test "a wrong secret fails the token request" do
      fake = fake() |> OAuthFake.serve_as()
      OAuthFake.register_client(fake, "svc", {:secret, "right"})
      config = cc_config(fake, client_secret: "wrong")

      assert {:error, %Error{reason: :token_request_failed, data: %{error: "invalid_client"}}} =
               OAuth.token_for(config, nil)
    end

    test "configuration: a client id and a credential are required" do
      assert_raise ArgumentError, ~r/client_id/, fn ->
        Config.new!(server_url: "https://mcp.example.com", grant: :client_credentials)
      end

      assert_raise ArgumentError, ~r/client_secret or a :private_key/, fn ->
        Config.new!(
          server_url: "https://mcp.example.com",
          grant: :client_credentials,
          client_id: "x"
        )
      end
    end
  end

  # --- loopback -------------------------------------------------------------------------

  describe "Loopback" do
    test "the open: callback's browser lands on a one-shot 127.0.0.1 server" do
      fake = fake() |> OAuthFake.serve_as()
      config = config(fake, redirect_uri: nil)
      {:ok, _} = Application.ensure_all_started(:inets)
      test = self()

      open = fn url ->
        # The "browser": GET the authorization URL; the fake redirects to
        # the loopback redirect URI, which httpc follows.
        {:ok, {{_, 200, _}, _headers, body}} = :httpc.request(String.to_charlist(url))
        send(test, {:page, to_string(body), url})
      end

      assert {:ok, %Tokens{}} = OAuth.Loopback.run(config, open: open, timeout: 2_000)
      assert_received {:page, page, url}
      assert page =~ "Authorization complete"

      redirect = URI.decode_query(URI.parse(url).query)["redirect_uri"]
      assert %URI{host: "127.0.0.1", path: "/callback", port: port} = URI.parse(redirect)

      # The listener is gone.
      assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", port, [], 200)
      assert {:ok, _} = TokenStore.fetch_tokens(config.store, {nil, fake.issuer, resource(fake)})
    end

    test "start/1 and await/2 serve exactly one callback" do
      {:ok, loopback} = OAuth.Loopback.start(path: "/cb")
      {:ok, _} = Application.ensure_all_started(:inets)
      callback = loopback.redirect_uri <> "?code=c&state=s"

      task =
        Task.async(fn ->
          first = :httpc.request(String.to_charlist(callback))
          second = :httpc.request(String.to_charlist(callback))
          {first, second}
        end)

      assert {:ok, %{"code" => "c", "state" => "s"}} = OAuth.Loopback.await(loopback, 2_000)
      {{:ok, {{_, 200, _}, _, _}}, second} = Task.await(task)

      case second do
        {:ok, {{_, 410, _}, _, _}} -> :ok
        {:error, _closed} -> :ok
      end
    end

    test "await/2 times out and stops the server" do
      {:ok, loopback} = OAuth.Loopback.start()
      assert {:error, :timeout} = OAuth.Loopback.await(loopback, 10)
      refute Process.alive?(loopback.server)
    end
  end
end

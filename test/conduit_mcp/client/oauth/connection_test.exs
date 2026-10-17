defmodule ConduitMcp.Test.Client.OAuthScopedServer do
  @moduledoc "A DSL server for the OAuth end-to-end tests: one open tool, one needing `admin`."
  use ConduitMcp.Server

  tool "echo", "Echoes the message" do
    param(:message, :string, "Message", required: true)
    handle(fn _conn, %{"message" => message} -> text(message) end)
  end

  tool "admin_op", "Needs the admin scope" do
    scope("admin")
    handle(fn _conn, _params -> text("admin ok") end)
  end
end

defmodule ConduitMcp.Client.OAuth.ConnectionTest do
  # The OAuth client end to end: `ConduitMcp.Client` (Streamable HTTP,
  # `auth: {:oauth, ...}`) against this library's own server protected by
  # `ConduitMcp.Plugs.OAuth`, with tokens minted by the fake authorization
  # server (`ConduitMcp.Test.Client.OAuthFake`), in both protocol eras.
  use ExUnit.Case, async: true

  @moduletag :integration

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.{Challenge, Tokens, TokenStore}
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.OAuthFake
  alias ConduitMcp.Test.Client.OAuthScopedServer

  @cimd "https://app.example.com/oauth/client.json"
  @redirect "http://127.0.0.1:9/callback"

  defp setup_servers(opts \\ []) do
    fake = OAuthFake.start(Keyword.merge([jwt: true], opts)) |> OAuthFake.serve_as()
    url = OAuthFake.serve_mcp(fake, OAuthScopedServer, scopes_supported: ["read"])
    {fake, url}
  end

  defp start_client(url, era, oauth \\ [], client_opts \\ []) do
    name = Keyword.get_lazy(client_opts, :name, fn -> {__MODULE__, make_ref()} end)
    test = self()

    oauth =
      Keyword.merge(
        [
          redirect_uri: @redirect,
          client_metadata_url: @cimd,
          allow_insecure_oauth: true,
          on_authorization_required: fn challenge -> send(test, {:authorize, name, challenge}) end
        ],
        oauth
      )

    start_supervised!(
      {Client,
       Keyword.merge(
         [
           name: name,
           protocol: era,
           transport: {StreamableHTTP, url: url <> "/", auth: {:oauth, oauth}},
           backoff: fn _attempt -> 0 end
         ],
         client_opts
       )},
      id: name
    )

    name
  end

  # The host's side of an interactive authorization: the URL, the user's
  # approval at the fake, and the callback.
  defp authorize(fake, name, challenge, opts \\ []) do
    {:ok, url, pending} = OAuth.authorize_url(name, Keyword.put(opts, :challenge, challenge))
    params = OAuthFake.approve(fake, url)
    {:ok, %Tokens{} = tokens} = OAuth.handle_callback(pending, params, client: name)
    {url, tokens}
  end

  defp state(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {state, _data} = :sys.get_state(conn)
    state
  end

  for era <- [:legacy, :modern] do
    describe "#{era} era" do
      @era era

      test "authorizes interactively, then serves tools with the bearer" do
        {fake, url} = setup_servers()
        name = start_client(url, @era)

        assert_receive {:authorize, ^name, %Challenge{} = challenge}, 2_000

        assert Challenge.resource_metadata(challenge) ==
                 url <> "/.well-known/oauth-protected-resource"

        assert state(name) == :authorizing

        # Interactive authorization never blocks: a request fails at once.
        assert {:error, %Error{kind: :auth, reason: :authorization_required, data: data}} =
                 Client.list_tools(name)

        assert %Challenge{} = data.challenge

        {authorize_url, _tokens} = authorize(fake, name, challenge)
        query = authorize_url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        assert query["client_id"] == @cimd
        assert query["code_challenge_method"] == "S256"
        assert query["resource"] == url
        assert query["scope"] == "read"
        assert query["redirect_uri"] == @redirect

        assert :ok = Client.await_ready(name, 2_000)
        assert {:ok, %{tools: tools}} = Client.list_tools(name)
        assert Enum.any?(tools, &(&1.name == "echo"))

        assert {:ok, %ToolResult{content: [%{"text" => "hi"}]}} =
                 Client.call_tool(name, "echo", %{"message" => "hi"})

        # Every MCP request after the authorization carried the bearer; no
        # authorization-server request ever did.
        mcp = Enum.filter(OAuthFake.requests(fake), &match?({:mcp, _}, &1.target))
        assert Enum.any?(mcp, &match?("Bearer " <> _, &1.authorization))
        as = Enum.filter(OAuthFake.requests(fake), &(&1.target == :as))
        assert as != []
        assert Enum.all?(as, &(&1.authorization == nil))
      end

      test "a 403 insufficient_scope steps up with the union of scopes, at most twice" do
        {fake, url} = setup_servers()
        name = start_client(url, @era)
        assert_receive {:authorize, ^name, challenge}, 2_000
        authorize(fake, name, challenge)
        assert :ok = Client.await_ready(name, 2_000)

        assert {:error, %Error{kind: :auth, reason: :authorization_required, data: data}} =
                 Client.call_tool(name, "admin_op", %{})

        assert Challenge.insufficient_scope?(data.challenge)
        assert Challenge.scopes(data.challenge) == ["read", "admin"]
        assert_receive {:authorize, ^name, step_up}, 1_000
        assert Challenge.scopes(step_up) == ["read", "admin"]

        # The host authorizes the union; the call then succeeds.
        {authorize_url, tokens} = authorize(fake, name, step_up)
        assert tokens.scopes == ["read", "admin"]
        assert URI.decode_query(URI.parse(authorize_url).query)["scope"] == "read admin"

        assert {:ok, %ToolResult{content: [%{"text" => "admin ok"}]}} =
                 Client.call_tool(name, "admin_op", %{})

        assert state(name) == :ready
      end
    end
  end

  test "step-up stops after max_step_up_attempts for the same scope set" do
    {fake, url} = setup_servers()
    name = start_client(url, :modern, max_step_up_attempts: 2)
    assert_receive {:authorize, ^name, challenge}, 2_000
    authorize(fake, name, challenge)
    assert :ok = Client.await_ready(name, 2_000)

    # The host never grants admin: two step-ups, then the limit.
    for _ <- 1..2 do
      assert {:error, %Error{reason: :authorization_required}} =
               Client.call_tool(name, "admin_op", %{})

      assert_receive {:authorize, ^name, _step_up}, 1_000
    end

    assert {:error, %Error{kind: :auth, reason: :step_up_limit}} =
             Client.call_tool(name, "admin_op", %{})

    refute_receive {:authorize, ^name, _}
    assert {:ok, _result} = Client.call_tool(name, "echo", %{"message" => "still fine"})
  end

  test "an expired access token is refreshed before the request, rotating the refresh token" do
    {fake, url} = setup_servers()
    store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
    start_supervised!(store)
    name = start_client(url, :modern, store: store)
    assert_receive {:authorize, ^name, challenge}, 2_000
    {_url, tokens} = authorize(fake, name, challenge)
    assert :ok = Client.await_ready(name, 2_000)

    key = {nil, fake.issuer, url}
    assert {:ok, ^tokens} = TokenStore.fetch_tokens(store, key)

    # Expire it locally; the next request refreshes first (in the request
    # process), with `resource`, and keeps the rotated refresh token.
    :ok = TokenStore.put_tokens(store, key, %{tokens | expires_at: 0})
    assert {:ok, _} = Client.call_tool(name, "echo", %{"message" => "after refresh"})

    [refresh] =
      Enum.filter(OAuthFake.requests(fake), &(&1.params["grant_type"] == "refresh_token"))

    assert refresh.params["resource"] == url
    assert refresh.params["refresh_token"] == Secret.expose(tokens.refresh_token)

    assert {:ok, rotated} = TokenStore.fetch_tokens(store, key)
    refute Secret.expose(rotated.refresh_token) == Secret.expose(tokens.refresh_token)
    refute Secret.expose(rotated.access_token) == Secret.expose(tokens.access_token)
  end

  test "a revoked refresh token deletes the tokens and asks the host again" do
    {fake, url} = setup_servers()
    name = start_client(url, :modern)
    assert_receive {:authorize, ^name, challenge}, 2_000
    {_url, tokens} = authorize(fake, name, challenge)
    assert :ok = Client.await_ready(name, 2_000)

    store = TokenStore.ETS.default(name)
    key = {nil, fake.issuer, url}
    :ok = TokenStore.put_tokens(store, key, %{tokens | expires_at: 0})
    OAuthFake.revoke_refresh_tokens(fake)

    # The request goes without a token, the server says 401, the check finds
    # nothing usable: the host is asked again and the call fails fast.
    assert {:error, %Error{kind: :auth, reason: :authorization_required}} =
             Client.call_tool(name, "echo", %{"message" => "x"})

    assert_receive {:authorize, ^name, _challenge}, 2_000
    assert TokenStore.fetch_tokens(store, key) == :error
  end

  test "tokens stored by the host are picked up by the next request" do
    {fake, url} = setup_servers()
    name = start_client(url, :modern)
    assert_receive {:authorize, ^name, challenge}, 2_000

    # The host completes the flow against a standalone config sharing the
    # client's store, without telling the client.
    {:ok, auth_url, pending} = OAuth.authorize_url(name, challenge: challenge)
    params = OAuthFake.approve(fake, auth_url)

    config =
      OAuth.Config.new!(
        server_url: url,
        store: TokenStore.ETS.default(name),
        allow_insecure_oauth: true
      )

    assert {:ok, _tokens} = OAuth.handle_callback(pending, params, config: config)
    assert state(name) == :authorizing

    assert {:ok, %{tools: tools}} = Client.list_tools(name)
    assert Enum.any?(tools, &(&1.name == "echo"))
  end

  test "two servers behind one authorization server hold separate tokens" do
    fake = OAuthFake.start(jwt: true) |> OAuthFake.serve_as()
    url_a = OAuthFake.serve_mcp(fake, OAuthScopedServer)
    url_b = OAuthFake.serve_mcp(fake, OAuthScopedServer)
    store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
    start_supervised!(store)

    a = start_client(url_a, :modern, store: store)
    b = start_client(url_b, :modern, store: store)
    assert_receive {:authorize, ^a, challenge_a}, 2_000
    assert_receive {:authorize, ^b, _challenge_b}, 2_000

    {_url, tokens_a} = authorize(fake, a, challenge_a)
    assert :ok = Client.await_ready(a, 2_000)

    # B still needs its own authorization; A's token never reaches B.
    assert {:error, %Error{reason: :authorization_required}} = Client.list_tools(b)
    bearer_a = "Bearer " <> Secret.expose(tokens_a.access_token)

    sent_to_b =
      for %{target: {:mcp, ^url_b}, authorization: auth} <- OAuthFake.requests(fake), do: auth

    assert sent_to_b != []
    refute bearer_a in sent_to_b
    assert TokenStore.fetch_tokens(store, {nil, fake.issuer, url_b}) == :error
  end

  test "client credentials: no user, the token is requested and the server accepts it" do
    {fake, url} = setup_servers()
    OAuthFake.register_client(fake, "svc", {:secret, "s3cret"})
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       name: name,
       protocol: :modern,
       transport:
         {StreamableHTTP,
          url: url <> "/",
          auth:
            {:client_credentials,
             client_id: "svc",
             client_secret: "s3cret",
             scopes: ["read"],
             allow_insecure_oauth: true}},
       backoff: fn _ -> 0 end}
    )

    assert :ok = Client.await_ready(name, 2_000)
    assert {:ok, _result} = Client.call_tool(name, "echo", %{"message" => "m2m"})

    [token] = Enum.filter(OAuthFake.requests(fake), &(&1.path == "/token"))
    assert token.params["grant_type"] == "client_credentials"
    assert token.params["resource"] == url
    assert "Basic " <> _ = token.authorization
  end

  test "a client-credentials step-up requests a token with the union of scopes" do
    {fake, url} = setup_servers()
    OAuthFake.register_client(fake, "svc", {:secret, "s3cret"})
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       name: name,
       protocol: :legacy,
       transport:
         {StreamableHTTP,
          url: url <> "/",
          auth:
            {:client_credentials,
             client_id: "svc",
             client_secret: "s3cret",
             scopes: ["read"],
             allow_insecure_oauth: true}},
       backoff: fn _ -> 0 end}
    )

    assert :ok = Client.await_ready(name, 2_000)

    assert {:ok, %ToolResult{content: [%{"text" => "admin ok"}]}} =
             Client.call_tool(name, "admin_op", %{})

    scopes =
      for %{path: "/token", params: params} <- OAuthFake.requests(fake), do: params["scope"]

    assert scopes == ["read", "read admin"]
  end

  test "OAuth telemetry carries the allowlisted keys only, and no secret (TL-1)" do
    {fake, url} = setup_servers()
    name = {__MODULE__, make_ref()}

    events =
      [[:conduit_mcp, :client, :oauth, :authorization_required]] ++
        for op <- [:discovery, :registration, :token_exchange, :refresh, :step_up],
            phase <- [:start, :stop, :exception],
            do: [:conduit_mcp, :client, :oauth, op, phase]

    ConduitMcp.TelemetryTestHelper.attach_event_handlers(self(), events, match: %{client: name})

    name = start_client(url, :modern, [], name: name)
    assert_receive {:authorize, ^name, challenge}, 2_000
    {:ok, auth_url, pending} = OAuth.authorize_url(name, challenge: challenge)
    params = OAuthFake.approve(fake, auth_url)
    {:ok, tokens} = OAuth.handle_callback(pending, params, client: name)
    assert :ok = Client.await_ready(name, 2_000)
    assert {:ok, _} = OAuth.refresh(name)
    assert {:error, _} = Client.call_tool(name, "admin_op", %{})

    # The step-up span stops in the connection right after the reply.
    assert_receive {[:conduit_mcp, :client, :oauth, :step_up, :stop] = step_up, _, _,
                    step_up_meta},
                   1_000

    metadata = collect([{step_up, step_up_meta}])
    names = Enum.map(metadata, &elem(&1, 0))

    for op <- [:discovery, :registration, :token_exchange, :refresh, :step_up],
        do: assert([:conduit_mcp, :client, :oauth, op, :stop] in names, inspect(op))

    assert [:conduit_mcp, :client, :oauth, :authorization_required] in names

    allowed = [:client, :server_id, :principal, :status, :reason, :method, :grant, :kind]

    secrets = [
      Secret.expose(tokens.access_token),
      Secret.expose(tokens.refresh_token),
      params["code"],
      params["state"],
      Secret.expose(pending.verifier),
      url
    ]

    for {_event, meta} <- metadata do
      assert Map.keys(meta) -- allowed == [], inspect(Map.keys(meta))
      text = inspect(meta, limit: :infinity, printable_limit: :infinity)
      for secret <- secrets, do: refute(text =~ secret)
    end
  end

  defp collect(acc) do
    receive do
      {event, _ref, _measurements, metadata} when is_list(event) ->
        collect([{event, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Client.authorized/1 without OAuth is an error" do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       name: name,
       transport: {ConduitMcp.Client.Transport.InProcess, server: ConduitMcp.TestServer}}
    )

    assert {:error, %Error{kind: :auth, reason: :oauth_not_configured}} =
             Client.authorized(name)
  end

  test "the connection's crash report redacts the OAuth state" do
    {_fake, url} = setup_servers()
    name = start_client(url, :modern, client_secret_holder())
    assert_receive {:authorize, ^name, _challenge}, 2_000
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {:status, _pid, _module, items} = :sys.get_status(conn)
    refute inspect(items, limit: :infinity) =~ "pre-registered-secret"
  end

  defp client_secret_holder,
    do: [
      pre_registered: %{
        "https://other.example" => [client_id: "x", client_secret: "pre-registered-secret"]
      }
    ]
end

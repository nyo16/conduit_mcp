defmodule ConduitMcp.Test.Client.CredentialScopedServer do
  @moduledoc "Public tools, a private (default-scoped) prompt, for the HT-11 cache tests."
  use ConduitMcp.Server

  tool "catalog", "The public catalog" do
    cache(ttl_ms: 60_000, scope: :public)
    handle(fn _conn, _params -> text("catalog") end)
  end

  prompt "greeting", "A greeting only its user may see" do
    get(fn _conn, _args -> [user("hi")] end)
  end
end

defmodule ConduitMcp.Test.Client.CredentialOAuthServer do
  @moduledoc "A DSL server behind the fake authorization server (private by default)."
  use ConduitMcp.Server

  tool "echo", "Echoes the message" do
    param(:message, :string, "Message", required: true)
    handle(fn _conn, %{"message" => message} -> text(message) end)
  end
end

defmodule ConduitMcp.Client.CacheCredentialTest do
  # HT-11: a result the server marks `cacheScope: "private"` (the default)
  # is cached for the credential identity it was fetched with and served
  # only while the connection still sends that credential; public results
  # are shared. End to end over Streamable HTTP, with static bearers, `:auth`
  # functions and OAuth (the fake authorization server).
  use ExUnit.Case, async: true

  @moduletag :integration

  import ConduitMcp.Test.Client.Harness, only: [attach: 2, await_hub_ready: 2]

  alias ConduitMcp.Client
  alias ConduitMcp.Client.{Cache, Error, Hub, Request, ToolResult, ToolSet}
  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.{Tokens, TokenStore}
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.{CredentialOAuthServer, CredentialScopedServer}
  alias ConduitMcp.Test.Client.{HTTPDslServer, HTTPServers, OAuthFake}

  @refresh [:conduit_mcp, :client, :cache, :refresh, :start]
  @cimd "https://app.example.com/oauth/client.json"
  @redirect "http://127.0.0.1:9/callback"

  defp start_http(url, auth, client_opts) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       [
         name: name,
         protocol: :modern,
         transport: {StreamableHTTP, [url: url, auth: auth] ++ client_opts[:transport]},
         backoff: fn _attempt -> 0 end
       ] ++ Keyword.delete(client_opts, :transport)},
      id: name
    )

    :ok = Client.await_ready(name, 2_000)
    name
  end

  defp cache(name) do
    {:ok, _pid, view} = Request.lookup(name)
    view.cache
  end

  defp refreshed(ref, kind), do: assert_receive({@refresh, ^ref, _, %{kind: ^kind}})
  defp not_refreshed(ref, kind), do: refute_received({@refresh, ^ref, _, %{kind: ^kind}})

  describe "static bearer tokens" do
    setup do
      test = self()

      verify = fn token ->
        send(test, {:verified, token})
        if token in ["tok-a", "tok-b"], do: {:ok, %{id: token}}, else: {:error, :unknown}
      end

      url =
        HTTPServers.serve_mcp(CredentialScopedServer, auth: [strategy: :function, verify: verify])

      {:ok, url: url}
    end

    test "set_auth/3 with another token drops private lists at once; public ones stay",
         %{url: url} do
      name = start_http(url, {:bearer, "tok-a"}, transport: [])
      ref = attach(name, [@refresh])

      assert {:ok, [%{name: "catalog"}]} = Client.list_all_tools(name)
      assert {:ok, [%{name: "greeting"}]} = Client.list_all_prompts(name)
      refreshed(ref, :tools)
      refreshed(ref, :prompts)
      assert {:ok, %{scope: :public}} = Cache.list(cache(name), :tools)
      assert {:ok, %{scope: :private}} = Cache.list(cache(name), :prompts)

      # Served from the cache while the token is the same.
      assert {:ok, [_]} = Client.list_all_prompts(name)
      not_refreshed(ref, :prompts)

      assert :ok = Client.set_auth(name, {:bearer, "tok-b"})
      assert :miss = Cache.list(cache(name), :prompts)
      assert {:ok, [%{name: "catalog"}]} = Client.cached_tools(name)

      assert :ok = Client.await_ready(name, 2_000)
      assert {:ok, [%{name: "greeting"}]} = Client.list_all_prompts(name)
      refreshed(ref, :prompts)
      assert_received {:verified, "tok-b"}
      assert {:ok, %{scope: :private}} = Cache.list(cache(name), :prompts)
    end

    test "set_auth/3 with the same token keeps private lists", %{url: url} do
      name = start_http(url, {:bearer, "tok-a"}, transport: [])
      assert {:ok, [_]} = Client.list_all_prompts(name)

      assert :ok = Client.set_auth(name, {:bearer, Secret.new("tok-a")})
      assert {:ok, %{items: [%{name: "greeting"}]}} = Cache.list(cache(name), :prompts)
    end

    test "set_auth/3 refuses what the transport would", %{url: url} do
      name = start_http(url, {:bearer, "tok-a"}, transport: [])

      assert_raise ArgumentError, ~r/expected nil, \{:bearer, token\}/, fn ->
        Client.set_auth(name, :nonsense)
      end

      assert_raise ArgumentError, ~r/:credential_id option: it needs an :auth function/, fn ->
        Client.set_auth(name, {:bearer, "tok-b"}, credential_id: "svc")
      end

      assert_raise ArgumentError, ~r/no token store; name a :store/, fn ->
        Client.set_auth(name, {:oauth, redirect_uri: @redirect, allow_insecure_oauth: true})
      end

      # Nothing changed.
      assert {:ok, [_]} = Client.list_all_prompts(name)
      assert_received {:verified, "tok-a"}
      refute_received {:verified, "tok-b"}
    end
  end

  describe "an :auth function" do
    setup do
      {:ok, url: HTTPServers.serve_mcp(HTTPDslServer)}
    end

    test "without :credential_id, private results are never served from the cache",
         %{url: url} do
      name = start_http(url, fn _request -> {:ok, "tok"} end, transport: [])
      ref = attach(name, [@refresh])

      assert {:ok, [_ | _]} = Client.list_all_tools(name)
      assert {:ok, [_ | _]} = Client.list_all_tools(name)
      refreshed(ref, :tools)
      refreshed(ref, :tools)
      assert :miss = Cache.list(cache(name), :tools)
      assert {:error, %Error{reason: :not_cached}} = Client.cached_tools(name)

      # A call still finds the definition for its `Mcp-Param-*` headers.
      assert {:ok, %ToolResult{content: [%{"text" => "region: eu"}]}} =
               Client.call_tool(name, "region", %{"region" => "eu"})
    end

    test "a governed call resolves the tool from the list it fetched", %{url: url} do
      name =
        start_http(url, fn _request -> {:ok, "tok"} end,
          transport: [],
          policy: ConduitMcp.Client.Policy.allow_all()
        )

      assert {:ok, %ToolResult{is_error: false, content: [%{"text" => "region: eu"}]}} =
               Client.call_tool(name, "region", %{"region" => "eu"})

      assert :miss = Cache.list(cache(name), :tools)
    end

    test "with :credential_id, private results are cached for that identity", %{url: url} do
      name =
        start_http(url, fn _request -> {:ok, "tok"} end, transport: [credential_id: "svc"])

      ref = attach(name, [@refresh])
      assert {:ok, [_ | _]} = Client.list_all_tools(name)
      assert {:ok, [_ | _]} = Client.list_all_tools(name)
      refreshed(ref, :tools)
      not_refreshed(ref, :tools)

      # Another declared identity is another credential.
      assert :ok =
               Client.set_auth(name, fn _request -> {:ok, "other"} end, credential_id: "other")

      assert :miss = Cache.list(cache(name), :tools)
    end

    test "a hub offers the server's tools on every listing", %{url: url} do
      hub = {__MODULE__, make_ref()}

      start_supervised!(
        {Hub,
         name: hub,
         policy: :allow_all,
         servers: [
           web: [
             protocol: :modern,
             transport: {StreamableHTTP, url: url, auth: fn _request -> {:ok, "tok"} end}
           ]
         ]}
      )

      await_hub_ready(hub, ["web"])

      for _listing <- 1..3 do
        {:ok, toolset} = Hub.list_tools(hub)
        assert "web__region" in ToolSet.names(toolset)
      end
    end
  end

  describe "OAuth" do
    defp oauth_servers do
      fake = OAuthFake.start(jwt: true) |> OAuthFake.serve_as()
      url = OAuthFake.serve_mcp(fake, CredentialOAuthServer, scopes_supported: ["read"])
      {fake, url}
    end

    defp oauth_opts(name, extra) do
      test = self()

      [
        redirect_uri: @redirect,
        client_metadata_url: @cimd,
        allow_insecure_oauth: true,
        on_authorization_required: fn challenge -> send(test, {:authorize, name, challenge}) end
      ] ++ extra
    end

    defp start_oauth(url, extra) do
      name = {__MODULE__, make_ref()}

      start_supervised!(
        {Client,
         name: name,
         protocol: :modern,
         transport: {StreamableHTTP, url: url <> "/", auth: {:oauth, oauth_opts(name, extra)}},
         backoff: fn _attempt -> 0 end},
        id: name
      )

      name
    end

    # The host's side of an interactive authorization, for the principal the
    # client is configured with now.
    defp authorize(fake, name) do
      assert_receive {:authorize, ^name, challenge}, 2_000
      {:ok, url, pending} = OAuth.authorize_url(name, challenge: challenge)
      params = OAuthFake.approve(fake, url)
      {:ok, %Tokens{}} = OAuth.handle_callback(pending, params, client: name)
      assert :ok = Client.await_ready(name, 2_000)
    end

    test "a private list fetched for one principal is not served after re-authorizing as another" do
      {fake, url} = oauth_servers()
      name = start_oauth(url, principal: "alice")
      authorize(fake, name)
      ref = attach(name, [@refresh])

      assert {:ok, [%{name: "echo"}]} = Client.list_all_tools(name)
      assert {:ok, [_]} = Client.list_all_tools(name)
      refreshed(ref, :tools)
      not_refreshed(ref, :tools)

      assert :ok = Client.set_auth(name, {:oauth, oauth_opts(name, principal: "bob")})
      assert {:error, %Error{reason: :not_cached}} = Client.cached_tools(name)

      authorize(fake, name)
      assert {:ok, [%{name: "echo"}]} = Client.list_all_tools(name)
      refreshed(ref, :tools)

      # One store, tokens per principal.
      store = TokenStore.ETS.default(name)
      assert {:ok, _} = TokenStore.fetch_tokens(store, {"alice", fake.issuer, url})
      assert {:ok, _} = TokenStore.fetch_tokens(store, {"bob", fake.issuer, url})
    end

    test "a token refresh for the same principal keeps serving the cache" do
      {fake, url} = oauth_servers()
      name = start_oauth(url, [])
      authorize(fake, name)
      ref = attach(name, [@refresh])

      assert {:ok, [_]} = Client.list_all_tools(name)
      refreshed(ref, :tools)

      store = TokenStore.ETS.default(name)
      key = {nil, fake.issuer, url}

      refreshes = fn ->
        Enum.count(OAuthFake.requests(fake), &(&1.params["grant_type"] == "refresh_token"))
      end

      # An expired token is refreshed in the request process before sending.
      {:ok, tokens} = TokenStore.fetch_tokens(store, key)
      :ok = TokenStore.put_tokens(store, key, %{tokens | expires_at: 0})

      assert {:ok, %ToolResult{is_error: false}} =
               Client.call_tool(name, "echo", %{"message" => "a"})

      assert refreshes.() == 1

      assert {:ok, [_]} = Client.list_all_tools(name)
      not_refreshed(ref, :tools)

      # A token the server refuses: the 401 sends the connection through its
      # own refresh, and the new session reaches the transport with the same
      # identity, so the private list stays.
      {:ok, tokens} = TokenStore.fetch_tokens(store, key)
      :ok = TokenStore.put_tokens(store, key, %{tokens | access_token: Secret.new("refused")})

      assert {:ok, %ToolResult{is_error: false}} =
               Client.call_tool(name, "echo", %{"message" => "b"})

      assert refreshes.() == 2

      assert {:ok, %{items: [%{name: "echo"}], scope: :private}} =
               Cache.list(cache(name), :tools)

      assert {:ok, [%{name: "echo"}]} = Client.cached_tools(name)
    end
  end
end

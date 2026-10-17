defmodule ConduitMcp.Test.Client.OAuthHubServer do
  @moduledoc "A DSL server for the hub token-store test: one open tool."
  use ConduitMcp.Server

  tool "echo", "Echoes the message" do
    param(:message, :string, "Message", required: true)
    handle(fn _conn, %{"message" => message} -> text(message) end)
  end
end

defmodule ConduitMcp.Client.OAuth.HubStoreTest do
  # A `ConduitMcp.Client.Hub` starts one in-memory token store for all its
  # servers (CS X-18): servers behind the same authorization server share
  # its dynamic client registration, hold separate tokens per resource
  # (OA-5), and keep them when their client is restarted.
  use ExUnit.Case, async: true

  @moduletag :integration

  import ConduitMcp.Test.Client.Harness, only: [eventually: 1]

  alias ConduitMcp.Client
  alias ConduitMcp.Client.{Hub, Registry, Secret, ToolResult}
  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.TokenStore
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.OAuthFake
  alias ConduitMcp.Test.Client.OAuthHubServer

  @redirect "http://127.0.0.1:9/callback"

  defp server(id, url, oauth \\ []) do
    test = self()

    oauth =
      Keyword.merge(
        [
          redirect_uri: @redirect,
          allow_insecure_oauth: true,
          on_authorization_required: fn challenge -> send(test, {:authorize, id, challenge}) end
        ],
        oauth
      )

    {id,
     [
       protocol: :modern,
       transport: {StreamableHTTP, url: url <> "/", auth: {:oauth, oauth}},
       backoff: fn _attempt -> 0 end
     ]}
  end

  defp start_hub(servers) do
    hub = {__MODULE__, make_ref()}

    start_supervised!(
      {Hub, name: hub, policy: :allow_all, servers: servers, restart_backoff: fn _ -> 0 end}
    )

    hub
  end

  defp authorize(fake, client, challenge) do
    {:ok, url, pending} = OAuth.authorize_url(client, challenge: challenge)
    params = OAuthFake.approve(fake, url)
    {:ok, tokens} = OAuth.handle_callback(pending, params, client: client)
    assert :ok = Client.await_ready(client, 2_000)
    tokens
  end

  defp kill_client(hub, id) do
    {:ok, pid, _} = Registry.lookup({:supervisor, Hub.client(hub, id)})
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    # The Registry drops the dead client's entry asynchronously.
    eventually(fn ->
      match?({:ok, new, _} when new != pid, Registry.lookup({:supervisor, Hub.client(hub, id)}))
    end)
  end

  test "servers share one registration, keep tokens per resource, and across a restart" do
    fake = OAuthFake.start(jwt: true) |> OAuthFake.serve_as()
    url_a = OAuthFake.serve_mcp(fake, OAuthHubServer)
    url_b = OAuthFake.serve_mcp(fake, OAuthHubServer)
    hub = start_hub([server("a", url_a), server("b", url_b)])

    tokens =
      for id <- ["a", "b"], into: %{} do
        assert_receive {:authorize, ^id, challenge}, 2_000
        {id, authorize(fake, Hub.client(hub, id), challenge)}
      end

    # One dynamic registration with the shared authorization server ...
    assert OAuthFake.count(fake, "POST", "/register") == 1

    # ... but a token per resource, each sent to its own server only.
    refute Secret.expose(tokens["a"].access_token) == Secret.expose(tokens["b"].access_token)

    for {id, url} <- [{"a", url_a}, {"b", url_b}] do
      assert {:ok, held} = OAuth.token_for(Hub.client(hub, id))
      assert Secret.expose(held.access_token) == Secret.expose(tokens[id].access_token)
      bearer = "Bearer " <> Secret.expose(tokens[id].access_token)

      sent =
        for %{target: {:mcp, ^url}, authorization: auth} <- OAuthFake.requests(fake), do: auth

      assert bearer in sent
    end

    token_requests = OAuthFake.count(fake, "POST", "/token")

    # A restarted server client finds its tokens in the hub's store: no
    # new authorization, no new token request.
    kill_client(hub, "a")
    eventually(fn -> Client.await_ready(Hub.client(hub, "a"), 1_000) == :ok end)

    assert {:ok, %ToolResult{content: [%{"text" => "back"}]}} =
             Hub.call_tool(hub, "a__echo", %{"message" => "back"})

    refute_received {:authorize, "a", _challenge}
    assert OAuthFake.count(fake, "POST", "/token") == token_requests
    assert OAuthFake.count(fake, "POST", "/register") == 1
  end

  test "a server's own store is kept" do
    fake = OAuthFake.start(jwt: true) |> OAuthFake.serve_as()
    url = OAuthFake.serve_mcp(fake, OAuthHubServer)
    store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
    start_supervised!(store)
    hub = start_hub([server("a", url, store: store)])

    assert_receive {:authorize, "a", challenge}, 2_000
    tokens = authorize(fake, Hub.client(hub, "a"), challenge)

    assert {:ok, stored} = TokenStore.fetch_tokens(store, {nil, fake.issuer, url})
    assert Secret.expose(stored.access_token) == Secret.expose(tokens.access_token)
  end
end

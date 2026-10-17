defmodule ConduitMcp.Client.OAuth.SingleFlightTest do
  # OA-9: fifty processes finding the same expired token refresh it once.
  # `async: false`: the default lock is `:global`, node-wide.
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.{Config, TokenStore}
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Test.Client.OAuthFake

  test "50 concurrent callers with an expired token cause exactly one refresh" do
    fake = OAuthFake.start()
    OAuthFake.serve_prm(fake, "/.well-known/oauth-protected-resource/mcp", fake.url <> "/mcp")
    OAuthFake.serve_as(fake)

    store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
    start_supervised!(store)

    config =
      Config.new!(
        server_url: fake.url <> "/mcp",
        redirect_uri: "http://127.0.0.1:9/callback",
        client_metadata_url: "https://app.example.com/oauth/client.json",
        allow_insecure_oauth: true,
        store: store
      )

    {:ok, url, pending} = OAuth.authorize_url(config)
    {:ok, tokens} = OAuth.handle_callback(pending, OAuthFake.approve(fake, url), config: config)
    key = {nil, fake.issuer, fake.url <> "/mcp"}
    :ok = TokenStore.put_tokens(store, key, %{tokens | expires_at: 0})

    test = self()

    callers =
      for _ <- 1..50 do
        Task.async(fn ->
          send(test, {:ready, self()})

          receive do
            :go -> OAuth.token_for(config, nil)
          end
        end)
      end

    for _ <- callers, do: assert_receive({:ready, _pid})
    Enum.each(callers, &send(&1.pid, :go))
    results = Task.await_many(callers, 30_000)

    access = for {:ok, tokens} <- results, uniq: true, do: Secret.expose(tokens.access_token)
    assert length(access) == 1
    assert length(results) == 50

    refreshes =
      Enum.count(OAuthFake.requests(fake), &(&1.params["grant_type"] == "refresh_token"))

    assert refreshes == 1
  end
end

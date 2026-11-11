# Task 2.1: SEC-H1 repro. Run with
#   mix test .claude/plans/hardening-0.11.1/research/sec_h1_repro_test.exs
defmodule SecH1ReproTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.{Config, TokenStore}
  alias ConduitMcp.Test.Client.OAuthFake

  test "client_credentials without :expected_issuers posts the secret to the AS the MCP server names" do
    real = OAuthFake.start() |> OAuthFake.serve_as()
    OAuthFake.register_client(real, "svc", {:secret, "s3cret"})

    attacker = OAuthFake.start() |> OAuthFake.serve_as()

    # The MCP server (hosted by `real`) names the attacker's AS in its PRM.
    OAuthFake.serve_prm(real, "/.well-known/oauth-protected-resource/mcp", real.url <> "/mcp",
      authorization_servers: [attacker.issuer]
    )

    store = {TokenStore.ETS, name: {__MODULE__, make_ref()}}
    start_supervised!(store)

    config =
      Config.new!(
        server_url: real.url <> "/mcp",
        grant: :client_credentials,
        client_id: "svc",
        client_secret: "s3cret",
        scopes: ["read"],
        allow_insecure_oauth: true,
        store: store
      )

    result = OAuth.token_for(config, nil)
    IO.inspect(result, label: "token_for")

    token_requests = Enum.filter(OAuthFake.requests(attacker), &(&1.path == "/token"))
    IO.inspect(token_requests, label: "attacker /token requests")

    leaked =
      Enum.any?(token_requests, fn r ->
        r.authorization == "Basic " <> Base.encode64("svc:s3cret") or
          r.params["client_secret"] == "s3cret"
      end)

    IO.puts("LEAKED: #{leaked}")
    assert leaked
  end
end

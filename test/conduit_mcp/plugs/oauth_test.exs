defmodule ConduitMcp.Plugs.OAuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.OAuth

  # Generate a test RSA key pair for signing JWTs
  @rsa_key JOSE.JWK.generate_key({:rsa, 2048})
  @rsa_key_map @rsa_key |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "test-key")
  @rsa_public_key @rsa_key
                  |> JOSE.JWK.to_public()
                  |> JOSE.JWK.to_map()
                  |> elem(1)
                  |> Map.put("kid", "test-key")

  @oauth_opts OAuth.init(
                issuer: "https://auth.example.com",
                audience: "https://mcp.example.com",
                scopes_supported: ["read", "write", "admin"],
                key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public_key]}
              )

  defp sign_token(claims) do
    signer = Joken.Signer.create("RS256", @rsa_key_map)

    default_claims = %{
      "iss" => "https://auth.example.com",
      "aud" => "https://mcp.example.com",
      "sub" => "user-123",
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    merged = Map.merge(default_claims, claims)
    {:ok, token, _claims} = Joken.encode_and_sign(merged, signer)
    token
  end

  describe "valid token" do
    test "authenticates with valid JWT" do
      token = sign_token(%{"scope" => "read write"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      refute result.halted
      assert result.assigns[:oauth_claims]["sub"] == "user-123"
      assert result.assigns[:oauth_scopes] == ["read", "write"]
      assert result.assigns[:current_user][:scopes] == ["read", "write"]
    end

    test "extracts scopes from space-separated string" do
      token = sign_token(%{"scope" => "read write admin"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.assigns[:oauth_scopes] == ["read", "write", "admin"]
    end

    test "handles empty scope" do
      token = sign_token(%{})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      refute result.halted
      assert result.assigns[:oauth_scopes] == []
    end
  end

  describe "invalid token" do
    test "rejects request without Authorization header" do
      result =
        conn(:get, "/")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
      assert get_resp_header(result, "www-authenticate") |> List.first() =~ "Bearer"
      assert get_resp_header(result, "www-authenticate") |> List.first() =~ "resource_metadata"
    end

    test "rejects request with invalid token" do
      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer invalid.token.here")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
    end

    test "rejects token with wrong issuer" do
      token = sign_token(%{"iss" => "https://wrong-issuer.com"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
    end

    test "rejects token with wrong audience" do
      token = sign_token(%{"aud" => "https://wrong-audience.com"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
    end

    test "accepts token with audience as array containing expected value" do
      token = sign_token(%{"aud" => ["https://mcp.example.com", "https://other.com"]})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      refute result.halted
    end

    test "skips auth for OPTIONS requests" do
      result =
        conn(:options, "/")
        |> OAuth.call(@oauth_opts)

      refute result.halted
    end
  end

  describe "algorithm allow-list" do
    test "rejects token whose header alg is not in the allow-list" do
      # HS256 is not in the default allow-list when no oct key is configured
      hs_signer = Joken.Signer.create("HS256", "shared-secret")

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "exp" => System.system_time(:second) + 3600
          },
          hs_signer
        )

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
    end

    test "explicit :algorithms option restricts accepted algs" do
      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          algorithms: ["ES256"],
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public_key]}
        )

      token = sign_token(%{"scope" => "read"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      # RS256 token rejected because only ES256 is allowed
      assert result.halted
      assert result.status == 401
    end

    test "HS flow works with a static oct key without explicit :algorithms" do
      secret = :crypto.strong_rand_bytes(32)

      oct_key = %{
        "kty" => "oct",
        "kid" => "hmac-key",
        "k" => Base.url_encode64(secret, padding: false)
      }

      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [oct_key]}
        )

      signer = Joken.Signer.create("HS256", secret, %{"kid" => "hmac-key"})

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "sub" => "user-456",
            "exp" => System.system_time(:second) + 3600
          },
          signer
        )

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      refute result.halted
      assert result.assigns[:oauth_claims]["sub"] == "user-456"
    end

    test "rejects token when header alg does not fit the key family" do
      # HS256 header alg against an RSA key — allow-list includes HS via
      # explicit option, but the key family check must still reject it
      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          algorithms: ["RS256", "HS256"],
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public_key]}
        )

      hs_signer = Joken.Signer.create("HS256", "attacker-controlled", %{"kid" => "test-key"})

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "exp" => System.system_time(:second) + 3600
          },
          hs_signer
        )

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      assert result.halted
      assert result.status == 401
    end

    test "rejects key with unknown kty cleanly" do
      weird_key = %{"kty" => "OKP", "kid" => "ed-key", "crv" => "Ed25519", "x" => "abc"}

      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [weird_key]}
        )

      token = sign_token(%{})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      assert result.halted
      assert result.status == 401
    end
  end

  describe "WWW-Authenticate header hygiene" do
    test "strips CRLF and quotes from config-sourced header values" do
      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          resource_uri: "https://mcp.example.com\r\nX-Injected: 1",
          scopes_supported: ["read\"", "write\r\n"],
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public_key]}
        )

      result =
        conn(:get, "/")
        |> OAuth.call(opts)

      [www_auth] = get_resp_header(result, "www-authenticate")
      refute www_auth =~ "\r"
      refute www_auth =~ "\n"
      assert www_auth =~ "resource_metadata=\"https://mcp.example.comX-Injected: 1/"
    end
  end

  describe "WWW-Authenticate headers" do
    test "401 includes resource_metadata and scope in WWW-Authenticate" do
      result =
        conn(:get, "/")
        |> OAuth.call(@oauth_opts)

      [www_auth] = get_resp_header(result, "www-authenticate")
      assert www_auth =~ "resource_metadata="
      assert www_auth =~ "scope=\"read write admin\""
    end
  end

  describe "has_scope?/2 and has_scopes?/2" do
    test "has_scope? checks single scope" do
      token = sign_token(%{"scope" => "read write"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert OAuth.has_scope?(result, "read")
      assert OAuth.has_scope?(result, "write")
      refute OAuth.has_scope?(result, "admin")
    end

    test "has_scopes? checks multiple scopes" do
      token = sign_token(%{"scope" => "read write"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert OAuth.has_scopes?(result, ["read", "write"])
      refute OAuth.has_scopes?(result, ["read", "admin"])
    end
  end

  describe "forbidden/3" do
    test "sends 403 with insufficient_scope error" do
      result =
        conn(:get, "/")
        |> OAuth.forbidden(@oauth_opts, ["admin", "write"])

      assert result.halted
      assert result.status == 403

      [www_auth] = get_resp_header(result, "www-authenticate")
      assert www_auth =~ "insufficient_scope"
      assert www_auth =~ "scope=\"admin write\""

      body = JSON.decode!(result.resp_body)
      assert body["error"] == "Forbidden"
      assert body["message"] =~ "Insufficient scope"
    end
  end
end

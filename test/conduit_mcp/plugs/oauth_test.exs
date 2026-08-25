defmodule ConduitMcp.Plugs.OAuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.OAuth
  alias ConduitMcp.TelemetryTestHelper

  @auth_event [:conduit_mcp, :auth, :verify]

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
      # The security property is that injected CR/LF can't break out of the
      # header value — assert their absence directly. Don't pin the exact
      # stripped concatenation, which is brittle to formatting changes.
      refute www_auth =~ "\r"
      refute www_auth =~ "\n"
      assert www_auth =~ "resource_metadata="
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

  describe "exp / nbf enforcement" do
    test "expired token reports :expired, not :invalid_signature" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      token = sign_token(%{"exp" => System.system_time(:second) - 3600})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Token expired"

      assert_receive {@auth_event, ^ref, _measurements,
                      %{strategy: :oauth, status: :error, reason: :expired}}
    end

    test "token with no exp claim is rejected as expired, not for some other reason" do
      # Joken folds validation over the claims the token carries, so an absent
      # exp was never validated and the token was accepted forever. A bare 401
      # cannot tell that apart from a signature or issuer rejection - which is
      # precisely how the pre-change suite passed for the wrong reason.
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      signer = Joken.Signer.create("RS256", @rsa_key_map)

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "sub" => "user-123"
          },
          signer
        )

      assert {:ok, claims} = Joken.peek_claims(token)
      refute Map.has_key?(claims, "exp")

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Token expired"

      assert_receive {@auth_event, ^ref, _measurements, %{status: :error, reason: :expired}}
    end

    test "token whose nbf is in the future is rejected" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      token = sign_token(%{"nbf" => System.system_time(:second) + 3600})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Token not yet valid"

      assert_receive {@auth_event, ^ref, _measurements, %{status: :error, reason: :not_yet_valid}}
    end

    test "token with a malformed nbf is rejected as not-yet-valid, fail-closed" do
      # A non-integer nbf must fail closed on the nbf branch. A bare 401 would
      # also pass if the token were rejected for its signature, which would
      # leave the malformed-claim path itself untested.
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      token = sign_token(%{"nbf" => "not-a-timestamp"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Token not yet valid"

      assert_receive {@auth_event, ^ref, _measurements, %{status: :error, reason: :not_yet_valid}}
    end

    test "wrong issuer reports :invalid_issuer, not :invalid_signature" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      token = sign_token(%{"iss" => "https://wrong-issuer.com"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Invalid token issuer"

      assert_receive {@auth_event, ^ref, _measurements,
                      %{status: :error, reason: :invalid_issuer}}
    end

    test "wrong audience reports :invalid_audience" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      token = sign_token(%{"aud" => "https://wrong-audience.com"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Invalid token audience"

      assert_receive {@auth_event, ^ref, _measurements,
                      %{status: :error, reason: :invalid_audience}}
    end

    test "a forged signature still reports :invalid_signature" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])

      other_key = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map() |> elem(1)
      signer = Joken.Signer.create("RS256", Map.put(other_key, "kid", "test-key"))

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "exp" => System.system_time(:second) + 3600
          },
          signer
        )

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] == "Token verification failed"

      assert_receive {@auth_event, ^ref, _measurements,
                      %{status: :error, reason: :invalid_signature}}
    end
  end

  describe "alg-pinned keys (the path every real JWKS takes)" do
    # Auth0, Okta, Entra, Keycloak and Google all publish "alg" on JWKS keys,
    # so the alg-pinned clause is what production hits — the suite previously
    # never entered it because its fixture key had no "alg".
    @alg_pinned_key Map.put(@rsa_public_key, "alg", "RS256")

    @alg_pinned_opts OAuth.init(
                       issuer: "https://auth.example.com",
                       audience: "https://mcp.example.com",
                       key_provider:
                         {ConduitMcp.OAuth.KeyProvider.Static, keys: [@alg_pinned_key]}
                     )

    test "accepts a token whose header alg matches the key's pinned alg" do
      token = sign_token(%{"scope" => "read"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@alg_pinned_opts)

      refute result.halted
      assert result.assigns[:oauth_claims]["sub"] == "user-123"
    end

    test "rejects a token whose header alg contradicts the key's pinned alg" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])

      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          # HS256 allow-listed so the allow-list check passes and the pinned
          # alg is what does the rejecting.
          algorithms: ["RS256", "HS256"],
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@alg_pinned_key]}
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

      assert_receive {@auth_event, ^ref, _measurements, %{status: :error, reason: :alg_mismatch}}
    end

    test "rejects a token whose header carries no alg at all" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])

      # Joken always writes an alg, so hand-build the compact serialization.
      encode = &Base.url_encode64(JSON.encode!(&1), padding: false)
      header = encode.(%{"typ" => "JWT", "kid" => "test-key"})

      payload =
        encode.(%{
          "iss" => "https://auth.example.com",
          "aud" => "https://mcp.example.com",
          "exp" => System.system_time(:second) + 3600
        })

      token = "#{header}.#{payload}.#{Base.url_encode64("sig", padding: false)}"

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@alg_pinned_opts)

      assert result.halted
      assert result.status == 401

      assert_receive {@auth_event, ^ref, _measurements, %{status: :error, reason: :missing_alg}}
    end

    test "rejects a key with no kty and no alg" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])

      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [%{"kid" => "test-key"}]}
        )

      token = sign_token(%{})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      assert result.halted
      assert result.status == 401

      assert_receive {@auth_event, ^ref, _measurements,
                      %{status: :error, reason: :unsupported_key_type}}
    end

    test "accepts an EC P-256 key signing ES256" do
      ec_key = JOSE.JWK.generate_key({:ec, "P-256"})
      ec_private = ec_key |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "ec-key")

      ec_public =
        ec_key
        |> JOSE.JWK.to_public()
        |> JOSE.JWK.to_map()
        |> elem(1)
        |> Map.put("kid", "ec-key")

      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [ec_public]}
        )

      signer = Joken.Signer.create("ES256", ec_private)

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "sub" => "ec-user",
            "exp" => System.system_time(:second) + 3600
          },
          signer
        )

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      refute result.halted
      assert result.assigns[:oauth_claims]["sub"] == "ec-user"
    end
  end

  describe "principal subject resolution" do
    test "a verified token with no subject claim is rejected, not made anonymous" do
      # Assigning id: nil would produce an *authenticated* principal that every
      # consumer reads as anonymous: task ownership collapses to unowned and
      # rate limiting falls back to the IP bucket.
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@auth_event])
      signer = Joken.Signer.create("RS256", @rsa_key_map)

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{
            "iss" => "https://auth.example.com",
            "aud" => "https://mcp.example.com",
            "exp" => System.system_time(:second) + 3600
          },
          signer
        )

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      assert result.halted
      assert result.status == 401
      assert JSON.decode!(result.resp_body)["message"] =~ "no usable subject claim"

      assert_receive {@auth_event, ^ref, _measurements,
                      %{status: :error, reason: :missing_subject}}
    end

    test "client_id is accepted when sub is absent (client-credentials tokens)" do
      token = sign_token(%{"sub" => nil, "client_id" => "svc-42"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      refute result.halted
      assert ConduitMcp.Principal.id(result) == "client_id:svc-42"
    end

    test "a numeric sub is coerced to a string rather than crashing downstream" do
      # Principal.rate_limit_key/1 concatenates the id; some IdPs emit numeric
      # subjects.
      token = sign_token(%{"sub" => 12_345})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(@oauth_opts)

      refute result.halted
      assert ConduitMcp.Principal.id(result) == "sub:12345"
      assert ConduitMcp.Principal.rate_limit_key(result) == "user:sub:12345"
    end

    test ":subject_claims can be pointed at a non-standard claim" do
      opts =
        OAuth.init(
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          subject_claims: ["tenant_id"],
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public_key]}
        )

      token = sign_token(%{"tenant_id" => "acme"})

      result =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OAuth.call(opts)

      refute result.halted
      assert ConduitMcp.Principal.id(result) == "tenant_id:acme"
    end
  end
end

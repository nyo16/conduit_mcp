defmodule ConduitMcp.Client.OAuth.DiscoveryTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.OAuth.{Discovery, Error}

  doctest ConduitMcp.Client.OAuth.Discovery

  @issuer "https://auth.example.com/tenant1"

  defp metadata(overrides \\ %{}) do
    Map.merge(
      %{
        "issuer" => @issuer,
        "authorization_endpoint" => "https://auth.example.com/tenant1/authorize",
        "token_endpoint" => "https://auth.example.com/tenant1/token",
        "code_challenge_methods_supported" => ["S256"]
      },
      overrides
    )
  end

  describe "prm_candidates/3" do
    test "table" do
      wk = "/.well-known/oauth-protected-resource"

      for {server, header, expected} <- [
            {"https://ex.com/public/mcp", nil,
             ["https://ex.com#{wk}/public/mcp", "https://ex.com#{wk}"]},
            {"https://ex.com/public/mcp/", nil,
             ["https://ex.com#{wk}/public/mcp", "https://ex.com#{wk}"]},
            {"https://ex.com", nil, ["https://ex.com#{wk}"]},
            {"https://ex.com/", nil, ["https://ex.com#{wk}"]},
            {"https://EX.com:443/mcp", nil, ["https://ex.com#{wk}/mcp", "https://ex.com#{wk}"]},
            {"https://ex.com:8443/mcp", nil,
             ["https://ex.com:8443#{wk}/mcp", "https://ex.com:8443#{wk}"]},
            {"https://ex.com/mcp?t=1#f", nil,
             ["https://ex.com#{wk}/mcp?t=1", "https://ex.com#{wk}"]},
            {"https://ex.com/mcp", "https://meta.ex.com/prm",
             ["https://meta.ex.com/prm", "https://ex.com#{wk}/mcp", "https://ex.com#{wk}"]},
            {"https://ex.com/mcp", "https://ex.com#{wk}/mcp",
             ["https://ex.com#{wk}/mcp", "https://ex.com#{wk}"]}
          ] do
        assert Discovery.prm_candidates(server, header) == {:ok, expected}, server
      end
    end

    test "the server URL must be https (loopback http behind allow_insecure)" do
      assert {:error, %Error{reason: :insecure_url}} =
               Discovery.prm_candidates("http://ex.com/mcp")

      assert {:ok, ["http://127.0.0.1:4000/.well-known/oauth-protected-resource/mcp" | _]} =
               Discovery.prm_candidates("http://127.0.0.1:4000/mcp", nil, allow_insecure: true)
    end
  end

  describe "as_metadata_candidates/2" do
    test "issuer with a path: OAuth path-insert, OIDC path-insert, OIDC path-append" do
      expected = [
        "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        "https://auth.example.com/.well-known/openid-configuration/tenant1",
        "https://auth.example.com/tenant1/.well-known/openid-configuration"
      ]

      assert Discovery.as_metadata_candidates(@issuer) == {:ok, expected}
      assert Discovery.as_metadata_candidates(@issuer <> "/") == {:ok, expected}
    end

    test "issuer without a path: OAuth then OIDC; ports are kept" do
      for issuer <- ["https://auth.example.com", "https://auth.example.com/"] do
        assert Discovery.as_metadata_candidates(issuer) ==
                 {:ok,
                  [
                    "https://auth.example.com/.well-known/oauth-authorization-server",
                    "https://auth.example.com/.well-known/openid-configuration"
                  ]}
      end

      assert {:ok,
              ["https://auth.example.com:8443/.well-known/oauth-authorization-server/a/b" | _]} =
               Discovery.as_metadata_candidates("https://auth.example.com:8443/a/b")
    end

    test "issuers with a query or fragment, or not https, are refused" do
      assert {:error, %Error{reason: :invalid_url}} =
               Discovery.as_metadata_candidates(@issuer <> "?x=1")

      assert {:error, %Error{reason: :invalid_url}} =
               Discovery.as_metadata_candidates(@issuer <> "#f")

      assert {:error, %Error{reason: :insecure_url}} =
               Discovery.as_metadata_candidates("http://auth.example.com")
    end
  end

  describe "validate_prm/2 (OA-4)" do
    @prm %{"resource" => "https://mcp.example.com/mcp", "authorization_servers" => [@issuer]}

    test "exact resource match is accepted" do
      assert Discovery.validate_prm(@prm, "https://mcp.example.com/mcp") == {:ok, @prm}
    end

    test "any resource difference is a mismatch" do
      for resource <- [
            "https://mcp.example.com/mcp/",
            "https://MCP.example.com/mcp",
            "https://mcp.example.com",
            "https://mcp.example.com/mcp/other",
            "https://evil.example.com/mcp",
            nil
          ] do
        assert {:error, %Error{reason: :resource_mismatch}} =
                 Discovery.validate_prm(
                   Map.put(@prm, "resource", resource),
                   "https://mcp.example.com/mcp"
                 )
      end

      assert {:error, %Error{reason: :resource_mismatch}} =
               Discovery.validate_prm(Map.delete(@prm, "resource"), "https://mcp.example.com/mcp")
    end

    test "authorization_servers and scopes_supported are checked" do
      canonical = "https://mcp.example.com/mcp"

      assert {:error, %Error{reason: :no_authorization_server}} =
               Discovery.validate_prm(Map.delete(@prm, "authorization_servers"), canonical)

      assert {:error, %Error{reason: :no_authorization_server}} =
               Discovery.validate_prm(%{@prm | "authorization_servers" => []}, canonical)

      assert {:error, %Error{reason: :invalid_metadata, data: %{field: "authorization_servers"}}} =
               Discovery.validate_prm(%{@prm | "authorization_servers" => [1]}, canonical)

      assert {:error, %Error{reason: :invalid_metadata, data: %{field: "scopes_supported"}}} =
               Discovery.validate_prm(Map.put(@prm, "scopes_supported", "a b"), canonical)

      assert {:error, %Error{reason: :invalid_metadata}} = Discovery.validate_prm([], canonical)
    end
  end

  describe "select_issuer/2" do
    test "the first authorization server, checked against expected_issuers" do
      prm = %{"authorization_servers" => [@issuer, "https://other.example.com"]}
      assert Discovery.select_issuer(prm) == {:ok, @issuer}
      assert Discovery.select_issuer(prm, expected_issuers: [@issuer]) == {:ok, @issuer}

      assert {:error, %Error{reason: :issuer_not_allowed}} =
               Discovery.select_issuer(prm, expected_issuers: ["https://other.example.com"])

      assert {:error, %Error{reason: :issuer_not_allowed}} =
               Discovery.select_issuer(prm, expected_issuers: [String.upcase(@issuer)])

      assert {:error, %Error{reason: :no_authorization_server}} = Discovery.select_issuer(%{})
    end
  end

  describe "validate_as_metadata/3" do
    test "valid metadata is returned unchanged" do
      meta = metadata(%{"registration_endpoint" => "https://auth.example.com/register"})
      assert Discovery.validate_as_metadata(meta, @issuer) == {:ok, meta}
    end

    test "OA-4: the issuer must match exactly, without normalization" do
      for {issuer, recorded} <- [
            {"https://AS.example", "https://as.example"},
            {"https://as.example", "https://AS.example"},
            {"https://as.example/", "https://as.example"},
            {"https://as.example:443", "https://as.example"},
            {"https://evil.example", "https://as.example"}
          ] do
        assert {:error, %Error{reason: :issuer_mismatch}} =
                 Discovery.validate_as_metadata(metadata(%{"issuer" => issuer}), recorded)
      end

      assert {:error, %Error{reason: :issuer_mismatch}} =
               Discovery.validate_as_metadata(Map.delete(metadata(), "issuer"), @issuer)
    end

    test "OA-1: no S256 is refused" do
      for methods <- [nil, [], ["plain"]] do
        meta =
          if methods,
            do: metadata(%{"code_challenge_methods_supported" => methods}),
            else: Map.delete(metadata(), "code_challenge_methods_supported")

        assert {:error, %Error{reason: :pkce_unsupported}} =
                 Discovery.validate_as_metadata(meta, @issuer)
      end
    end

    test "OA-7: javascript:, file: and other non-https endpoints are refused" do
      for {field, url, scheme} <- [
            {"authorization_endpoint", "javascript:alert(1)", "javascript"},
            {"authorization_endpoint", "JavaScript:alert(1)", "javascript"},
            {"authorization_endpoint", "file:///etc/passwd", "file"},
            {"authorization_endpoint", "data:text/html,hi", "data"},
            {"authorization_endpoint", "com.example.app:/cb", "com.example.app"},
            {"authorization_endpoint", "http://auth.example.com/authorize", "http"},
            {"token_endpoint", "http://auth.example.com/token", "http"},
            {"registration_endpoint", "http://auth.example.com/register", "http"},
            {"revocation_endpoint", "ftp://auth.example.com/revoke", "ftp"},
            {"jwks_uri", "http://auth.example.com/jwks", "http"}
          ] do
        assert {:error,
                %Error{reason: :insecure_endpoint, data: %{field: ^field, scheme: ^scheme}}} =
                 Discovery.validate_as_metadata(metadata(%{field => url}), @issuer),
               url
      end
    end

    test "missing or malformed endpoints" do
      for field <- ["authorization_endpoint", "token_endpoint"] do
        assert {:error, %Error{reason: :invalid_metadata, data: %{field: ^field}}} =
                 Discovery.validate_as_metadata(Map.delete(metadata(), field), @issuer)
      end

      for {field, value} <- [
            {"token_endpoint", nil},
            {"token_endpoint", 42},
            {"authorization_endpoint", "https:///authorize"},
            {"authorization_endpoint", "https://user@auth.example.com/authorize"},
            {"authorization_endpoint", "https://auth.example.com/authorize#frag"},
            {"userinfo_endpoint", "not a url"}
          ] do
        assert {:error, %Error{reason: :invalid_metadata, data: %{field: ^field}}} =
                 Discovery.validate_as_metadata(metadata(%{field => value}), @issuer),
               inspect(value)
      end

      assert {:error, %Error{reason: :invalid_metadata}} =
               Discovery.validate_as_metadata("{}", @issuer)
    end

    test "allow_insecure admits loopback http only" do
      issuer = "http://127.0.0.1:4001"

      meta = %{
        "issuer" => issuer,
        "authorization_endpoint" => "http://127.0.0.1:4001/authorize",
        "token_endpoint" => "http://localhost:4001/token",
        "code_challenge_methods_supported" => ["S256"]
      }

      assert {:ok, ^meta} = Discovery.validate_as_metadata(meta, issuer, allow_insecure: true)

      assert {:error, %Error{reason: :insecure_endpoint}} =
               Discovery.validate_as_metadata(meta, issuer)

      assert {:error, %Error{reason: :insecure_endpoint, data: %{field: "token_endpoint"}}} =
               Discovery.validate_as_metadata(
                 %{meta | "token_endpoint" => "http://auth.example.com/token"},
                 issuer,
                 allow_insecure: true
               )
    end
  end
end

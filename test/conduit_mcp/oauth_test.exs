defmodule ConduitMcp.OAuthTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.OAuth.KeyProvider.Static
  alias ConduitMcp.OAuth.ResourceMetadata

  describe "KeyProvider.Static" do
    @test_keys [
      %{"kty" => "RSA", "kid" => "key-1", "n" => "abc", "e" => "AQAB"},
      %{"kty" => "RSA", "kid" => "key-2", "n" => "def", "e" => "AQAB"}
    ]

    test "fetch_keys returns configured keys" do
      assert {:ok, keys} = Static.fetch_keys(keys: @test_keys)
      assert length(keys) == 2
    end

    test "fetch_keys returns empty list when no keys configured" do
      assert {:ok, []} = Static.fetch_keys([])
    end

    test "fetch_key finds key by kid" do
      assert {:ok, key} = Static.fetch_key("key-1", keys: @test_keys)
      assert key["kid"] == "key-1"
    end

    test "fetch_key returns error for unknown kid" do
      assert {:error, :not_found} = Static.fetch_key("unknown", keys: @test_keys)
    end
  end

  describe "ResourceMetadata.build/1" do
    test "builds metadata with all fields" do
      config = [
        issuer: "https://auth.example.com",
        audience: "https://mcp.example.com",
        scopes_supported: ["read", "write"]
      ]

      metadata = ResourceMetadata.build(config)

      assert metadata["resource"] == "https://mcp.example.com"
      assert metadata["authorization_servers"] == ["https://auth.example.com"]
      assert metadata["scopes_supported"] == ["read", "write"]
      assert metadata["bearer_methods_supported"] == ["header"]
    end

    test "builds metadata without scopes" do
      config = [
        issuer: "https://auth.example.com",
        audience: "https://mcp.example.com"
      ]

      metadata = ResourceMetadata.build(config)

      assert metadata["resource"] == "https://mcp.example.com"
      refute Map.has_key?(metadata, "scopes_supported")
    end

    test "uses resource_uri when provided" do
      config = [
        issuer: "https://auth.example.com",
        audience: "https://mcp.example.com",
        resource_uri: "https://custom-resource.example.com"
      ]

      metadata = ResourceMetadata.build(config)
      assert metadata["resource"] == "https://custom-resource.example.com"
    end
  end
end

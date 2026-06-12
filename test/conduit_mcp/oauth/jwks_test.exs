defmodule ConduitMcp.OAuth.KeyProvider.JWKSTest do
  # async: false — uses Req.default_options (global) to route requests
  # through Req.Test stubs, and a shared named ETS cache table.
  use ExUnit.Case, async: false

  alias ConduitMcp.OAuth.KeyProvider.JWKS

  @table :conduit_mcp_jwks_cache

  @keys [%{"kty" => "RSA", "kid" => "key-1", "n" => "abc", "e" => "AQAB"}]

  setup do
    Req.default_options(plug: {Req.Test, __MODULE__})

    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    on_exit(fn -> Application.delete_env(:req, :default_options) end)
    :ok
  end

  defp stub_json(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end)
  end

  test "fetches and caches keys from an https JWKS endpoint" do
    stub_json(200, %{"keys" => @keys})

    config = [jwks_uri: "https://auth.example.com/jwks-fetch"]
    assert {:ok, @keys} = JWKS.fetch_keys(config)

    # Second call served from cache — break the stub to prove no refetch
    Req.Test.stub(__MODULE__, fn _conn -> raise "must not refetch" end)
    assert {:ok, @keys} = JWKS.fetch_keys(config)
  end

  test "rejects http:// URIs unless allow_insecure_jwks is set" do
    assert {:error, :insecure_jwks_uri} =
             JWKS.fetch_keys(jwks_uri: "http://auth.example.com/jwks-insecure")

    stub_json(200, %{"keys" => @keys})

    assert {:ok, @keys} =
             JWKS.fetch_keys(
               jwks_uri: "http://auth.example.com/jwks-insecure-ok",
               allow_insecure_jwks: true
             )
  end

  test "does not follow redirects" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example.com/jwks")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, {:http_error, 302}} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-redirect")
  end

  test "rejects oversized responses" do
    huge = String.duplicate("a", 1_048_577)

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, huge) end)

    assert {:error, :jwks_too_large} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-huge")
  end

  test "rejects responses that are not a valid key set" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)

    assert {:error, :invalid_jwks} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-bad-json")

    stub_json(200, %{"nokeys" => true})

    assert {:error, :invalid_jwks} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-bad-shape")
  end

  test "serves stale cached keys when a refresh fails" do
    uri = "https://auth.example.com/jwks-stale"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # Backdate the cached row past the TTL (but within stale_max_age),
    # then make the endpoint fail
    [{^uri, keys, _cached_at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    stub_json(500, %{"error" => "down"})

    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri, cache_ttl: 1)
  end

  test "fails closed when stale cached keys exceed :stale_max_age" do
    uri = "https://auth.example.com/jwks-too-stale"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, keys, _cached_at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    stub_json(500, %{"error" => "down"})

    assert {:error, {:http_error, 500}} =
             JWKS.fetch_keys(jwks_uri: uri, cache_ttl: 1, stale_max_age: 1_000)
  end

  test "fails when refresh fails and no cached keys exist" do
    stub_json(500, %{"error" => "down"})

    assert {:error, {:http_error, 500}} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-down")
  end

  test "key rollover: unknown kid triggers a refresh" do
    uri = "https://auth.example.com/jwks-rollover"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # IdP rotates: kid key-2 appears upstream while the cache still has key-1
    rotated = [%{"kty" => "RSA", "kid" => "key-2", "n" => "def", "e" => "AQAB"}]
    stub_json(200, %{"keys" => rotated})

    assert {:ok, %{"kid" => "key-2"}} = JWKS.fetch_key("key-2", jwks_uri: uri)
  end

  test "TTL expiry triggers a refetch" do
    uri = "https://auth.example.com/jwks-ttl"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, keys, _cached_at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, 0})

    fresh = [%{"kty" => "RSA", "kid" => "key-fresh", "n" => "ghi", "e" => "AQAB"}]
    stub_json(200, %{"keys" => fresh})

    assert {:ok, ^fresh} = JWKS.fetch_keys(jwks_uri: uri, cache_ttl: 1)
  end
end

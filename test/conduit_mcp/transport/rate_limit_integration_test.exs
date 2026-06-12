defmodule ConduitMcp.Transport.RateLimitIntegrationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.TestServer
  alias ConduitMcp.Transport.StreamableHTTP

  @backend ConduitMcp.TestRateLimiter

  describe "StreamableHTTP with rate limiting" do
    test "allows requests within rate limit" do
      key = "integration-allow-#{System.unique_integer([:positive])}"

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          rate_limit: [
            backend: @backend,
            limit: 10,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/list"
          })
        )
        |> put_req_header("content-type", "application/json")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200

      {:ok, response} = JSON.decode(result.resp_body)
      assert response["result"]["tools"]
    end

    test "returns 429 when rate limit exceeded" do
      key = "integration-deny-#{System.unique_integer([:positive])}"

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # First request should be allowed
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")

      result1 = StreamableHTTP.call(conn1, opts)
      refute result1.halted
      assert result1.status == 200

      # Second request should be rate limited
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")

      result2 = StreamableHTTP.call(conn2, opts)

      assert result2.halted
      assert result2.status == 429

      {:ok, body} = JSON.decode(result2.resp_body)
      assert body["error"]["code"] == -32000
      assert body["error"]["message"] == "Rate limit exceeded"
    end
  end

  describe "auth + rate limiting ordering" do
    test "auth rejects before rate limit is consumed" do
      key = "integration-auth-first-#{System.unique_integer([:positive])}"

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          auth: [
            strategy: :bearer_token,
            token: "secret-token"
          ],
          rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # Unauthenticated request should get 401 (not 429)
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")

      result1 = StreamableHTTP.call(conn1, opts)

      assert result1.halted
      assert result1.status == 401

      # Authenticated request should still work (rate limit not consumed by failed auth)
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer secret-token")

      result2 = StreamableHTTP.call(conn2, opts)

      refute result2.halted
      assert result2.status == 200
    end
  end

  describe "no rate_limit config" do
    test "works normally without rate limiting" do
      opts = StreamableHTTP.init(server_module: TestServer)

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end
  end

  describe "disabled rate limiting" do
    test "passes all requests when disabled" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          rate_limit: [enabled: false]
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end
  end
end

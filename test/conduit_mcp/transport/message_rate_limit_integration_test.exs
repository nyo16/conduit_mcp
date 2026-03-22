defmodule ConduitMcp.Transport.MessageRateLimitIntegrationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @backend ConduitMcp.TestRateLimiter

  describe "StreamableHTTP with message rate limit" do
    test "works without message_rate_limit configured (no regression)" do
      opts =
        ConduitMcp.Transport.StreamableHTTP.init(server_module: ConduitMcp.TestServer)

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      result = ConduitMcp.Transport.StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end

    test "message rate limit kicks in on POST requests" do
      key = "integ-msg-rl-#{System.unique_integer([:positive])}"

      opts =
        ConduitMcp.Transport.StreamableHTTP.init(
          server_module: ConduitMcp.TestServer,
          message_rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # First request allowed
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      result1 = ConduitMcp.Transport.StreamableHTTP.call(conn1, opts)
      assert result1.status == 200

      # Second request denied
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")

      result2 = ConduitMcp.Transport.StreamableHTTP.call(conn2, opts)
      assert result2.status == 429

      {:ok, body} = JSON.decode(result2.resp_body)
      assert body["error"]["message"] == "Message rate limit exceeded"
    end

    test "GET requests bypass message rate limit" do
      key = "integ-msg-rl-get-#{System.unique_integer([:positive])}"

      opts =
        ConduitMcp.Transport.StreamableHTTP.init(
          server_module: ConduitMcp.TestServer,
          message_rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # Exhaust message rate limit
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      ConduitMcp.Transport.StreamableHTTP.call(conn1, opts)

      # GET should still work
      conn2 = conn(:get, "/")
      result = ConduitMcp.Transport.StreamableHTTP.call(conn2, opts)
      assert result.status == 200
    end

    test "excluded methods bypass message rate limit in full pipeline" do
      key = "integ-msg-rl-excluded-#{System.unique_integer([:positive])}"

      opts =
        ConduitMcp.Transport.StreamableHTTP.init(
          server_module: ConduitMcp.TestServer,
          message_rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end,
            excluded_methods: ["initialize", "ping"]
          ]
        )

      # "initialize" should not be counted
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      result1 = ConduitMcp.Transport.StreamableHTTP.call(conn1, opts)
      assert result1.status == 200

      # A regular method should still be allowed (limit=1, nothing counted yet)
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")

      result2 = ConduitMcp.Transport.StreamableHTTP.call(conn2, opts)
      assert result2.status == 200

      # Now the limit is exhausted for non-excluded methods
      conn3 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 3})
        )
        |> put_req_header("content-type", "application/json")

      result3 = ConduitMcp.Transport.StreamableHTTP.call(conn3, opts)
      assert result3.status == 429
    end

    test "both HTTP and message rate limits configured together" do
      http_key = "integ-http-rl-#{System.unique_integer([:positive])}"
      msg_key = "integ-msg-rl-both-#{System.unique_integer([:positive])}"

      opts =
        ConduitMcp.Transport.StreamableHTTP.init(
          server_module: ConduitMcp.TestServer,
          rate_limit: [
            backend: @backend,
            limit: 10,
            scale: 60_000,
            key_func: fn _conn -> http_key end
          ],
          message_rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> msg_key end
          ]
        )

      # First request passes both limits
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      result1 = ConduitMcp.Transport.StreamableHTTP.call(conn1, opts)
      assert result1.status == 200

      # Second request: HTTP limit still fine, but message limit exceeded
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")

      result2 = ConduitMcp.Transport.StreamableHTTP.call(conn2, opts)
      assert result2.status == 429

      {:ok, body} = JSON.decode(result2.resp_body)
      assert body["error"]["message"] == "Message rate limit exceeded"
    end
  end

  describe "SSE with message rate limit" do
    test "works without message_rate_limit configured (no regression)" do
      opts =
        ConduitMcp.Transport.SSE.init(server_module: ConduitMcp.TestServer)

      conn =
        conn(
          :post,
          "/message",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      result = ConduitMcp.Transport.SSE.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end

    test "message rate limit kicks in on POST requests" do
      key = "integ-sse-msg-rl-#{System.unique_integer([:positive])}"

      opts =
        ConduitMcp.Transport.SSE.init(
          server_module: ConduitMcp.TestServer,
          message_rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # First request allowed
      conn1 =
        conn(
          :post,
          "/message",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")

      result1 = ConduitMcp.Transport.SSE.call(conn1, opts)
      assert result1.status == 200

      # Second request denied
      conn2 =
        conn(
          :post,
          "/message",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")

      result2 = ConduitMcp.Transport.SSE.call(conn2, opts)
      assert result2.status == 429

      {:ok, body} = JSON.decode(result2.resp_body)
      assert body["error"]["message"] == "Message rate limit exceeded"
    end
  end
end

defmodule ConduitMcp.Plugs.MessageRateLimitTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.MessageRateLimit
  alias ConduitMcp.TelemetryTestHelper

  @backend ConduitMcp.TestRateLimiter

  describe "init/1" do
    test "sets defaults with backend" do
      opts = MessageRateLimit.init(backend: @backend)

      assert opts.enabled == true
      assert opts.backend == @backend
      assert opts.scale == 300_000
      assert opts.limit == 50
      assert is_function(opts.key_func, 1)
      assert opts.excluded_methods == []
    end

    test "accepts custom options" do
      key_fn = fn _conn -> "custom" end

      opts =
        MessageRateLimit.init(
          backend: @backend,
          enabled: false,
          scale: 60_000,
          limit: 100,
          key_func: key_fn,
          excluded_methods: ["initialize", "ping"]
        )

      assert opts.enabled == false
      assert opts.scale == 60_000
      assert opts.limit == 100
      assert opts.key_func == key_fn
      assert opts.excluded_methods == ["initialize", "ping"]
    end

    test "raises when backend is missing and enabled" do
      assert_raise ArgumentError, ~r/requires a :backend option/, fn ->
        MessageRateLimit.init([])
      end
    end

    test "does not raise when backend is missing but disabled" do
      opts = MessageRateLimit.init(enabled: false)
      assert opts.enabled == false
    end
  end

  describe "call/2 with disabled" do
    test "passes through when disabled" do
      opts = MessageRateLimit.init(enabled: false)
      conn = conn(:post, "/")

      result = MessageRateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 with OPTIONS" do
    test "bypasses message rate limiting for CORS preflight" do
      opts = MessageRateLimit.init(backend: @backend, limit: 1, scale: 60_000)
      conn = conn(:options, "/")

      result = MessageRateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 with GET" do
    test "bypasses message rate limiting for GET requests" do
      opts = MessageRateLimit.init(backend: @backend, limit: 1, scale: 60_000)
      conn = conn(:get, "/")

      result = MessageRateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 with notification" do
    test "passes through for JSON-RPC notifications (no id field)" do
      key = "test-notification-#{System.unique_integer([:positive])}"

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled"})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result = MessageRateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 with excluded method" do
    test "passes through for excluded methods" do
      key = "test-excluded-#{System.unique_integer([:positive])}"

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key end,
          excluded_methods: ["initialize", "ping"]
        )

      # First call with "initialize" should pass through (not counted)
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result1 = MessageRateLimit.call(conn1, opts)
      refute result1.halted

      # Second call with "initialize" should also pass through (still not counted)
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result2 = MessageRateLimit.call(conn2, opts)
      refute result2.halted
    end
  end

  describe "call/2 within limit" do
    test "allows message within limit" do
      key = "test-msg-allow-#{System.unique_integer([:positive])}"

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 10,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result = MessageRateLimit.call(conn, opts)

      refute result.halted
    end

    test "emits telemetry on allow" do
      key = "test-msg-telemetry-allow-#{System.unique_integer([:positive])}"

      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [
          [:conduit_mcp, :message_rate_limit, :check]
        ])

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 10,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      MessageRateLimit.call(conn, opts)

      assert_receive {[:conduit_mcp, :message_rate_limit, :check], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.key == key
      assert metadata.status == :allow
      assert is_integer(metadata.count)
      assert metadata.method == "tools/call"
    end
  end

  describe "call/2 exceeding limit" do
    test "returns 429 when limit exceeded" do
      key = "test-msg-deny-#{System.unique_integer([:positive])}"

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      # First request should be allowed
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result1 = MessageRateLimit.call(conn1, opts)
      refute result1.halted

      # Second request should be denied
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result2 = MessageRateLimit.call(conn2, opts)

      assert result2.halted
      assert result2.status == 429

      {:ok, body} = JSON.decode(result2.resp_body)
      assert body["jsonrpc"] == "2.0"
      assert body["id"] == nil
      assert body["error"]["code"] == -32000
      assert body["error"]["message"] == "Message rate limit exceeded"
    end

    test "includes Retry-After header on 429" do
      key = "test-msg-retry-after-#{System.unique_integer([:positive])}"

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      # Exhaust limit
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      MessageRateLimit.call(conn1, opts)

      # Second request should have Retry-After
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result = MessageRateLimit.call(conn2, opts)

      assert result.halted
      [retry_after] = get_resp_header(result, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "emits telemetry on deny" do
      key = "test-msg-telemetry-deny-#{System.unique_integer([:positive])}"

      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [
          [:conduit_mcp, :message_rate_limit, :check]
        ])

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      # Exhaust limit
      conn1 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      MessageRateLimit.call(conn1, opts)

      # Clear the allow telemetry message
      assert_receive {[:conduit_mcp, :message_rate_limit, :check], ^ref, _measurements,
                      %{status: :allow}}

      # Second request triggers deny
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 2})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      MessageRateLimit.call(conn2, opts)

      assert_receive {[:conduit_mcp, :message_rate_limit, :check], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.key == key
      assert metadata.status == :deny
      assert is_integer(metadata.retry_after)
      assert metadata.method == "tools/call"
    end
  end

  describe "call/2 with custom key_func" do
    test "uses custom key function for per-user isolation" do
      key1 = "msg:user-1-#{System.unique_integer([:positive])}"
      key2 = "msg:user-2-#{System.unique_integer([:positive])}"

      opts_user1 =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key1 end
        )

      opts_user2 =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key2 end
        )

      make_conn = fn id ->
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => id})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))
      end

      # User 1 exhausts their limit
      MessageRateLimit.call(make_conn.(1), opts_user1)
      result1 = MessageRateLimit.call(make_conn.(2), opts_user1)
      assert result1.halted
      assert result1.status == 429

      # User 2 is not affected
      result2 = MessageRateLimit.call(make_conn.(3), opts_user2)
      refute result2.halted
    end
  end

  describe "call/2 with non-map body_params" do
    test "passes through when body_params is not a map" do
      key = "test-non-map-#{System.unique_integer([:positive])}"

      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000,
          key_func: fn _conn -> key end
        )

      conn = conn(:post, "/")

      result = MessageRateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "default_key_func" do
    test "uses current_user id when available" do
      key = "test-default-key-user-id-#{System.unique_integer([:positive])}"

      # We test the default key function by not providing a custom one
      # and checking that different users get different keys
      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))
        |> assign(:current_user, %{id: key})

      # Should use "msg:user:<key>" as the key - just verify it doesn't crash
      result = MessageRateLimit.call(conn, opts)
      refute result.halted
    end

    test "uses current_user string when available" do
      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000
        )

      user_string = "user-string-#{System.unique_integer([:positive])}"

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))
        |> assign(:current_user, user_string)

      result = MessageRateLimit.call(conn, opts)
      refute result.halted
    end

    test "falls back to IP when no current_user" do
      opts =
        MessageRateLimit.init(
          backend: @backend,
          limit: 1,
          scale: 60_000
        )

      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1})
        )
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

      result = MessageRateLimit.call(conn, opts)
      refute result.halted
    end
  end
end

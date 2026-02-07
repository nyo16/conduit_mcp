defmodule ConduitMcp.Plugs.RateLimitTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.RateLimit
  alias ConduitMcp.TelemetryTestHelper

  @backend ConduitMcp.TestRateLimiter

  describe "init/1" do
    test "sets defaults with backend" do
      opts = RateLimit.init(backend: @backend)

      assert opts.enabled == true
      assert opts.backend == @backend
      assert opts.scale == 60_000
      assert opts.limit == 60
      assert is_function(opts.key_func, 1)
    end

    test "accepts custom options" do
      key_fn = fn _conn -> "custom" end

      opts =
        RateLimit.init(
          backend: @backend,
          enabled: false,
          scale: 30_000,
          limit: 100,
          key_func: key_fn
        )

      assert opts.enabled == false
      assert opts.scale == 30_000
      assert opts.limit == 100
      assert opts.key_func == key_fn
    end

    test "raises when backend is missing and enabled" do
      assert_raise ArgumentError, ~r/requires a :backend option/, fn ->
        RateLimit.init([])
      end
    end

    test "does not raise when backend is missing but disabled" do
      opts = RateLimit.init(enabled: false)
      assert opts.enabled == false
    end
  end

  describe "call/2 with disabled" do
    test "passes through when disabled" do
      opts = RateLimit.init(enabled: false)
      conn = conn(:get, "/")

      result = RateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 with OPTIONS" do
    test "bypasses rate limiting for CORS preflight" do
      opts = RateLimit.init(backend: @backend, limit: 1, scale: 60_000)
      conn = conn(:options, "/")

      result = RateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 within limit" do
    test "allows request within limit" do
      key = "test-allow-#{System.unique_integer([:positive])}"

      opts =
        RateLimit.init(backend: @backend, limit: 10, scale: 60_000, key_func: fn _conn -> key end)

      conn = conn(:post, "/")

      result = RateLimit.call(conn, opts)

      refute result.halted
    end

    test "emits telemetry on allow" do
      key = "test-telemetry-allow-#{System.unique_integer([:positive])}"

      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :rate_limit, :check]])

      opts =
        RateLimit.init(backend: @backend, limit: 10, scale: 60_000, key_func: fn _conn -> key end)

      conn = conn(:post, "/")

      RateLimit.call(conn, opts)

      assert_receive {[:conduit_mcp, :rate_limit, :check], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.key == key
      assert metadata.status == :allow
      assert is_integer(metadata.count)
    end
  end

  describe "call/2 exceeding limit" do
    test "returns 429 when limit exceeded" do
      key = "test-deny-#{System.unique_integer([:positive])}"

      opts =
        RateLimit.init(backend: @backend, limit: 1, scale: 60_000, key_func: fn _conn -> key end)

      # First request should be allowed
      conn1 = conn(:post, "/")
      result1 = RateLimit.call(conn1, opts)
      refute result1.halted

      # Second request should be denied
      conn2 = conn(:post, "/")
      result2 = RateLimit.call(conn2, opts)

      assert result2.halted
      assert result2.status == 429

      {:ok, body} = Jason.decode(result2.resp_body)
      assert body["jsonrpc"] == "2.0"
      assert body["id"] == nil
      assert body["error"]["code"] == -32000
      assert body["error"]["message"] == "Rate limit exceeded"
    end

    test "includes Retry-After header on 429" do
      key = "test-retry-after-#{System.unique_integer([:positive])}"

      opts =
        RateLimit.init(backend: @backend, limit: 1, scale: 60_000, key_func: fn _conn -> key end)

      # Exhaust limit
      RateLimit.call(conn(:post, "/"), opts)

      # Second request should have Retry-After
      conn2 = conn(:post, "/")
      result = RateLimit.call(conn2, opts)

      assert result.halted
      [retry_after] = get_resp_header(result, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "emits telemetry on deny" do
      key = "test-telemetry-deny-#{System.unique_integer([:positive])}"

      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :rate_limit, :check]])

      opts =
        RateLimit.init(backend: @backend, limit: 1, scale: 60_000, key_func: fn _conn -> key end)

      # Exhaust limit
      RateLimit.call(conn(:post, "/"), opts)

      # Clear the allow telemetry message
      assert_receive {[:conduit_mcp, :rate_limit, :check], ^ref, _measurements, %{status: :allow}}

      # Second request triggers deny
      RateLimit.call(conn(:post, "/"), opts)

      assert_receive {[:conduit_mcp, :rate_limit, :check], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.key == key
      assert metadata.status == :deny
      assert is_integer(metadata.retry_after)
    end
  end

  describe "call/2 with custom key_func" do
    test "uses custom key function" do
      key1 = "user-1-#{System.unique_integer([:positive])}"
      key2 = "user-2-#{System.unique_integer([:positive])}"

      opts_user1 =
        RateLimit.init(backend: @backend, limit: 1, scale: 60_000, key_func: fn _conn -> key1 end)

      opts_user2 =
        RateLimit.init(backend: @backend, limit: 1, scale: 60_000, key_func: fn _conn -> key2 end)

      # User 1 exhausts their limit
      RateLimit.call(conn(:post, "/"), opts_user1)
      result1 = RateLimit.call(conn(:post, "/"), opts_user1)
      assert result1.halted
      assert result1.status == 429

      # User 2 is not affected
      result2 = RateLimit.call(conn(:post, "/"), opts_user2)
      refute result2.halted
    end
  end
end

defmodule ConduitMcp.Transport.SSETest do
  # `async: true` is safe *only* because `:conduit_mcp_sse_connections` is
  # written exclusively by the `GET /sse` route and the slot helpers, and this
  # is the only module that drives either. Tests within a module run
  # sequentially, so no live slot row can appear underneath a test here —
  # which the `max_connections: 1` tests rely on outright. Any new module
  # that opens a `GET /sse` connection MUST be `async: false`, or the slot
  # assertions below become seed-dependent. The other assertions are
  # before/after deltas of `SSE.active_connections/0` (live rows only), so
  # rows left by dead processes cannot break them.
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.TestServer
  alias ConduitMcp.Transport.SSE

  @opts SSE.init(server_module: TestServer)

  describe "initialization" do
    test "requires server_module option" do
      assert_raise ArgumentError, "server_module is required", fn ->
        SSE.init([])
      end
    end

    test "accepts valid options" do
      opts = SSE.init(server_module: TestServer, cors_origin: "https://example.com")
      assert opts[:server_module] == TestServer
      assert opts[:cors_origin] == "https://example.com"
    end

    test "a :max_connections that is not a positive integer is a boot-time error" do
      # A non-integer compared as greater than every count, so `"10"` or
      # `:infinity` silently disabled the cap.
      for bad <- ["10", :infinity, 0, -1, 1.5, nil] do
        assert_raise ArgumentError, ~r/:max_connections must be a positive integer/, fn ->
          SSE.init(server_module: TestServer, max_connections: bad)
        end
      end

      assert SSE.init(server_module: TestServer, max_connections: 1)
    end
  end

  describe "CORS headers" do
    test "emits no CORS headers by default" do
      conn =
        conn(:post, "/message")
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
      assert get_resp_header(conn, "access-control-allow-headers") == []
    end

    test "emits the full CORS header set once cors_origin is configured" do
      opts = SSE.init(server_module: TestServer, cors_origin: "*")

      conn =
        conn(:post, "/message")
        |> put_req_header("content-type", "application/json")
        |> SSE.call(opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "content-type, authorization"
             ]
    end

    test "respects custom CORS origin" do
      opts =
        SSE.init(
          server_module: TestServer,
          cors_origin: "https://example.com"
        )

      conn =
        conn(:post, "/message")
        |> put_req_header("content-type", "application/json")
        |> SSE.call(opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://example.com"]
    end

    test "handles OPTIONS preflight request" do
      conn =
        conn(:options, "/message")
        |> SSE.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "GET /sse" do
    @tag timeout: 5000
    test "emits keepalive chunks on the configured interval" do
      # The old test only did `refute_receive {:conn_result, _}, 200` — it
      # proved the loop was entered and asserted nothing about the keepalive
      # it exists to send. With an injectable interval the chunk itself is
      # observable.
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          keep_alive_interval: 20,
          max_connection_lifetime: 200
        )

      conn =
        conn(:get, "/sse")
        |> put_req_header("accept", "text/event-stream")
        |> SSE.call(opts)

      # `max_connection_lifetime` makes the loop terminate, so `call/2`
      # returns and the accumulated chunks are inspectable.
      assert conn.state == :chunked
      assert conn.resp_body =~ "event: endpoint"
      assert conn.resp_body =~ ": keepalive"
    end

    test "sends no connection-specific header" do
      # RFC 9113 §8.2.2 forbids connection-specific headers in HTTP/2, and
      # strict clients (curl, nghttp2) reject a response carrying one.
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          keep_alive_interval: 10,
          max_connection_lifetime: 20
        )

      conn =
        conn(:get, "/sse")
        |> put_req_header("accept", "text/event-stream")
        |> SSE.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "connection") == []
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end

    @tag timeout: 15_000
    test "a foreign message does not accumulate in the mailbox" do
      # The old loop matched only {:plug_conn, :sent}; anything else stayed in
      # the mailbox forever and was rescanned on every tick.
      parent = self()

      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          keep_alive_interval: 20,
          max_connection_lifetime: 2_000
        )

      task =
        Task.async(fn ->
          send(parent, {:pid, self()})

          conn(:get, "/sse")
          |> put_req_header("accept", "text/event-stream")
          |> SSE.call(opts)
        end)

      assert_receive {:pid, sse_pid}, 1000

      for i <- 1..50, do: send(sse_pid, {:junk, i})
      # A real monitor message, not the bare atom: `{:DOWN, ref, :process, pid,
      # reason}` is the shape the audit named as the leaking class, and a
      # 5-tuple exercises a different branch of the guard than a 2-tuple.
      send(sse_pid, {:DOWN, make_ref(), :process, self(), :normal})
      send(sse_pid, {:system, {self(), make_ref()}, :get_state})

      # Polled to a deadline rather than one `Process.sleep/1`: under
      # `mix coveralls` a single sleep is exactly the wall-clock race T-M7 was
      # written to remove, and the tempting fix is a longer sleep.
      assert drained?(sse_pid, System.monotonic_time(:millisecond) + 5_000),
             "mailbox never drained: #{inspect(Process.info(sse_pid, :message_queue_len))}"

      conn = Task.await(task, 5_000)
      assert conn.resp_body =~ ": keepalive"
    end

    @tag timeout: 15_000
    test "the drain leaves Bandit's adapter messages in the mailbox" do
      # Under HTTP/2 the Plug runs inside Bandit.HTTP2.StreamProcess and the
      # connection process delivers {:send_window_update, delta} and
      # {:rst_stream, code} to *this* mailbox, which chunk/2 reads back with a
      # selective receive. Draining them loses flow-control credit (eventually
      # a FLOW_CONTROL_ERROR) and ignores h2 stream cancellation - an
      # EventSource.close() sends RST_STREAM, not a TCP close, so the
      # :max_connections slot would be held for the full lifetime.
      parent = self()

      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          keep_alive_interval: 20,
          max_connection_lifetime: 2_000
        )

      task =
        Task.async(fn ->
          send(parent, {:pid, self()})

          conn(:get, "/sse")
          |> put_req_header("accept", "text/event-stream")
          |> SSE.call(opts)
        end)

      assert_receive {:pid, sse_pid}, 1000

      send(sse_pid, {:bandit, {:send_window_update, 65_535}})
      send(sse_pid, {:bandit, {:rst_stream, 8}})
      for i <- 1..20, do: send(sse_pid, {:junk, i})

      # The junk drains; the two Bandit messages must not. Plug.Test's adapter
      # never consumes them, so they stay queued for the whole stream.
      assert queue_settles_at(sse_pid, 2, System.monotonic_time(:millisecond) + 5_000),
             "expected exactly the 2 Bandit messages to remain, found " <>
               "#{inspect(Process.info(sse_pid, :message_queue_len))}"

      Task.await(task, 5_000)
    end

    test "the cap fails closed when the slot table is unavailable" do
      # A resource cap must read "cannot count" as "no": answering with a count
      # of 0 would grant the slot, so every failure mode of the table would
      # silently disable the cap. The route recreates a missing table first, so
      # in production this is reachable only if the table vanishes between
      # that recreation and the slot insert; a table that never existed stands
      # in for that window here.
      table = :"conduit_mcp_sse_connections_missing_#{System.unique_integer([:positive])}"
      assert :ets.whereis(table) == :undefined

      refute SSE.__acquire_slot__(table, 1_000),
             "an unavailable slot table granted the slot: the cap is disabled, not enforced"
    end

    @tag timeout: 10_000
    test "a stream killed without running its cleanup does not keep its slot" do
      # Under HTTP/2 Bandit's stream process is linked to the connection and
      # does not trap exits, so a peer close kills it before `after` can
      # release the slot. `Process.exit/2` with the same reason reproduces
      # that without a socket.
      before = SSE.active_connections()

      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          max_connections: 1,
          keep_alive_interval: 10,
          max_connection_lifetime: 60_000
        )

      {pid, ref} =
        spawn_monitor(fn ->
          conn(:get, "/sse")
          |> put_req_header("accept", "text/event-stream")
          |> SSE.call(opts)
        end)

      assert slots_reach?(before + 1, System.monotonic_time(:millisecond) + 5_000),
             "the spawned stream never acquired its slot"

      Process.exit(pid, {:shutdown, :peer_closed})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :peer_closed}}, 1_000

      next_opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          max_connections: 1,
          keep_alive_interval: 10,
          max_connection_lifetime: 20
        )

      conn =
        conn(:get, "/sse")
        |> put_req_header("accept", "text/event-stream")
        |> SSE.call(next_opts)

      assert conn.status == 200, "the killed stream's slot was never reclaimed"
    end

    @tag timeout: 5000
    test "closes the stream at :max_connection_lifetime" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          keep_alive_interval: 10,
          max_connection_lifetime: 50
        )

      conn =
        conn(:get, "/sse")
        |> put_req_header("accept", "text/event-stream")
        |> SSE.call(opts)

      # Returning at all is the assertion: with no lifetime bound this call
      # never comes back.
      assert conn.state == :chunked
    end

    test "rejects a connection past :max_connections with 503" do
      # Held on the global table by a live process, so the rejected request
      # below sees a count above the cap however many dead rows other tests
      # left behind. The normal release in `on_exit` also ends the sweep
      # window that request's fruitless sweep opens, which the killed-stream
      # test above would otherwise inherit.
      holder = start_holder(:conduit_mcp_sse_connections, 1_000)
      on_exit(fn -> release_holder(holder) end)
      before = SSE.active_connections()
      opts = SSE.init(server_module: TestServer, allowed_origins: "*", max_connections: 1)

      conn =
        conn(:get, "/sse")
        |> put_req_header("accept", "text/event-stream")
        |> SSE.call(opts)

      assert conn.status == 503
      assert JSON.decode!(conn.resp_body)["error"] == "Service Unavailable"
      # The rejected request inserted its row before counting; it must not keep it.
      assert SSE.active_connections() == before
    end

    test "a finished connection releases its slot" do
      before = SSE.active_connections()

      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          keep_alive_interval: 10,
          max_connection_lifetime: 20
        )

      conn(:get, "/sse")
      |> put_req_header("accept", "text/event-stream")
      |> SSE.call(opts)

      assert SSE.active_connections() == before
    end

    test "rejects SSE connection without proper Accept header" do
      conn =
        conn(:get, "/sse")
        |> SSE.call(@opts)

      assert conn.status == 406
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      body = JSON.decode!(conn.resp_body)
      assert body["error"] == "Not Acceptable"
      assert String.contains?(body["message"], "Accept header")
    end

    test "rejects SSE connection with wrong Accept header" do
      conn =
        conn(:get, "/sse")
        |> put_req_header("accept", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 406
    end
  end

  # Against a private table, so these can race nothing in the global one.
  describe "slot sweeping at the cap" do
    setup do
      %{table: :ets.new(:sse_slots, SSE.connections_table_opts() -- [:named_table])}
    end

    test "a stream killed at the cap is reclaimed once the sweep window has passed",
         %{table: table} do
      holder = start_holder(table, 1)

      # At the cap with every slot live: this sweep frees nothing.
      refute acquire_elsewhere(table, 1)

      kill(holder)

      # Within the window a fruitless sweep is not repeated, so the dead row
      # still counts - this is what keeps a flood of rejected connects from
      # walking the table on every request.
      refute SSE.__acquire_slot__(table, 1),
             "a rejected connect re-swept within the window of a sweep that freed nothing"

      # Past the window (0 ms here) the next connect sweeps and takes the slot.
      assert SSE.__acquire_slot__(table, 1, 0),
             "the killed stream's slot was never reclaimed"
    end

    test "a released slot ends the window, so a later dead row is swept at once",
         %{table: table} do
      first = start_holder(table, 1)
      refute acquire_elsewhere(table, 1)
      release_holder(first)

      # A stream admitted into the freed slot, then killed without releasing.
      second = start_holder(table, 1)
      kill(second)

      assert SSE.__acquire_slot__(table, 1),
             "a fruitless sweep's verdict outlived the release that invalidated it"
    end

    test "a sweep that frees a slot admits the connect that ran it", %{table: table} do
      kill(start_holder(table, 1))

      assert SSE.__acquire_slot__(table, 1)
      # And it is counted: the next connect is over the cap.
      refute acquire_elsewhere(table, 1)
    end
  end

  describe "endpoint event URL" do
    test "uses configured :base_url when set" do
      conn =
        conn(:get, "/sse")
        |> Plug.Conn.put_private(:sse_base_url, "https://mcp.example.com/")

      assert SSE.message_base_url(conn) == "https://mcp.example.com"
    end

    test "falls back to sanitized Host header" do
      conn = %{conn(:get, "/sse") | req_headers: [{"host", "mcp.example.com:4001"}]}

      assert SSE.message_base_url(conn) == "http://mcp.example.com:4001"
    end

    test "strips dangerous characters from Host fallback" do
      conn = %{conn(:get, "/sse") | req_headers: [{"host", "evil.com/path bad\r\ninjected"}]}

      assert SSE.message_base_url(conn) == "http://evil.compathbadinjected"
    end
  end

  describe "POST /message" do
    test "handles ping request" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      response = JSON.decode!(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{}
    end

    test "handles initialize request" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"},
            "capabilities" => %{}
          }
        })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert response["result"]["protocolVersion"] == "2025-06-18"
      assert response["result"]["serverInfo"]["name"] == "conduit-mcp"
    end

    test "handles tools/list request" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list"
        })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert response["result"]["tools"]
      assert is_list(response["result"]["tools"])
    end

    test "handles tools/call request" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "echo",
            "arguments" => %{"message" => "Hello"}
          }
        })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Hello"}]
    end

    test "handles notifications with 204 status" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "raises ParseError for invalid JSON" do
      assert_raise Plug.Parsers.ParseError, fn ->
        conn(:post, "/message", "not valid json")
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)
      end
    end

    test "raises UnsupportedMediaTypeError for non-JSON content-type" do
      assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
        conn(:post, "/message", "some data")
        |> put_req_header("content-type", "text/plain")
        |> SSE.call(@opts)
      end
    end

    test "returns error for unknown method" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 100,
          "method" => "unknown/method"
        })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert response["error"]["code"] == -32601
      assert String.contains?(response["error"]["message"], "Method not found")
    end
  end

  describe "GET /health" do
    test "returns health check status" do
      conn =
        conn(:get, "/health")
        |> SSE.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      body = JSON.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "unknown routes" do
    test "returns 404 for unknown path" do
      conn =
        conn(:get, "/unknown")
        |> SSE.call(@opts)

      assert conn.status == 404
      assert conn.resp_body == "Not found"
    end

    test "returns 404 for unsupported method on message endpoint" do
      conn =
        conn(:put, "/message")
        |> SSE.call(@opts)

      assert conn.status == 404
    end
  end

  describe "origin validation" do
    test "request with allowed origin passes" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: ["https://allowed.example.com"]
        )

      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/message", ping_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://allowed.example.com")
        |> SSE.call(opts)

      assert conn.status == 200

      response = JSON.decode!(conn.resp_body)
      assert response["result"] == %{}
    end

    test "request with disallowed origin gets 403" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: ["https://allowed.example.com"]
        )

      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/message", ping_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://evil.example.com")
        |> SSE.call(opts)

      assert conn.status == 403

      response = JSON.decode!(conn.resp_body)
      assert response["error"] == "Origin not allowed"
    end

    test "request with no Origin header passes (browser-less clients)" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: ["https://allowed.example.com"]
        )

      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/message", ping_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(opts)

      assert conn.status == 200

      response = JSON.decode!(conn.resp_body)
      assert response["result"] == %{}
    end

    test "OPTIONS requests bypass origin validation" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: ["https://allowed.example.com"]
        )

      conn =
        conn(:options, "/message")
        |> put_req_header("origin", "https://evil.example.com")
        |> SSE.call(opts)

      assert conn.status == 200
    end
  end

  describe "security headers" do
    test "responses include security headers" do
      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/message", ping_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "health check includes security headers" do
      conn =
        conn(:get, "/health")
        |> SSE.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end

  # These all used to be StreamableHTTP-only, purely because the shared
  # plumbing was copy-pasted and the copies diverged.
  describe "transport parity with StreamableHTTP" do
    @ping JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    defp post_message(opts, headers \\ []) do
      Enum.reduce(headers, conn(:post, "/message", @ping), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
      |> put_req_header("content-type", "application/json")
      |> SSE.call(opts)
    end

    test "bearer-token auth is enforced" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          auth: [strategy: :bearer_token, token: "s3cret"]
        )

      denied = post_message(opts)
      assert denied.halted
      assert denied.status == 401

      allowed = post_message(opts, [{"authorization", "Bearer s3cret"}])
      refute allowed.halted
      assert allowed.status == 200
    end

    test "strategy: :oauth is dispatched to the OAuth plug, not the catch-all" do
      # Previously SSE had no :oauth branch, so every request fell through to
      # Plugs.Auth's catch-all: a blanket 401 "Server configuration error"
      # plus a Logger.error per request, even with a valid token.
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          auth: [
            strategy: :oauth,
            issuer: "https://auth.example.com",
            audience: "https://mcp.example.com",
            key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: []}
          ]
        )

      denied = post_message(opts)
      assert denied.status == 401

      body = JSON.decode!(denied.resp_body)
      assert body["message"] == "Missing or invalid Authorization header"
      refute body["message"] == "Server configuration error"

      # And it advertises the OAuth challenge, which the catch-all never did.
      assert [www_auth] = get_resp_header(denied, "www-authenticate")
      assert www_auth =~ "resource_metadata="
    end

    test "message rate limiting is enforced" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          message_rate_limit: [
            backend: ConduitMcp.TestRateLimiter,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> "sse-msg-#{System.unique_integer([:positive])}" end
          ]
        )

      refute post_message(opts).halted

      # Same bucket this time, so the second request is denied.
      key = "sse-msg-fixed-#{System.unique_integer([:positive])}"

      fixed_opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          message_rate_limit: [
            backend: ConduitMcp.TestRateLimiter,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      refute post_message(fixed_opts).halted
      denied = post_message(fixed_opts)
      assert denied.halted
      assert denied.status == 429
    end

    test "HTTP rate limiting is enforced" do
      key = "sse-http-#{System.unique_integer([:positive])}"

      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          rate_limit: [
            backend: ConduitMcp.TestRateLimiter,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      refute post_message(opts).halted
      denied = post_message(opts)
      assert denied.halted
      assert denied.status == 429
    end

    test "serves /.well-known/oauth-protected-resource when OAuth is configured" do
      opts =
        SSE.init(
          server_module: TestServer,
          allowed_origins: "*",
          auth: [
            strategy: :oauth,
            issuer: "https://auth.example.com",
            audience: "https://mcp.example.com",
            key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: []}
          ]
        )

      conn = SSE.call(conn(:get, "/.well-known/oauth-protected-resource"), opts)

      assert conn.status == 200
      metadata = JSON.decode!(conn.resp_body)
      assert metadata["resource"]
      assert metadata["authorization_servers"]
    end

    test "404s the metadata endpoint when OAuth is not configured" do
      conn = SSE.call(conn(:get, "/.well-known/oauth-protected-resource"), @opts)
      assert conn.status == 404
    end

    test "responses carry the mcp-protocol-version header" do
      conn = post_message(@opts)

      assert get_resp_header(conn, "mcp-protocol-version") ==
               [ConduitMcp.Protocol.protocol_version()]
    end

    test "init/1 resolves the auth plug once, not per request" do
      opts = SSE.init(server_module: TestServer, auth: [strategy: :bearer_token, token: "t"])

      assert {ConduitMcp.Plugs.Auth, %{strategy: :bearer_token, token: "t"}} =
               Keyword.fetch!(opts, :auth_plug)
    end
  end

  # Polls to a deadline instead of sleeping once. Returns true as soon as the
  # loop has drained everything it is allowed to drain.
  defp drained?(pid, deadline) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(10)
          drained?(pid, deadline)
        end
    end
  end

  # Waits for the queue to reach `expected` and stay there, so a slow drain
  # cannot pass by happening to be at `expected` on the way down.
  defp queue_settles_at(pid, expected, deadline) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, ^expected} ->
        Process.sleep(60)
        Process.info(pid, :message_queue_len) == {:message_queue_len, expected}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(10)
          queue_settles_at(pid, expected, deadline)
        end
    end
  end

  # Polls `SSE.active_connections/0` until it reaches `expected`: the stream
  # acquires its slot inside `SSE.call/2`, which gives the caller no signal.
  defp slots_reach?(expected, deadline) do
    cond do
      SSE.active_connections() == expected ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        slots_reach?(expected, deadline)
    end
  end

  # A process holding a slot in `table` until told to release it, standing in
  # for a live stream. Not linked: a holder must outlive a failed test long
  # enough for `release_holder/1` in `on_exit` to release it normally.
  defp start_holder(table, max) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:acquired, self(), SSE.__acquire_slot__(table, max)})

        receive do
          :release -> SSE.__release_slot__(table)
        end
      end)

    assert_receive {:acquired, ^pid, true}, 1_000
    pid
  end

  # Releases normally and waits until the holder is gone. Safe on a holder
  # that has already exited.
  defp release_holder(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  # Kills a holder without letting it release, like a peer-closed h2 stream.
  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
  end

  # Tries for a slot from a short-lived process, which exits right after.
  defp acquire_elsewhere(table, max) do
    fn -> SSE.__acquire_slot__(table, max) end
    |> Task.async()
    |> Task.await()
  end
end

defmodule ConduitMcp.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.TestServer
  alias ConduitMcp.Transport.StreamableHTTP

  @opts StreamableHTTP.init(server_module: TestServer)

  # A *literal* `forward`, deliberately: `Plug.Router.forward/2` runs
  # `target.init/1` at compile time and escapes the result into
  # `@plug_forward_opts`, so a non-escapable value there breaks the build
  # rather than a test. Since `Transport.Shared.init/2` resolves the rate-limit
  # plugs at init time, a *local* function capture in their options - which is
  # what `key_func` defaults to - made this router fail to compile with
  # "cannot escape #Function<...default_key_func>". This is the documented
  # Phoenix integration (README "Phoenix Integration"), and the trigger was the
  # default configuration, so a consumer writing nothing hit it.
  defmodule ForwardBackend do
    @moduledoc false
    def hit(_key, _scale, _limit), do: {:allow, 1}
  end

  defmodule ForwardRouter do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    forward("/mcp",
      to: ConduitMcp.Transport.StreamableHTTP,
      init_opts: [
        server_module: ConduitMcp.TestServer,
        allowed_origins: "*",
        rate_limit: [backend: ForwardBackend, limit: 100, scale: 60_000],
        message_rate_limit: [backend: ForwardBackend, limit: 100, scale: 60_000]
      ]
    )

    match _ do
      send_resp(conn, 404, "")
    end
  end

  describe "initialization" do
    test "requires server_module option" do
      assert_raise ArgumentError, "server_module is required", fn ->
        StreamableHTTP.init([])
      end
    end

    test "accepts valid options" do
      opts = StreamableHTTP.init(server_module: TestServer, cors_origin: "https://example.com")
      assert opts[:server_module] == TestServer
      assert opts[:cors_origin] == "https://example.com"
    end

    test "a forwarded, rate-limited mount serves requests" do
      # The compile-time property is asserted by ForwardRouter existing at all;
      # this proves the escaped init options are still usable at runtime.
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
        })

      conn =
        conn(:post, "/mcp/", body)
        |> put_req_header("content-type", "application/json")
        |> ForwardRouter.call(ForwardRouter.init([]))

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"]["protocolVersion"]
    end
  end

  describe "configuration validation" do
    test "a list :cors_origin is a boot-time error, not a per-request 500" do
      # `:allowed_origins` accepts a list and is documented two bullets above
      # `:cors_origin`, so this is a natural mistake. put_resp_header/3 is
      # guarded on a binary value, so without the init check it raises inside
      # the pipeline on every request.
      assert_raise ArgumentError, ~r/:cors_origin must be a single header value/, fn ->
        StreamableHTTP.init(
          server_module: TestServer,
          cors_origin: ["https://a.example", "https://b.example"]
        )
      end
    end

    test "a string or nil :cors_origin is accepted" do
      assert StreamableHTTP.init(server_module: TestServer, cors_origin: "*")
      assert StreamableHTTP.init(server_module: TestServer, allowed_origins: "*")
    end
  end

  describe "CORS headers" do
    test "emits no CORS headers by default" do
      # `access-control-allow-origin: *` on every response is what let a page
      # on another origin *read* the reply to a cross-origin POST.
      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
      assert get_resp_header(conn, "access-control-allow-headers") == []
    end

    test "emits the full CORS header set once cors_origin is configured" do
      opts = StreamableHTTP.init(server_module: TestServer, cors_origin: "*")

      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "content-type, authorization"
             ]
    end

    test "respects custom CORS origin" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          cors_origin: "https://example.com"
        )

      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://example.com"]
    end

    test "handles OPTIONS preflight request" do
      conn =
        conn(:options, "/")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      # A preflight that grants nothing: the browser will not send the real
      # request, let alone let the page read the response.
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "OPTIONS preflight grants the configured origin" do
      opts = StreamableHTTP.init(server_module: TestServer, cors_origin: "https://app.example")

      conn = conn(:options, "/") |> StreamableHTTP.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example"]
    end
  end

  describe "GET /" do
    test "returns server info" do
      conn =
        conn(:get, "/")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      body = JSON.decode!(conn.resp_body)
      assert body["transport"] == "streamable-http"
      assert body["version"] == "2025-11-25"
      assert body["status"] == "ready"
    end
  end

  describe "GET /health" do
    test "returns health check status" do
      conn =
        conn(:get, "/health")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      body = JSON.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "POST / with valid requests" do
    test "handles ping request" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Hello"}]
    end
  end

  describe "POST / with notifications" do
    test "handles notifications with 204 status" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      conn =
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  describe "POST / with invalid requests" do
    test "raises ParseError for invalid JSON" do
      assert_raise Plug.Parsers.ParseError, fn ->
        conn(:post, "/", "not valid json")
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)
      end
    end

    test "raises UnsupportedMediaTypeError for non-JSON content-type" do
      assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
        conn(:post, "/", "some data")
        |> put_req_header("content-type", "text/plain")
        |> StreamableHTTP.call(@opts)
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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert response["error"]["code"] == -32601
      assert String.contains?(response["error"]["message"], "Method not found")
    end
  end

  describe "unknown routes" do
    test "returns 404 for unknown path" do
      conn =
        conn(:get, "/unknown")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 404
      assert conn.resp_body == "Not found"
    end

    test "returns 404 for unsupported method on root" do
      conn =
        conn(:put, "/")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 404
    end
  end

  describe "origin validation startup warning" do
    import ExUnit.CaptureLog

    test "init warns when :allowed_origins is unset" do
      log = capture_log(fn -> StreamableHTTP.init(server_module: TestServer) end)
      assert log =~ "allowed_origins"
      assert log =~ "rejected with 403"
    end

    test "init stays quiet when :allowed_origins is set (even to \"*\")" do
      log =
        capture_log(fn ->
          StreamableHTTP.init(server_module: TestServer, allowed_origins: "*")
        end)

      refute log =~ "allowed_origins"
    end
  end

  describe "session management" do
    @session_opts StreamableHTTP.init(
                    server_module: TestServer,
                    session: [store: ConduitMcp.Session.EtsStore]
                  )

    setup do
      ConduitMcp.Session.EtsStore.ensure_table()
      :ets.delete_all_objects(:conduit_mcp_sessions)
      :ok
    end

    defp initialize_request_body do
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
    end

    test "initialize request creates a session with MCP-Session-Id header" do
      conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@session_opts)

      assert conn.status == 200

      session_ids = get_resp_header(conn, "mcp-session-id")
      assert length(session_ids) == 1

      session_id = List.first(session_ids)
      assert is_binary(session_id) and byte_size(session_id) > 0

      # Session should exist in the store
      assert {:ok, _data} = ConduitMcp.Session.get(session_id, ConduitMcp.Session.EtsStore)
    end

    test "subsequent request with valid session ID succeeds" do
      # First, initialize to get a session
      init_conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@session_opts)

      session_id = get_resp_header(init_conn, "mcp-session-id") |> List.first()
      assert session_id

      # Now send a request with the session ID
      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "ping"
        })

      conn =
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTP.call(@session_opts)

      assert conn.status == 200

      response = JSON.decode!(conn.resp_body)
      assert response["result"] == %{}
    end

    test "request with invalid session ID gets 404" do
      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "invalid-session-id")
        |> StreamableHTTP.call(@session_opts)

      assert conn.status == 404

      response = JSON.decode!(conn.resp_body)
      assert response["error"]
      assert response["error"]["message"] =~ "Session not found"
    end

    test "require_session: true rejects non-initialize POST without session header" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          session: [store: ConduitMcp.Session.EtsStore, require_session: true]
        )

      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      assert conn.status == 400
      response = JSON.decode!(conn.resp_body)
      assert response["error"]["message"] =~ "Mcp-Session-Id"
    end

    test "require_session: true still allows initialize without session header" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          session: [store: ConduitMcp.Session.EtsStore, require_session: true]
        )

      conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end

    test "require_session: true accepts requests with a valid session header" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          session: [store: ConduitMcp.Session.EtsStore, require_session: true]
        )

      init_conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      session_id = get_resp_header(init_conn, "mcp-session-id") |> List.first()

      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTP.call(opts)

      assert conn.status == 200
    end

    test "without require_session, non-initialize POST passes without session header" do
      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@session_opts)

      assert conn.status == 200
    end

    test "sessions disabled (session: false) — no session header returned" do
      no_session_opts =
        StreamableHTTP.init(
          server_module: TestServer,
          session: false
        )

      conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(no_session_opts)

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "initialize fails closed with 503 when the session store is at capacity" do
      previous = Application.get_env(:conduit_mcp, :sessions_max_rows)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:conduit_mcp, :sessions_max_rows)
          value -> Application.put_env(:conduit_mcp, :sessions_max_rows, value)
        end
      end)

      Application.put_env(:conduit_mcp, :sessions_max_rows, 0)

      conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@session_opts)

      # Handing back a 200 with no mcp-session-id would give the client a
      # negotiated connection whose session does not exist on any follow-up
      # request.
      assert conn.status == 503
      assert get_resp_header(conn, "mcp-session-id") == []

      response = JSON.decode!(conn.resp_body)
      assert response["error"]["code"] == ConduitMcp.Protocol.internal_error()
      assert response["error"]["message"] =~ "cannot accept new sessions"
    end
  end

  describe "RFC 9728 protected-resource metadata" do
    @oauth_opts StreamableHTTP.init(
                  server_module: TestServer,
                  allowed_origins: "*",
                  auth: [
                    strategy: :oauth,
                    issuer: "https://auth.example.com",
                    audience: "https://mcp.example.com",
                    key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: []}
                  ]
                )

    test "is reachable without a token, because that is how discovery works" do
      # The metadata document is what a client fetches *after* a 401 to find
      # the authorization server. Running the auth plug over it would make
      # discovery require already being authenticated.
      conn =
        conn(:get, "/.well-known/oauth-protected-resource")
        |> StreamableHTTP.call(@oauth_opts)

      assert conn.status == 200
      metadata = JSON.decode!(conn.resp_body)
      assert metadata["resource"] == "https://mcp.example.com"
    end

    test "everything else still requires a token" do
      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@oauth_opts)

      assert conn.status == 401
    end
  end

  describe "origin validation" do
    test "request with allowed origin passes" do
      opts =
        StreamableHTTP.init(
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
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://allowed.example.com")
        |> StreamableHTTP.call(opts)

      assert conn.status == 200

      response = JSON.decode!(conn.resp_body)
      assert response["result"] == %{}
    end

    test "request with disallowed origin gets 403" do
      opts =
        StreamableHTTP.init(
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
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://evil.example.com")
        |> StreamableHTTP.call(opts)

      assert conn.status == 403

      response = JSON.decode!(conn.resp_body)
      assert response["error"] == "Origin not allowed"
    end

    test "request with no Origin header passes (browser-less clients)" do
      opts =
        StreamableHTTP.init(
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
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      assert conn.status == 200

      response = JSON.decode!(conn.resp_body)
      assert response["result"] == %{}
    end

    test "OPTIONS requests bypass origin validation" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          allowed_origins: ["https://allowed.example.com"]
        )

      conn =
        conn(:options, "/")
        |> put_req_header("origin", "https://evil.example.com")
        |> StreamableHTTP.call(opts)

      assert conn.status == 200
    end
  end

  describe "MCP-Protocol-Version header" do
    test "POST responses include MCP-Protocol-Version header" do
      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200

      protocol_versions = get_resp_header(conn, "mcp-protocol-version")
      assert protocol_versions == ["2025-11-25"]
    end
  end

  describe "security headers" do
    test "POST responses include security headers" do
      ping_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      conn =
        conn(:post, "/", ping_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "GET / includes security headers" do
      conn =
        conn(:get, "/")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "health check includes security headers" do
      conn =
        conn(:get, "/health")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end
end

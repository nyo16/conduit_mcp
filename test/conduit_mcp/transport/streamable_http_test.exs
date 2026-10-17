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

    test "an :allowed_origins of an unsupported shape is a boot-time error" do
      for bad <- [42, :all, %{"origin" => "https://a.example"}, ["https://a.example", 7]] do
        assert_raise ArgumentError, ~r/:allowed_origins must be/, fn ->
          StreamableHTTP.init(server_module: TestServer, allowed_origins: bad)
        end
      end
    end

    test "a list mixing in a Regex is rejected rather than silently never matching" do
      # List entries are compared with `in`, so a Regex inside a list could
      # never match any origin.
      assert_raise ArgumentError, ~r/single Regex/, fn ->
        StreamableHTTP.init(
          server_module: TestServer,
          allowed_origins: ["https://a.example", ~r/\Ahttps:\/\/b\.example\z/]
        )
      end
    end

    test "every documented :allowed_origins shape is accepted" do
      for good <- [
            nil,
            "*",
            "https://a.example",
            [],
            ["https://a.example"],
            ~r/\Ahttps:\/\/a\.example\z/
          ] do
        assert StreamableHTTP.init(server_module: TestServer, allowed_origins: good)
      end
    end

    test "a :session that is neither off nor a keyword list is a boot-time error" do
      # Only a keyword list turns sessions on, so `session: true` used to mean
      # "no sessions" - and no `require_session` - without any signal.
      for bad <- [true, %{store: ConduitMcp.Session.EtsStore}, :ets, [:store]] do
        assert_raise ArgumentError, ~r/session: \[\]/, fn ->
          StreamableHTTP.init(server_module: TestServer, session: bad)
        end
      end
    end

    test "every documented :session shape is accepted" do
      for good <- [nil, false, [], [store: ConduitMcp.Session.EtsStore, require_session: true]] do
        assert StreamableHTTP.init(server_module: TestServer, session: good)
      end
    end
  end

  describe "sessions are opt-in" do
    setup do
      ConduitMcp.Session.EtsStore.ensure_table()
      :ok
    end

    test "without :session, initialize creates no session" do
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
        })

      before = :ets.info(:conduit_mcp_sessions, :size)

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []
      # `<=`, not `==`: the session Janitor may sweep expired rows between the
      # two reads.
      assert :ets.info(:conduit_mcp_sessions, :size) <= before
    end

    test "session: [] turns sessions on with the default store" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])

      conn =
        conn(:post, "/", initialize_request_body())
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(opts)

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert {:ok, _} = ConduitMcp.Session.get(session_id, ConduitMcp.Session.EtsStore)
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

      assert get_resp_header(conn, "access-control-allow-methods") == [
               "GET, POST, DELETE, OPTIONS"
             ]

      # A browser client must be allowed to send the session and protocol
      # headers, and to read them back; without these, a cross-origin client
      # can never present the session it was issued.
      assert get_resp_header(conn, "access-control-allow-headers") == [
               "content-type, authorization, mcp-session-id, mcp-protocol-version, " <>
                 "mcp-method, mcp-name"
             ]

      assert get_resp_header(conn, "access-control-expose-headers") == [
               "mcp-session-id, mcp-protocol-version"
             ]
    end

    test "an explicit :cors_headers replaces the default allow-headers" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          cors_origin: "*",
          cors_headers: "content-type, mcp-param-region"
        )

      conn = conn(:options, "/") |> StreamableHTTP.call(opts)

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "content-type, mcp-param-region"
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

    # The specification lets a client open a server-to-client SSE stream with
    # a GET; a server that offers none MUST answer 405. Answering 200 with a
    # JSON body told such a client the stream had opened.
    test "a GET asking for an event stream gets 405 with an allow header" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, OPTIONS"]
    end

    test "with sessions on, the allow header names DELETE too" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> StreamableHTTP.call(opts)

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, DELETE, OPTIONS"]
    end

    test "a GET with another Accept still gets the info JSON" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["status"] == "ready"
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
    # The Streamable HTTP transport answers an accepted notification or
    # response with 202 Accepted and no body; 204 is not what the
    # specification prescribes, and a strict client treats it as a failure.
    test "answers a notification with 202 and no body" do
      request_body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      conn =
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "answers a JSON-RPC response with 202 and no body" do
      request_body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 7, "result" => %{}})

      conn =
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 202
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

    # R12 / SV-8: a modern request ignores the session it presents, but must
    # not be able to present one bound to somebody else.
    test "a session records its principal, and a mixed request from another principal is refused" do
      verify = fn
        "alice-token" -> {:ok, %{id: "alice"}}
        "mallory-token" -> {:ok, %{id: "mallory"}}
        _ -> {:error, "invalid"}
      end

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          session: [store: ConduitMcp.Session.EtsStore],
          auth: [strategy: :function, verify: verify]
        )

      post = fn body, token, session_id ->
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        # Required on every modern HTTP request (Plugs.HeaderValidation);
        # ignored by the legacy initialize.
        |> put_req_header("mcp-method", body["method"])
        |> then(fn conn ->
          if body["method"] == "initialize",
            do: conn,
            else: put_req_header(conn, "mcp-protocol-version", "2026-07-28")
        end)
        |> then(&if(session_id, do: put_req_header(&1, "mcp-session-id", session_id), else: &1))
        |> StreamableHTTP.call(opts)
      end

      init_conn = post.(JSON.decode!(initialize_request_body()), "alice-token", nil)
      [session_id] = get_resp_header(init_conn, "mcp-session-id")

      assert {:ok, %{"principal" => "alice"}} =
               ConduitMcp.Session.get(session_id, ConduitMcp.Session.EtsStore)

      mixed = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }

      refused = JSON.decode!(post.(mixed, "mallory-token", session_id).resp_body)
      assert refused["error"]["code"] == ConduitMcp.Errors.invalid_request()

      allowed = JSON.decode!(post.(mixed, "alice-token", session_id).resp_body)
      assert allowed["result"]["resultType"] == "complete"
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

    # SV-12: the modern handshake is not an unauthenticated side door. An
    # anonymous `server/discover` gets the same 401 + RFC 9728 challenge a
    # legacy `ping` does, so a modern client can start OAuth discovery from it.
    test "an unauthenticated modern server/discover gets 401 with resource_metadata" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "server/discover",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }

      conn =
        post_json(body, @oauth_opts, [
          {"mcp-method", "server/discover"},
          {"mcp-protocol-version", "2026-07-28"}
        ])

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"

      assert challenge =~
               ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource")

      refute JSON.decode!(conn.resp_body)["result"]
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
    setup do
      ConduitMcp.Session.EtsStore.ensure_table()
      :ok
    end

    test "POST responses include MCP-Protocol-Version header" do
      conn = post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, @opts)

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    end

    # A client that negotiated 2025-06-18 was told on every response that the
    # connection spoke 2025-11-25, the hardcoded latest version.
    test "initialize echoes the negotiated version, not the latest" do
      conn = post_json(JSON.decode!(initialize_request_body()), @opts)

      assert JSON.decode!(conn.resp_body)["result"]["protocolVersion"] == "2025-06-18"
      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    end

    test "a session's requests echo the version negotiated at initialize" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])
      init = post_json(JSON.decode!(initialize_request_body()), opts)
      [session_id] = get_resp_header(init, "mcp-session-id")

      # The session, not the request header, is the record of what was
      # negotiated.
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}, opts, [
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "2025-11-25"}
        ])

      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    end

    test "without sessions, a supported request header is echoed" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, @opts, [
          {"mcp-protocol-version", "2025-06-18"}
        ])

      assert get_resp_header(conn, "mcp-protocol-version") == ["2025-06-18"]
    end

    # 2025-11-25 transports: an invalid or unsupported MCP-Protocol-Version
    # MUST be answered 400 Bad Request. It used to be served (and merely not
    # echoed).
    test "an unsupported request header is a 400, and is never echoed" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, @opts, [
          {"mcp-protocol-version", "1999-01-01"}
        ])

      assert conn.status == 400
      assert conn.halted
      refute conn.resp_body =~ "1999-01-01"

      assert %{"id" => 1, "error" => %{"code" => -32600, "data" => %{"supported" => supported}}} =
               JSON.decode!(conn.resp_body)

      assert supported == ConduitMcp.Protocol.supported_versions()
    end

    test "a request without the header is served (the spec's 2025-03-26 default)" do
      conn = post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, @opts)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"] == %{}
    end

    test "initialize is exempt: it negotiates the version in its body" do
      conn =
        post_json(JSON.decode!(initialize_request_body()), @opts, [
          {"mcp-protocol-version", "2099-01-01"}
        ])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"]["protocolVersion"] == "2025-06-18"
    end

    test "a DELETE with an unsupported header is a 400 too" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> StreamableHTTP.call(opts)

      assert conn.status == 400
    end
  end

  describe "DELETE / (session termination)" do
    setup do
      ConduitMcp.Session.EtsStore.ensure_table()
      :ok
    end

    defp open_session(opts) do
      init = post_json(JSON.decode!(initialize_request_body()), opts)
      [session_id] = get_resp_header(init, "mcp-session-id")
      session_id
    end

    defp send_delete(opts, headers) do
      Enum.reduce(headers, conn(:delete, "/"), fn {k, v}, conn -> put_req_header(conn, k, v) end)
      |> StreamableHTTP.call(opts)
    end

    test "ends a live session; the id is then unknown" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])
      session_id = open_session(opts)

      conn = send_delete(opts, [{"mcp-session-id", session_id}])

      assert conn.status == 200
      assert {:error, :not_found} = ConduitMcp.Session.get(session_id)

      after_delete =
        post_json(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}, opts, [
          {"mcp-session-id", session_id}
        ])

      assert after_delete.status == 404
    end

    test "an unknown session id gets the same 404 a POST does" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])

      conn = send_delete(opts, [{"mcp-session-id", "no-such-session"}])

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body)["error"]["message"] =~ "Session not found"
    end

    test "a DELETE with no session id is a 400" do
      opts = StreamableHTTP.init(server_module: TestServer, session: [])

      conn = send_delete(opts, [])

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"]["message"] =~ "Mcp-Session-Id"
    end

    test "with sessions off, DELETE is 405 with an allow header" do
      conn = send_delete(@opts, [{"mcp-session-id", "anything"}])

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, OPTIONS"]
    end

    test "DELETE still requires authentication" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          session: [],
          auth: [strategy: :bearer_token, token: "s3cret"]
        )

      conn = send_delete(opts, [{"mcp-session-id", "anything"}])

      assert conn.status == 401
    end
  end

  describe "insufficient OAuth scope" do
    defmodule ScopedServer do
      @moduledoc false
      use ConduitMcp.Server

      tool "read_data", "Requires data:read" do
        scope("data:read")
        handle(fn _conn, _params -> text("data") end)
      end
    end

    @rsa_key JOSE.JWK.generate_key({:rsa, 2048})
    @rsa_private @rsa_key |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "k1")
    @rsa_public @rsa_key
                |> JOSE.JWK.to_public()
                |> JOSE.JWK.to_map()
                |> elem(1)
                |> Map.put("kid", "k1")

    defp oauth_opts do
      StreamableHTTP.init(
        server_module: ScopedServer,
        auth: [
          strategy: :oauth,
          issuer: "https://auth.example.com",
          audience: "https://mcp.example.com",
          key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public]}
        ]
      )
    end

    defp bearer(scope) do
      now = System.system_time(:second)

      claims = %{
        "iss" => "https://auth.example.com",
        "aud" => "https://mcp.example.com",
        "sub" => "user-1",
        "exp" => now + 3600,
        "scope" => scope
      }

      {:ok, token, _} = Joken.encode_and_sign(claims, Joken.Signer.create("RS256", @rsa_private))
      {"authorization", "Bearer " <> token}
    end

    defp call_read_data(opts, headers) do
      post_json(
        %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "read_data", "arguments" => %{}}
        },
        opts,
        headers
      )
    end

    # MCP authorization: a token lacking a scope gets 403 with an
    # `insufficient_scope` Bearer challenge naming the scope, which is what
    # lets a client step up. A JSON-RPC error at 200 gave it nothing to act on.
    test "answers 403 with an insufficient_scope challenge" do
      conn = call_read_data(oauth_opts(), [bearer("other")])

      assert conn.status == 403
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(Bearer error="insufficient_scope")
      assert challenge =~ ~s(scope="data:read")
      assert challenge =~ "resource_metadata="

      # The body is still the JSON-RPC error, correlated to the request.
      body = JSON.decode!(conn.resp_body)
      assert body["id"] == 9
      assert body["error"]["code"] == ConduitMcp.Protocol.server_error()
    end

    test "a token with the scope is served" do
      conn = call_read_data(oauth_opts(), [bearer("data:read")])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"]["content"]
    end

    # Only OAuth has an authorization server to step up with, so other
    # strategies keep the JSON-RPC error at 200.
    test "without OAuth the denial stays a JSON-RPC error at 200" do
      opts =
        StreamableHTTP.init(
          server_module: ScopedServer,
          auth: [strategy: :bearer_token, token: "s3cret"]
        )

      conn = call_read_data(opts, [{"authorization", "Bearer s3cret"}])

      assert conn.status == 200
      assert get_resp_header(conn, "www-authenticate") == []
      assert JSON.decode!(conn.resp_body)["error"]["message"] =~ "Insufficient scope"
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

  defp post_json(body, opts, headers \\ []) do
    headers
    |> Enum.reduce(conn(:post, "/", JSON.encode!(body)), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
    |> put_req_header("content-type", "application/json")
    |> StreamableHTTP.call(opts)
  end
end

defmodule ConduitMcp.Transport.SSETest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Transport.SSE
  alias ConduitMcp.TestServer

  @opts SSE.init(server_module: TestServer)

  setup do
    {:ok, _pid} = start_supervised({TestServer, []})
    :ok
  end

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
  end

  describe "CORS headers" do
    test "adds default CORS headers" do
      conn =
        conn(:post, "/message")
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
      assert get_resp_header(conn, "access-control-allow-headers") == ["content-type, authorization"]
    end

    test "respects custom CORS origin" do
      opts = SSE.init(
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
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "GET /sse" do
    @tag timeout: 2000
    test "establishes SSE connection with correct Accept header" do
      # SSE connections enter an infinite keep-alive loop (by design for long-lived connections)
      # We spawn it in a background process to verify it starts without errors
      parent = self()

      Task.async(fn ->
        conn =
          conn(:get, "/sse")
          |> put_req_header("accept", "text/event-stream")

        # This will block forever in the keep-alive loop, but we just want to verify
        # it starts successfully without raising an error
        result = SSE.call(conn, @opts)
        send(parent, {:conn_result, result})
      end)

      # Give it time to start - if headers were wrong, it would error immediately (< 100ms)
      # If it's still running after 200ms, it successfully entered the keep-alive loop
      receive do
        {:conn_result, _} -> flunk("Connection should have entered infinite loop")
      after
        200 -> assert true
      end
    end

    test "rejects SSE connection without proper Accept header" do
      conn =
        conn(:get, "/sse")
        |> SSE.call(@opts)

      assert conn.status == 406
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      body = Jason.decode!(conn.resp_body)
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

  describe "POST /message" do
    test "handles ping request" do
      request_body = Jason.encode!(%{
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

      response = Jason.decode!(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{}
    end

    test "handles initialize request" do
      request_body = Jason.encode!(%{
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
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["protocolVersion"] == "2025-06-18"
      assert response["result"]["serverInfo"]["name"] == "conduit-mcp"
    end

    test "handles tools/list request" do
      request_body = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list"
      })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["tools"]
      assert is_list(response["result"]["tools"])
    end

    test "handles tools/call request" do
      request_body = Jason.encode!(%{
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
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Hello"}]
    end

    test "handles notifications with 204 status" do
      request_body = Jason.encode!(%{
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
      request_body = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 100,
        "method" => "unknown/method"
      })

      conn =
        conn(:post, "/message", request_body)
        |> put_req_header("content-type", "application/json")
        |> SSE.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
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

      body = Jason.decode!(conn.resp_body)
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
end

defmodule ConduitMcp.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Transport.StreamableHTTP
  alias ConduitMcp.TestServer

  @opts StreamableHTTP.init(server_module: TestServer)

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
  end

  describe "CORS headers" do
    test "adds default CORS headers" do
      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
      assert get_resp_header(conn, "access-control-allow-headers") == ["content-type, authorization"]
    end

    test "respects custom CORS origin" do
      opts = StreamableHTTP.init(
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
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "GET /" do
    test "returns server info" do
      conn =
        conn(:get, "/")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      body = Jason.decode!(conn.resp_body)
      assert body["transport"] == "streamable-http"
      assert body["version"] == "2025-06-18"
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

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "POST / with valid requests" do
    test "handles ping request" do
      request_body = Jason.encode!(%{
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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

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
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Hello"}]
    end
  end

  describe "POST / with notifications" do
    test "handles notifications with 204 status" do
      request_body = Jason.encode!(%{
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
      request_body = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 100,
        "method" => "unknown/method"
      })

      conn =
        conn(:post, "/", request_body)
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
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
end

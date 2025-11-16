defmodule ConduitMcp.Transport.AuthIntegrationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Transport.StreamableHTTP
  alias ConduitMcp.TestServer

  describe "StreamableHTTP with bearer token authentication" do
    setup do
      opts = StreamableHTTP.init(
        server_module: TestServer,
        auth: [
          strategy: :bearer_token,
          token: "test-secret-token"
        ]
      )
      {:ok, opts: opts}
    end

    test "allows authenticated requests", %{opts: opts} do
      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        }))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer test-secret-token")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200

      {:ok, response} = Jason.decode(result.resp_body)
      assert response["result"]["tools"]
      assert is_list(response["result"]["tools"])
    end

    test "blocks unauthenticated requests", %{opts: opts} do
      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        }))
        |> put_req_header("content-type", "application/json")
        # No authorization header

      result = StreamableHTTP.call(conn, opts)

      assert result.halted
      assert result.status == 401

      {:ok, response} = Jason.decode(result.resp_body)
      assert response["error"] == "Unauthorized"
    end

    test "blocks requests with wrong token", %{opts: opts} do
      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "echo",
            "arguments" => %{"message" => "test"}
          }
        }))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer wrong-token")

      result = StreamableHTTP.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end

    test "OPTIONS requests bypass auth (CORS preflight)", %{opts: opts} do
      conn = conn(:options, "/")

      result = StreamableHTTP.call(conn, opts)

      assert result.status == 200
      refute result.halted
    end
  end

  describe "StreamableHTTP with custom verification function" do
    test "calls custom verification and assigns user" do
      verify_fn = fn token ->
        case token do
          "user-token-123" -> {:ok, %{id: 1, email: "user@example.com", role: :user}}
          "admin-token-456" -> {:ok, %{id: 2, email: "admin@example.com", role: :admin}}
          _ -> {:error, "Invalid token"}
        end
      end

      opts = StreamableHTTP.init(
        server_module: TestServer,
        auth: [
          strategy: :function,
          verify: verify_fn,
          assign_as: :current_user
        ]
      )

      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        }))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer admin-token-456")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
      assert result.assigns[:current_user].role == :admin
      assert result.assigns[:current_user].email == "admin@example.com"
    end
  end

  describe "StreamableHTTP with disabled auth" do
    test "allows all requests when auth is disabled" do
      opts = StreamableHTTP.init(
        server_module: TestServer,
        auth: [enabled: false]
      )

      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        }))
        |> put_req_header("content-type", "application/json")
        # No authorization header

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end
  end

  describe "StreamableHTTP with API key authentication" do
    test "accepts valid API key" do
      opts = StreamableHTTP.init(
        server_module: TestServer,
        auth: [
          strategy: :api_key,
          api_key: "secret-api-key-xyz",
          header: "x-api-key"
        ]
      )

      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        }))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "secret-api-key-xyz")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200

      {:ok, response} = Jason.decode(result.resp_body)
      assert response["result"]["tools"]
    end

    test "rejects invalid API key" do
      opts = StreamableHTTP.init(
        server_module: TestServer,
        auth: [
          strategy: :api_key,
          api_key: "secret-api-key-xyz",
          header: "x-api-key"
        ]
      )

      conn =
        conn(:post, "/", Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        }))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-api-key", "wrong-key")

      result = StreamableHTTP.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end
  end
end

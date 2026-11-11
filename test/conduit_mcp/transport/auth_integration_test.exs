defmodule ConduitMcp.Transport.AuthIntegrationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.TestServer
  alias ConduitMcp.Transport.StreamableHTTP

  describe "StreamableHTTP with bearer token authentication" do
    setup do
      opts =
        StreamableHTTP.init(
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
        |> put_req_header("authorization", "Bearer test-secret-token")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200

      {:ok, response} = JSON.decode(result.resp_body)
      assert response["result"]["tools"]
      assert is_list(response["result"]["tools"])
    end

    test "blocks unauthenticated requests", %{opts: opts} do
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

      # No authorization header

      result = StreamableHTTP.call(conn, opts)

      assert result.halted
      assert result.status == 401

      {:ok, response} = JSON.decode(result.resp_body)
      assert response["error"] == "Unauthorized"
    end

    test "blocks requests with wrong token", %{opts: opts} do
      conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{
              "name" => "echo",
              "arguments" => %{"message" => "test"}
            }
          })
        )
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

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          auth: [
            strategy: :function,
            verify: verify_fn,
            assign_as: :current_user
          ]
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
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          auth: [enabled: false]
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

      # No authorization header

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end
  end

  describe "StreamableHTTP with API key authentication" do
    test "accepts valid API key" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          auth: [
            strategy: :api_key,
            api_key: "secret-api-key-xyz",
            header: "x-api-key"
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
        |> put_req_header("x-api-key", "secret-api-key-xyz")

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200

      {:ok, response} = JSON.decode(result.resp_body)
      assert response["result"]["tools"]
    end

    test "rejects invalid API key" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          auth: [
            strategy: :api_key,
            api_key: "secret-api-key-xyz",
            header: "x-api-key"
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
        |> put_req_header("x-api-key", "wrong-key")

      result = StreamableHTTP.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end
  end

  # The body is parsed after authentication: an unauthenticated request costs
  # no body read, whatever its body is.
  for {transport, path} <- [{StreamableHTTP, "/"}, {ConduitMcp.Transport.SSE, "/message"}] do
    describe "#{inspect(transport)}: the body is parsed after authentication" do
      setup do
        opts =
          unquote(transport).init(
            server_module: TestServer,
            auth: [strategy: :bearer_token, token: "test-secret-token"]
          )

        {:ok, opts: opts}
      end

      test "no credential and an invalid JSON body is 401", %{opts: opts} do
        assert status(unquote(transport), opts, post(unquote(path), "not json")) == 401
      end

      test "no credential and a body over the limit is 401", %{opts: opts} do
        body = JSON.encode!(%{"pad" => String.duplicate("a", 1_000_001)})
        assert status(unquote(transport), opts, post(unquote(path), body)) == 401
      end

      test "authenticated, an invalid JSON body is 400", %{opts: opts} do
        conn = post(unquote(path), "not json") |> authorized()
        assert status(unquote(transport), opts, conn) == 400
      end

      test "authenticated, a valid body is handled", %{opts: opts} do
        body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        conn = post(unquote(path), body) |> authorized()
        assert status(unquote(transport), opts, conn) == 200
      end

      test ":max_body_bytes is enforced after authentication" do
        opts =
          unquote(transport).init(
            server_module: TestServer,
            auth: [strategy: :bearer_token, token: "test-secret-token"],
            max_body_bytes: 10
          )

        eleven = ~s({"a":"123"})
        assert byte_size(eleven) == 11

        assert status(unquote(transport), opts, post(unquote(path), eleven)) == 401

        assert status(unquote(transport), opts, post(unquote(path), eleven) |> authorized()) ==
                 413
      end

      test ":max_body_bytes must be a positive integer" do
        for bad <- [0, -1, "1", 1.5] do
          assert_raise ArgumentError, ~r/:max_body_bytes/, fn ->
            unquote(transport).init(server_module: TestServer, max_body_bytes: bad)
          end
        end
      end
    end
  end

  defp post(path, body) do
    conn(:post, path, body) |> put_req_header("content-type", "application/json")
  end

  defp authorized(conn), do: put_req_header(conn, "authorization", "Bearer test-secret-token")

  # The response status, or the status of the exception a plug raised
  # (`Plug.Parsers` raises; Bandit answers with the exception's status).
  defp status(transport, opts, conn) do
    transport.call(conn, opts).status
  rescue
    exception -> Plug.Exception.status(exception)
  end
end

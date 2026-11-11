defmodule ConduitMcp.Transport.RateLimitIntegrationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.TestServer
  alias ConduitMcp.Transport.StreamableHTTP

  @backend ConduitMcp.TestRateLimiter

  describe "StreamableHTTP with rate limiting" do
    test "allows requests within rate limit" do
      key = "integration-allow-#{System.unique_integer([:positive])}"

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          rate_limit: [
            backend: @backend,
            limit: 10,
            scale: 60_000,
            key_func: fn _conn -> key end
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

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200

      {:ok, response} = JSON.decode(result.resp_body)
      assert response["result"]["tools"]
    end

    test "returns 429 when rate limit exceeded" do
      key = "integration-deny-#{System.unique_integer([:positive])}"

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # First request should be allowed
      conn1 =
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

      result1 = StreamableHTTP.call(conn1, opts)
      refute result1.halted
      assert result1.status == 200

      # Second request should be rate limited
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")

      result2 = StreamableHTTP.call(conn2, opts)

      assert result2.halted
      assert result2.status == 429

      {:ok, body} = JSON.decode(result2.resp_body)
      assert body["error"]["code"] == -32000
      assert body["error"]["message"] == "Rate limit exceeded"
    end
  end

  describe "auth + rate limiting ordering" do
    test "auth rejects before rate limit is consumed" do
      key = "integration-auth-first-#{System.unique_integer([:positive])}"

      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          auth: [
            strategy: :bearer_token,
            token: "secret-token"
          ],
          rate_limit: [
            backend: @backend,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      # Unauthenticated request should get 401 (not 429)
      conn1 =
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

      result1 = StreamableHTTP.call(conn1, opts)

      assert result1.halted
      assert result1.status == 401

      # Authenticated request should still work (rate limit not consumed by failed auth)
      conn2 =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "ping"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer secret-token")

      result2 = StreamableHTTP.call(conn2, opts)

      refute result2.halted
      assert result2.status == 200
    end
  end

  describe "no rate_limit config" do
    test "works normally without rate limiting" do
      opts = StreamableHTTP.init(server_module: TestServer)

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

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end
  end

  describe "disabled rate limiting" do
    test "passes all requests when disabled" do
      opts =
        StreamableHTTP.init(
          server_module: TestServer,
          rate_limit: [enabled: false]
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

      result = StreamableHTTP.call(conn, opts)

      refute result.halted
      assert result.status == 200
    end
  end

  defmodule DenyBackend do
    @moduledoc false
    def hit(_key, _scale, _limit), do: {:deny, 1_000}
  end

  defmodule RecordingBackend do
    @moduledoc false
    # Allows, and tells the calling (test) process about every hit.
    def hit(key, _scale, _limit) do
      send(self(), {:hit, key})
      {:allow, 1}
    end
  end

  @doc false
  def verify(token) do
    send(self(), {:verify, token})
    if token == "right-token", do: {:ok, %{id: "u1"}}, else: {:error, "Invalid token"}
  end

  for {transport, path} <- [{StreamableHTTP, "/"}, {ConduitMcp.Transport.SSE, "/message"}] do
    describe "#{inspect(transport)}: the body is parsed after rate limiting" do
      test "a denied request with an invalid JSON body is 429" do
        opts =
          unquote(transport).init(server_module: TestServer, rate_limit: [backend: DenyBackend])

        assert status(unquote(transport), opts, post(unquote(path), "not json")) == 429
      end

      test ":message_rate_limit still sees the parsed body" do
        opts =
          unquote(transport).init(
            server_module: TestServer,
            rate_limit: [backend: RecordingBackend],
            message_rate_limit: [backend: DenyBackend]
          )

        body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        assert status(unquote(transport), opts, post(unquote(path), body)) == 429
      end
    end

    describe "#{inspect(transport)}: rate_limit before_auth" do
      test "true: a denied request never reaches authentication" do
        opts = before_auth_opts(unquote(transport), DenyBackend, true)

        conn = post(unquote(path), ping()) |> bearer("wrong-token")
        assert status(unquote(transport), opts, conn) == 429
        refute_received {:verify, _}
      end

      test "true: a failed authentication is counted once" do
        opts = before_auth_opts(unquote(transport), RecordingBackend, true)

        conn = post(unquote(path), ping()) |> bearer("wrong-token")
        assert status(unquote(transport), opts, conn) == 401
        assert_received {:verify, "wrong-token"}
        assert_received {:hit, _key}
        refute_received {:hit, _key}
      end

      test "true: an authenticated request is counted once" do
        opts = before_auth_opts(unquote(transport), RecordingBackend, true)

        conn = post(unquote(path), ping()) |> bearer("right-token")
        assert status(unquote(transport), opts, conn) == 200
        assert_received {:hit, _key}
        refute_received {:hit, _key}
      end

      test "default false: a failed authentication is not counted" do
        for opts <- [
              before_auth_opts(unquote(transport), RecordingBackend, false),
              unquote(transport).init(
                server_module: TestServer,
                auth: [strategy: :function, verify: &__MODULE__.verify/1],
                rate_limit: [backend: RecordingBackend]
              )
            ] do
          conn = post(unquote(path), ping()) |> bearer("wrong-token")
          assert status(unquote(transport), opts, conn) == 401
          refute_received {:hit, _key}
        end
      end

      test "with Principal.rate_limit_key/1: before auth every request keys on the client" do
        opts = key_opts(unquote(transport), true)
        conn = post(unquote(path), ping())
        bucket = ConduitMcp.Principal.client_bucket(conn)

        for {token, expected} <- [{"wrong-token", 401}, {"right-token", 200}] do
          assert status(unquote(transport), opts, bearer(conn, token)) == expected
          assert_received {:hit, ^bucket}
        end
      end

      test "with Principal.rate_limit_key/1: after auth a success keys on the user" do
        opts = key_opts(unquote(transport), false)
        conn = post(unquote(path), ping()) |> bearer("right-token")

        assert status(unquote(transport), opts, conn) == 200
        assert_received {:hit, "user:" <> _id}
      end

      test "a non-boolean raises at init" do
        assert_raise ArgumentError, ~r/:before_auth/, fn ->
          before_auth_opts(unquote(transport), RecordingBackend, :yes)
        end
      end
    end
  end

  defp before_auth_opts(transport, backend, before_auth) do
    transport.init(
      server_module: TestServer,
      auth: [strategy: :function, verify: &__MODULE__.verify/1],
      rate_limit: [backend: backend, before_auth: before_auth]
    )
  end

  defp key_opts(transport, before_auth) do
    transport.init(
      server_module: TestServer,
      auth: [strategy: :function, verify: &__MODULE__.verify/1],
      rate_limit: [
        backend: RecordingBackend,
        key_func: &ConduitMcp.Principal.rate_limit_key/1,
        before_auth: before_auth
      ]
    )
  end

  defp ping, do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

  defp post(path, body) do
    conn(:post, path, body) |> put_req_header("content-type", "application/json")
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # The response status, or the status of the exception a plug raised.
  defp status(transport, opts, conn) do
    transport.call(conn, opts).status
  rescue
    exception -> Plug.Exception.status(exception)
  end
end

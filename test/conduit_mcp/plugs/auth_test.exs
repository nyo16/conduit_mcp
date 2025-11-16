defmodule ConduitMcp.Plugs.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.Auth

  describe "disabled authentication" do
    test "allows all requests when disabled" do
      opts = Auth.init(enabled: false)
      conn = conn(:get, "/")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.status == nil
    end

    test "passes through without checking headers when disabled" do
      opts = Auth.init(enabled: false)
      conn = conn(:get, "/")  # No auth header

      result = Auth.call(conn, opts)

      refute result.halted
    end
  end

  describe "bearer token strategy - static token" do
    setup do
      opts = Auth.init(strategy: :bearer_token, token: "secret-token-123")
      {:ok, opts: opts}
    end

    test "accepts valid bearer token", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer secret-token-123")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user] == %{authenticated: true}
    end

    test "rejects invalid bearer token", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer wrong-token")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
      assert get_resp_header(result, "content-type") == ["application/json; charset=utf-8"]

      {:ok, body} = Jason.decode(result.resp_body)
      assert body["error"] == "Unauthorized"
    end

    test "rejects request without authorization header", %{opts: opts} do
      conn = conn(:get, "/")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end

    test "rejects malformed authorization header", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "InvalidFormat")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end
  end

  describe "api key strategy" do
    setup do
      opts = Auth.init(
        strategy: :api_key,
        api_key: "my-api-key-789",
        header: "x-api-key"
      )
      {:ok, opts: opts}
    end

    test "accepts valid API key", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", "my-api-key-789")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user] == %{authenticated: true}
    end

    test "rejects invalid API key", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", "wrong-key")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end

    test "rejects request without API key header", %{opts: opts} do
      conn = conn(:get, "/")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end

    test "supports custom header name" do
      opts = Auth.init(
        strategy: :api_key,
        api_key: "custom-key",
        header: "x-custom-api-key"
      )

      conn =
        conn(:get, "/")
        |> put_req_header("x-custom-api-key", "custom-key")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user] == %{authenticated: true}
    end
  end

  describe "function strategy - anonymous function" do
    test "accepts when verification function returns {:ok, user}" do
      verify_fn = fn token ->
        if token == "valid-token" do
          {:ok, %{id: 123, name: "Test User"}}
        else
          {:error, "Invalid"}
        end
      end

      opts = Auth.init(strategy: :function, verify: verify_fn)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer valid-token")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user] == %{id: 123, name: "Test User"}
    end

    test "rejects when verification function returns {:error, reason}" do
      verify_fn = fn _token ->
        {:error, "Token expired"}
      end

      opts = Auth.init(strategy: :function, verify: verify_fn)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer any-token")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end

    test "supports custom assign key" do
      verify_fn = fn _token -> {:ok, %{role: :admin}} end

      opts = Auth.init(
        strategy: :function,
        verify: verify_fn,
        assign_as: :admin_user
      )

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer token")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:admin_user] == %{role: :admin}
      assert result.assigns[:current_user] == nil
    end
  end

  describe "function strategy - MFA tuple" do
    defmodule TestAuth do
      def verify_token(token) do
        case token do
          "mfa-valid-token" -> {:ok, %{verified_via: :mfa}}
          _ -> {:error, "Invalid MFA token"}
        end
      end

      def verify_with_extra_args(token, prefix) do
        if String.starts_with?(token, prefix) do
          {:ok, %{token: token, prefix: prefix}}
        else
          {:error, "Invalid prefix"}
        end
      end
    end

    test "calls module function with MFA tuple" do
      opts = Auth.init(
        strategy: :function,
        verify: {TestAuth, :verify_token, []}
      )

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer mfa-valid-token")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user] == %{verified_via: :mfa}
    end

    test "supports extra arguments in MFA tuple" do
      opts = Auth.init(
        strategy: :function,
        verify: {TestAuth, :verify_with_extra_args, ["prefix_"]}
      )

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer prefix_123")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user].prefix == "prefix_"
    end

    test "rejects when MFA returns error" do
      opts = Auth.init(
        strategy: :function,
        verify: {TestAuth, :verify_token, []}
      )

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer invalid")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end
  end

  describe "error handling" do
    test "handles invalid strategy gracefully" do
      opts = Auth.init(strategy: :unknown_strategy)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer token")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end

    test "handles verification function that returns unexpected value" do
      verify_fn = fn _token -> :unexpected_return end

      opts = Auth.init(strategy: :function, verify: verify_fn)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer token")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401
    end
  end

  describe "integration scenarios" do
    test "full request flow with valid authentication" do
      verify_fn = fn token ->
        # Simulate database lookup
        case token do
          "db-token-abc" -> {:ok, %{id: 1, email: "user@example.com", role: :user}}
          _ -> {:error, "Not found"}
        end
      end

      opts = Auth.init(strategy: :function, verify: verify_fn)

      conn =
        conn(:post, "/", %{data: "test"})
        |> put_req_header("authorization", "Bearer db-token-abc")
        |> put_req_header("content-type", "application/json")

      result = Auth.call(conn, opts)

      refute result.halted
      assert result.assigns[:current_user].email == "user@example.com"
      assert result.assigns[:current_user].role == :user
    end

    test "authentication failure blocks request" do
      verify_fn = fn _token -> {:error, "Expired"} end

      opts = Auth.init(strategy: :function, verify: verify_fn)

      conn =
        conn(:post, "/important-action", %{data: "sensitive"})
        |> put_req_header("authorization", "Bearer expired-token")

      result = Auth.call(conn, opts)

      assert result.halted
      assert result.status == 401

      {:ok, body} = Jason.decode(result.resp_body)
      assert body["message"] == "Authentication failed"
    end
  end
end

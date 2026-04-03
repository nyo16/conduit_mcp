defmodule ConduitMcp.Plugs.OriginValidationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.OriginValidation

  defp call_with_origins(conn, allowed_origins) do
    conn
    |> Plug.Conn.put_private(:allowed_origins, allowed_origins)
    |> OriginValidation.call(OriginValidation.init([]))
  end

  describe "origin validation" do
    test "passes when no origin restriction configured (nil)" do
      conn =
        conn(:post, "/")
        |> put_req_header("origin", "https://any.example.com")
        |> call_with_origins(nil)

      refute conn.halted
    end

    test "passes when origin restriction is wildcard" do
      conn =
        conn(:post, "/")
        |> put_req_header("origin", "https://any.example.com")
        |> call_with_origins("*")

      refute conn.halted
    end

    test "passes when origin matches allowed list" do
      conn =
        conn(:post, "/")
        |> put_req_header("origin", "https://allowed.example.com")
        |> call_with_origins(["https://allowed.example.com"])

      refute conn.halted
    end

    test "blocks request from disallowed origin with 403" do
      conn =
        conn(:post, "/")
        |> put_req_header("origin", "https://evil.example.com")
        |> call_with_origins(["https://allowed.example.com"])

      assert conn.halted
      assert conn.status == 403

      body = JSON.decode!(conn.resp_body)
      assert body["error"] == "Origin not allowed"
    end

    test "passes when no Origin header (browser-less clients)" do
      conn =
        conn(:post, "/")
        |> call_with_origins(["https://allowed.example.com"])

      refute conn.halted
    end

    test "OPTIONS requests bypass origin validation" do
      conn =
        conn(:options, "/")
        |> put_req_header("origin", "https://evil.example.com")
        |> call_with_origins(["https://allowed.example.com"])

      refute conn.halted
    end

    test "supports multiple allowed origins" do
      origins = ["https://app1.example.com", "https://app2.example.com"]

      conn1 =
        conn(:post, "/")
        |> put_req_header("origin", "https://app1.example.com")
        |> call_with_origins(origins)

      refute conn1.halted

      conn2 =
        conn(:post, "/")
        |> put_req_header("origin", "https://app2.example.com")
        |> call_with_origins(origins)

      refute conn2.halted

      conn3 =
        conn(:post, "/")
        |> put_req_header("origin", "https://app3.example.com")
        |> call_with_origins(origins)

      assert conn3.halted
      assert conn3.status == 403
    end
  end
end

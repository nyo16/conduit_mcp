defmodule ConduitMcp.Plugs.SecurityHeadersTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Plugs.SecurityHeaders

  describe "security headers" do
    test "sets X-Content-Type-Options: nosniff" do
      conn =
        conn(:get, "/")
        |> SecurityHeaders.call(SecurityHeaders.init([]))

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "sets X-Frame-Options: DENY" do
      conn =
        conn(:get, "/")
        |> SecurityHeaders.call(SecurityHeaders.init([]))

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "sets Cache-Control: no-store" do
      conn =
        conn(:get, "/")
        |> SecurityHeaders.call(SecurityHeaders.init([]))

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "sets all headers on a single request" do
      conn =
        conn(:post, "/")
        |> SecurityHeaders.call(SecurityHeaders.init([]))

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end
end

defmodule ConduitMcp.CtxTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Ctx

  doctest ConduitMcp.Ctx

  describe "Inspect" do
    test "never renders the conn, the principal or the session" do
      conn =
        conn(:post, "/", "")
        |> Plug.Conn.put_req_header("authorization", "Bearer sk-live-SECRET")

      ctx = %Ctx{
        era: :legacy,
        conn: conn,
        principal: %{id: "user-SECRET", scopes: [], strategy: :oauth, claims: %{}, user: nil},
        session: %{id: "session-SECRET", data: %{}},
        request_id: 1
      }

      rendered = inspect(ctx)

      refute rendered =~ "SECRET"
      assert rendered =~ "era: :legacy"
      assert rendered =~ "request_id: 1"
    end
  end

  describe "put/2 and from_conn/1" do
    test "round-trips the context with the current conn" do
      conn = conn(:post, "/", "")
      ctx = %Ctx{era: :modern, version: "2026-07-28", conn: conn}

      stored = Ctx.put(conn, ctx)
      later = Plug.Conn.assign(stored, :mcp_request_id, 3)

      assert %Ctx{era: :modern, version: "2026-07-28", conn: ^later} = Ctx.from_conn(later)
    end

    test "does not nest the conn inside the stored copy" do
      conn = conn(:post, "/", "")
      stored = Ctx.put(conn, %Ctx{conn: conn})

      assert %Ctx{conn: nil} = stored.private[:mcp_ctx]
    end

    test "is nil when nothing was stored" do
      assert Ctx.from_conn(conn(:post, "/", "")) == nil
      assert Ctx.from_conn(%{}) == nil
    end
  end

  describe "server_info/1" do
    test "uses the transport-resolved name and version" do
      conn =
        conn(:post, "/", "")
        |> Plug.Conn.put_private(:server_name, "acme")
        |> Plug.Conn.put_private(:server_version, "9.9.9")

      assert Ctx.server_info(conn) == %{"name" => "acme", "version" => "9.9.9"}
    end

    test "defaults to the library identity" do
      assert %{"name" => "conduit-mcp", "version" => version} = Ctx.server_info(%{})
      assert version == to_string(Application.spec(:conduit_mcp, :vsn))
    end
  end

  describe "log?/2" do
    test "orders levels by RFC 5424 severity" do
      ctx = %Ctx{era: :modern, log_level: "notice"}

      assert Ctx.log?(ctx, "notice")
      assert Ctx.log?(ctx, "emergency")
      refute Ctx.log?(ctx, "info")
      refute Ctx.log?(ctx, "debug")
      refute Ctx.log?(ctx, "not-a-level")
    end

    test "legacy requests are never gated per request" do
      assert Ctx.log?(%Ctx{era: :legacy}, "debug")
    end
  end
end

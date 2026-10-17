defmodule ConduitMcp.EraTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Ctx
  alias ConduitMcp.Era
  alias ConduitMcp.Errors
  alias ConduitMcp.Session

  @pv "io.modelcontextprotocol/protocolVersion"
  @caps "io.modelcontextprotocol/clientCapabilities"

  @metas %{
    none: nil,
    version_only: %{@pv => "2026-07-28"},
    caps_only: %{@caps => %{}},
    both: %{@pv => "2026-07-28", @caps => %{"sampling" => %{}}}
  }

  @methods ["server/discover", "initialize", "tools/list"]

  defp request(method, meta) do
    params = if meta, do: %{"_meta" => meta}, else: %{}
    %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params}
  end

  defp http_conn(session_header?) do
    conn = conn(:post, "/", "")

    if session_header?,
      do: Plug.Conn.put_req_header(conn, "mcp-session-id", "sess-unknown"),
      else: conn
  end

  # The expected classification for every {meta, method} pair. The session
  # header never changes it (R12), so it is not an input here.
  @expected %{
    {:both, "server/discover"} => :modern,
    {:both, "initialize"} => :modern,
    {:both, "tools/list"} => :modern,
    {:none, "server/discover"} => :modern,
    {:none, "initialize"} => :legacy,
    {:none, "tools/list"} => :legacy
  }

  defp assert_classified({:error, code, message, nil}, :rejected) do
    assert code == Errors.invalid_params()
    assert message =~ "_meta"
  end

  defp assert_classified({:ok, %Ctx{} = ctx}, era) do
    assert ctx.era == era
    assert ctx.request_id == 7
    # A modern context never carries a session, mixed or not.
    if ctx.era == :modern, do: assert(ctx.session == nil)
  end

  defp assert_classified(other, expected),
    do: flunk("expected #{inspect(expected)}, got #{inspect(other)}")

  describe "classify/2 truth table" do
    for meta_kind <- [:none, :version_only, :caps_only, :both],
        method <- @methods,
        session? <- [false, true] do
      @meta_kind meta_kind
      @method method
      @session session?
      # One of protocolVersion/clientCapabilities without the other (D-3).
      @want Map.get(@expected, {meta_kind, method}, :rejected)

      test "_meta #{meta_kind}, #{method}, session header #{if session?, do: "present", else: "absent"}" do
        @method
        |> request(@metas[@meta_kind])
        |> Era.classify(http_conn(@session))
        |> assert_classified(@want)
      end
    end
  end

  describe "classify/2 modern contexts" do
    test "carries the per-request metadata" do
      meta = %{
        @pv => "2026-07-28",
        @caps => %{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}},
        "io.modelcontextprotocol/clientInfo" => %{"name" => "c", "version" => "1"},
        "io.modelcontextprotocol/logLevel" => "warning"
      }

      assert {:ok, ctx} = Era.classify(request("tools/list", meta), conn(:post, "/", ""))

      assert ctx.version == "2026-07-28"
      assert ctx.client_info == %{"name" => "c", "version" => "1"}
      assert ctx.extensions == %{"io.modelcontextprotocol/tasks" => %{}}
      assert ctx.log_level == "warning"
      assert ctx.server_info["name"] == "conduit-mcp"
    end

    test "an era-exempt discover without _meta has no version" do
      assert {:ok, %Ctx{era: :modern, version: nil}} =
               Era.classify(request("server/discover", nil), conn(:post, "/", ""))
    end

    for {label, meta} <- [
          {"non-string protocolVersion", %{@pv => 2026, @caps => %{}}},
          {"non-object clientCapabilities", %{@pv => "2026-07-28", @caps => "all"}},
          {"non-object clientInfo",
           %{@pv => "2026-07-28", @caps => %{}, "io.modelcontextprotocol/clientInfo" => "x"}},
          {"unknown logLevel",
           %{@pv => "2026-07-28", @caps => %{}, "io.modelcontextprotocol/logLevel" => "loud"}}
        ] do
      @meta meta
      test "rejects #{label} with -32602 without echoing the value" do
        assert {:error, -32602, message, nil} =
                 Era.classify(request("tools/list", @meta), conn(:post, "/", ""))

        refute message =~ "2026"
        refute message =~ "loud"
      end
    end

    test "drops the transport's session from the conn of a mixed request" do
      conn =
        conn(:post, "/", "")
        |> Plug.Conn.put_req_header("mcp-session-id", "s1")
        |> Plug.Conn.put_private(:mcp_session_id, "s1")
        |> Plug.Conn.put_private(:mcp_session_data, %{"protocol_version" => "2025-11-25"})

      assert {:ok, ctx} = Era.classify(request("tools/list", @metas.both), conn)
      refute Map.has_key?(ctx.conn.private, :mcp_session_id)
      refute Map.has_key?(ctx.conn.private, :mcp_session_data)
      # So cancellation is scoped to the client, never to the session.
      assert ConduitMcp.Cancellation.scope(ctx.conn) == "ip:127.0.0.1"
    end
  end

  describe "classify/2 mixed requests and session principal binding (R12)" do
    setup do
      id = "era-test-" <> Integer.to_string(System.unique_integer([:positive]))
      on_exit(fn -> Session.delete(id) end)
      %{id: id}
    end

    defp mixed_conn(session_id, principal_id) do
      conn =
        conn(:post, "/", "")
        |> Plug.Conn.put_req_header("mcp-session-id", session_id)
        |> Plug.Conn.put_private(:session_config, [])

      if principal_id, do: ConduitMcp.Principal.put(conn, %{id: principal_id}), else: conn
    end

    test "a live session bound to another principal is rejected", %{id: id} do
      :ok = Session.create(id, %{"protocol_version" => "2025-11-25", "principal" => "alice"})

      assert {:error, code, message, nil} =
               Era.classify(request("tools/list", @metas.both), mixed_conn(id, "mallory"))

      assert code == Errors.invalid_request()
      refute message =~ id
    end

    test "an unauthenticated request cannot ride an authenticated session", %{id: id} do
      :ok = Session.create(id, %{"principal" => "alice"})

      assert {:error, _code, _message, nil} =
               Era.classify(request("tools/list", @metas.both), mixed_conn(id, nil))
    end

    test "the bound principal itself is accepted", %{id: id} do
      :ok = Session.create(id, %{"principal" => "alice"})

      assert {:ok, %Ctx{era: :modern, session: nil}} =
               Era.classify(request("tools/list", @metas.both), mixed_conn(id, "alice"))
    end

    test "an unknown session id is ignored on the modern path", %{id: id} do
      assert {:ok, %Ctx{era: :modern}} =
               Era.classify(request("tools/list", @metas.both), mixed_conn(id, "mallory"))
    end

    test "a session that recorded no principal binds nothing", %{id: id} do
      :ok = Session.create(id, %{"protocol_version" => "2025-11-25"})

      assert {:ok, %Ctx{era: :modern}} =
               Era.classify(request("tools/list", @metas.both), mixed_conn(id, "mallory"))
    end

    test "a legacy request is not checked here; the transport owns its session", %{id: id} do
      :ok = Session.create(id, %{"principal" => "alice"})

      assert {:ok, %Ctx{era: :legacy}} =
               Era.classify(request("tools/list", nil), mixed_conn(id, "mallory"))
    end
  end

  describe "classify/2 legacy contexts" do
    test "carry the session the transport resolved and its negotiated version" do
      conn =
        conn(:post, "/", "")
        |> Plug.Conn.put_private(:mcp_session_id, "s1")
        |> Plug.Conn.put_private(:mcp_session_data, %{"protocol_version" => "2025-06-18"})

      assert {:ok, ctx} = Era.classify(request("tools/list", nil), conn)
      assert ctx.session == %{id: "s1", data: %{"protocol_version" => "2025-06-18"}}
      assert ctx.version == "2025-06-18"
      assert ctx.client_capabilities == %{}
    end
  end

  describe "trace context" do
    @valid_traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    defp trace(meta) do
      {:ok, ctx} = Era.classify(request("tools/list", Map.merge(@metas.both, meta)), %{})
      {ctx.traceparent, ctx.tracestate, ctx.baggage}
    end

    test "keeps valid values" do
      assert {@valid_traceparent, "congo=t61rcWkgMzE", "userId=alice"} =
               trace(%{
                 "traceparent" => @valid_traceparent,
                 "tracestate" => "congo=t61rcWkgMzE",
                 "baggage" => "userId=alice"
               })
    end

    test "drops a malformed or degenerate traceparent" do
      for bad <- [
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7",
            "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01",
            "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            String.duplicate("a", 55),
            42
          ] do
        assert {nil, nil, nil} = trace(%{"traceparent" => bad}), "kept #{inspect(bad)}"
      end
    end

    test "drops tracestate and baggage over 512 bytes or with control characters" do
      assert {nil, nil, nil} =
               trace(%{
                 "tracestate" => String.duplicate("a", 513),
                 "baggage" => "user=a\r\nX-Injected: 1"
               })

      assert {nil, at_cap, nil} = trace(%{"tracestate" => String.duplicate("a", 512)})
      assert byte_size(at_cap) == 512
    end
  end

  describe "check_version/1" do
    test "accepts the modern version, a versionless discover and any legacy context" do
      assert :ok = Era.check_version(%Ctx{era: :modern, version: "2026-07-28"})
      assert :ok = Era.check_version(%Ctx{era: :modern, version: nil})
      assert :ok = Era.check_version(%Ctx{era: :legacy, version: "2025-06-18"})
    end

    test "rejects a version the modern path does not implement with -32022" do
      for version <- ["2099-01-01", "2025-11-25"] do
        assert {:error, -32022, _message, data} =
                 Era.check_version(%Ctx{era: :modern, version: version})

        assert data == %{
                 "supported" => ["2026-07-28", "2025-11-25", "2025-06-18"],
                 "requested" => version
               }
      end
    end
  end
end

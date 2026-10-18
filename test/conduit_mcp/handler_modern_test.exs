defmodule ConduitMcp.HandlerModernTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Ctx
  alias ConduitMcp.Handler
  alias ConduitMcp.TelemetryTestHelper

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{},
    "io.modelcontextprotocol/clientInfo" => %{"name" => "probe", "version" => "0.1"}
  }

  # Reports what a callback observes about its request. The test pid travels
  # in conn.assigns, so concurrent tests never see each other's messages.
  defmodule ProbeServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn), do: {:ok, %{"tools" => []}}

    @impl true
    def handle_call_tool(conn, "probe", _params) do
      send(conn.assigns.test_pid, {
        :probe,
        Ctx.from_conn(conn),
        ConduitMcp.Cancellation.scope(conn),
        conn.assigns[:mcp_request_id]
      })

      {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}}
    end

    def handle_call_tool(_conn, "with_meta", _params) do
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => "ok"}],
         "_meta" => %{"ui" => %{"resourceUri" => "ui://app.html"}, "progressToken" => "tool's"}
       }}
    end
  end

  defp modern(method, params \\ %{}, id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", @meta)
    }
  end

  defp probe_conn do
    conn(:post, "/", "")
    |> Plug.Conn.assign(:test_pid, self())
  end

  describe "dispatch/3 on the modern path" do
    test "callbacks receive a conn carrying the modern context" do
      assert {:reply, %{"result" => %{"resultType" => "complete"}}} =
               Handler.dispatch(
                 modern("tools/call", %{"name" => "probe"}, 41),
                 ProbeServer,
                 probe_conn()
               )

      assert_receive {:probe, %Ctx{} = ctx, _scope, 41}
      assert ctx.era == :modern
      assert ctx.version == "2026-07-28"
      assert ctx.client_info == %{"name" => "probe", "version" => "0.1"}
    end

    test "a mixed request is scoped by principal, never by the session it presents" do
      conn =
        probe_conn()
        |> Plug.Conn.put_req_header("mcp-session-id", "legacy-session")
        |> Plug.Conn.put_private(:mcp_session_id, "legacy-session")
        |> ConduitMcp.Principal.put(%{id: "alice"})

      assert {:reply, %{"result" => _}} =
               Handler.dispatch(modern("tools/call", %{"name" => "probe"}), ProbeServer, conn)

      assert_receive {:probe, %Ctx{session: nil}, "principal:alice", 1}
    end

    test "without a principal the scope falls back to the client IP" do
      conn = Plug.Conn.put_private(probe_conn(), :mcp_session_id, "legacy-session")

      Handler.dispatch(modern("tools/call", %{"name" => "probe"}), ProbeServer, conn)

      assert_receive {:probe, _ctx, "ip:127.0.0.1", 1}
    end

    test "a legacy request through the same conn keeps its session scope" do
      conn = Plug.Conn.put_private(probe_conn(), :mcp_session_id, "legacy-session")

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "probe"}
      }

      Handler.dispatch(request, ProbeServer, conn)

      assert_receive {:probe, %Ctx{era: :legacy, session: %{id: "legacy-session"}},
                      "session:legacy-session", 1}
    end

    test "an unsupported _meta version is -32022, checked before routing" do
      request =
        put_in(
          modern("no/such/method")["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
          "2099-01-01"
        )

      assert {:reply, %{"error" => %{"code" => -32022, "data" => data}}} =
               Handler.dispatch(request, ProbeServer, %Plug.Conn{})

      assert data["requested"] == "2099-01-01"
      assert "2026-07-28" in data["supported"]
    end

    test "a modern notification is dropped" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 1, "_meta" => @meta}
      }

      assert Handler.dispatch(notification, ProbeServer, %Plug.Conn{}) == :noreply
      assert Handler.handle_request(notification, ProbeServer) == :ok
    end

    test "a malformed modern message is -32600" do
      request = %{
        "jsonrpc" => "1.0",
        "id" => 3,
        "method" => "tools/list",
        "params" => %{"_meta" => @meta}
      }

      assert {:reply, %{"id" => 3, "error" => %{"code" => -32600}}} =
               Handler.dispatch(request, ProbeServer, %Plug.Conn{})
    end

    test "a classification failure is answered, not raised" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "tools/list",
        "params" => %{"_meta" => Map.delete(@meta, "io.modelcontextprotocol/clientCapabilities")}
      }

      assert {:reply, %{"id" => 9, "error" => %{"code" => -32602}}} =
               Handler.dispatch(request, ProbeServer, %Plug.Conn{})
    end

    test "a Ctx argument is used as-is instead of reclassifying" do
      {:ok, ctx} =
        ConduitMcp.Era.classify(modern("tools/call", %{"name" => "probe"}), probe_conn())

      # The body no longer carries _meta, but the transport already classified it.
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{"name" => "probe"}
      }

      assert {:reply, %{"result" => %{"resultType" => "complete"}}} =
               Handler.dispatch(request, ProbeServer, ctx)

      assert_receive {:probe, %Ctx{era: :modern}, _scope, 5}
    end
  end

  describe "handle_request/3" do
    test "serves a modern request in the modern shape" do
      response = Handler.handle_request(modern("tools/list"), ProbeServer)

      assert response["result"]["resultType"] == "complete"
      assert response["result"]["ttlMs"] == 60_000

      assert response["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] ==
               "conduit-mcp"
    end

    test "a legacy initialize cannot negotiate the modern version" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2026-07-28", "capabilities" => %{}}
      }

      assert %{"error" => %{"code" => -32600, "message" => message}} =
               Handler.handle_request(request, ProbeServer)

      assert message =~ "Supported versions: 2025-11-25, 2025-06-18"
    end
  end

  describe "tools/call result _meta" do
    test "modern: the tool's _meta is kept and the request's _meta is not echoed" do
      meta =
        Map.merge(@meta, %{
          "progressToken" => "req",
          "io.modelcontextprotocol/logLevel" => "debug",
          "user/key" => 1
        })

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "with_meta", "arguments" => %{}, "_meta" => meta}
      }

      response = Handler.handle_request(request, ProbeServer)

      assert %{"io.modelcontextprotocol/serverInfo" => %{"name" => "conduit-mcp"}} =
               result_meta = response["result"]["_meta"]

      assert Map.delete(result_meta, "io.modelcontextprotocol/serverInfo") == %{
               "ui" => %{"resourceUri" => "ui://app.html"},
               "progressToken" => "tool's"
             }
    end

    test "modern: a tool without _meta gets only serverInfo" do
      request =
        modern("tools/call", %{"name" => "probe"})
        |> put_in(["params", "_meta", "progressToken"], "req")
        |> put_in(["params", "_meta", "user/key"], 1)

      response = Handler.handle_request(request, ProbeServer, probe_conn())

      assert Map.keys(response["result"]["_meta"]) == ["io.modelcontextprotocol/serverInfo"]
    end

    test "legacy: the request's _meta is echoed, the tool's own keys win" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "with_meta",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "req", "user/key" => 1}
        }
      }

      response = Handler.handle_request(request, ProbeServer)

      assert response["result"]["_meta"] == %{
               "ui" => %{"resourceUri" => "ui://app.html"},
               "progressToken" => "tool's",
               "user/key" => 1
             }
    end
  end

  describe "request.stop telemetry" do
    @traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    defmodule TelemetryServer do
      use ConduitMcp.Server, dsl: false
    end

    setup do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :request, :stop]])
      on_exit(fn -> TelemetryTestHelper.detach(ref) end)
      %{ref: ref}
    end

    test "carries the era, version and validated trace context, never the Ctx", %{ref: ref} do
      request =
        modern("tools/list")
        |> put_in(["params", "_meta", "traceparent"], @traceparent)
        |> put_in(["params", "_meta", "baggage"], "bad\nvalue")

      Handler.handle_request(request, TelemetryServer)

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, _m,
                      %{server_module: TelemetryServer} = metadata}

      assert metadata.method == "tools/list"
      assert metadata.status == :ok
      assert metadata.era == :modern
      assert metadata.protocol_version == "2026-07-28"
      assert metadata.traceparent == @traceparent
      assert metadata.baggage == nil
      refute Enum.any?(Map.values(metadata), &is_struct(&1, Ctx))
    end

    test "tags legacy requests", %{ref: ref} do
      Handler.handle_request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
        TelemetryServer
      )

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, _m,
                      %{server_module: TelemetryServer, era: :legacy, protocol_version: nil}}
    end

    test "a rejected classification is still counted, as a modern error", %{ref: ref} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}}
      }

      Handler.handle_request(request, TelemetryServer)

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, _m,
                      %{server_module: TelemetryServer, era: :modern, status: :error}}
    end
  end
end

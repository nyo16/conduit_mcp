defmodule ConduitMcp.StreamSpecTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Ctx
  alias ConduitMcp.Handler
  alias ConduitMcp.StreamSpec

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  defmodule NotifyServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn), do: {:ok, %{"tools" => []}}

    @impl true
    def handle_call_tool(conn, "notify", _params) do
      ConduitMcp.Progress.report(conn, 1, total: 1)
      ConduitMcp.Log.log(conn, "error", "oops")
      send(conn.assigns.test_pid, {:ran, self(), conn.assigns[:mcp_request_id]})
      {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}}
    end
  end

  defp call(meta, id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "notify", "arguments" => %{}, "_meta" => Map.merge(@meta, meta)}
    }
  end

  defp test_conn, do: conn(:post, "/", "") |> Plug.Conn.assign(:test_pid, self())

  # A conn carrying `ctx` and a sink pointing at this process.
  defp sink_conn(ctx, token) do
    ref = make_ref()
    conn = test_conn() |> Ctx.put(ctx) |> StreamSpec.put_sink(self(), ref, token)
    {conn, ref}
  end

  defp frame_message(frame) do
    "event: message\ndata: " <> rest = IO.iodata_to_binary(frame)
    rest |> String.trim_trailing("\n\n") |> JSON.decode!()
  end

  describe "Handler.dispatch/3" do
    test "a modern tools/call with a progressToken is a stream" do
      assert {:stream, %StreamSpec{kind: :response, request_id: 3, progress_token: "t"}} =
               Handler.dispatch(call(%{"progressToken" => "t"}, 3), NotifyServer, test_conn())
    end

    test "a modern tools/call with a logLevel is a stream" do
      assert {:stream, %StreamSpec{progress_token: nil}} =
               Handler.dispatch(
                 call(%{"io.modelcontextprotocol/logLevel" => "debug"}),
                 NotifyServer,
                 test_conn()
               )
    end

    test "a modern tools/call asking for neither is a reply" do
      assert {:reply, %{"result" => _}} = Handler.dispatch(call(%{}), NotifyServer, test_conn())
    end

    test "an unsupported version is a reply, not a stream" do
      meta = %{"io.modelcontextprotocol/protocolVersion" => "2099-01-01", "progressToken" => 1}

      assert {:reply, %{"error" => %{"code" => -32_022}}} =
               Handler.dispatch(call(meta), NotifyServer, test_conn())
    end
  end

  describe "run/1 and Handler.handle_request/3" do
    test "run the work in the caller, in flight, dropping its notifications" do
      response =
        Handler.handle_request(
          call(%{"progressToken" => "t", "io.modelcontextprotocol/logLevel" => "debug"}, 9),
          NotifyServer,
          test_conn()
        )

      assert %{"id" => 9, "result" => %{"resultType" => "complete"}} = response
      # The modern era does not echo the request's _meta into the result.
      refute Map.has_key?(response["result"]["_meta"], "progressToken")
      refute Map.has_key?(response["result"]["_meta"], "io.modelcontextprotocol/logLevel")

      me = self()
      assert_receive {:ran, ^me, 9}
      refute_received {StreamSpec, _ref, _frame}
    end
  end

  describe "ConduitMcp.Progress.report/3" do
    test "sends a notifications/progress frame carrying the request's token" do
      {conn, ref} = sink_conn(%Ctx{era: :modern}, "tok")

      assert :ok = ConduitMcp.Progress.report(conn, 5, total: 10, message: "m")
      assert_receive {StreamSpec, ^ref, {:frame, frame}}

      assert frame_message(frame) == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "progressToken" => "tok",
                 "progress" => 5,
                 "total" => 10,
                 "message" => "m"
               }
             }
    end

    test "is a no-op without a progress token or without a stream" do
      {conn, _ref} = sink_conn(%Ctx{era: :modern, log_level: "debug"}, nil)
      assert :ok = ConduitMcp.Progress.report(conn, 1)
      assert :ok = ConduitMcp.Progress.report(test_conn(), 1)
      refute_received {StreamSpec, _ref, _frame}
    end

    test "rejects a non-numeric progress" do
      assert_raise ArgumentError, ~r/progress must be a number/, fn ->
        ConduitMcp.Progress.report(test_conn(), "50%")
      end
    end
  end

  describe "ConduitMcp.Log.log/4" do
    test "sends a notifications/message at or above the request's level" do
      {conn, ref} = sink_conn(%Ctx{era: :modern, log_level: "warning"}, nil)

      assert :ok = ConduitMcp.Log.log(conn, :info, "below")
      assert :ok = ConduitMcp.Log.log(conn, "error", %{"k" => 1}, logger: "db")

      assert_receive {StreamSpec, ^ref, {:frame, frame}}
      refute_received {StreamSpec, ^ref, _frame}

      assert frame_message(frame)["params"] == %{
               "level" => "error",
               "data" => %{"k" => 1},
               "logger" => "db"
             }
    end

    test "sends nothing for a request without a logLevel, even with a stream" do
      {conn, _ref} = sink_conn(%Ctx{era: :modern}, "tok")

      assert :ok = ConduitMcp.Log.log(conn, :emergency, "nope")
      refute_received {StreamSpec, _ref, _frame}
    end

    test "is a no-op on a legacy request" do
      conn = Ctx.put(test_conn(), %Ctx{era: :legacy})
      assert :ok = ConduitMcp.Log.log(conn, :info, "legacy")
      refute_received {StreamSpec, _ref, _frame}
    end

    test "rejects a level that is not an MCP logging level" do
      assert_raise ArgumentError, ~r/not an MCP logging level/, fn ->
        ConduitMcp.Log.log(test_conn(), :verbose, "x")
      end
    end

    test "raises in the caller for data that is not JSON-encodable" do
      {conn, _ref} = sink_conn(%Ctx{era: :modern, log_level: "debug"}, nil)

      assert_raise Protocol.UndefinedError, fn ->
        ConduitMcp.Log.log(conn, :info, %{"pid" => self()})
      end
    end
  end
end

defmodule ConduitMcp.Client.LoggerMetadataTest do
  # Logger metadata (`mcp_client`, `mcp_server`, `mcp_transport`,
  # `mcp_era`) is set in the processes the client spawns - the connection,
  # hook and approver tasks, handler tasks, the notifier - and never in the
  # calling process (CS §4.5). The stdio port owner and the HTTP listener
  # are checked where those transports run (`SecretScanTest`).
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Transport.InProcess
  alias ConduitMcp.Test.Client.FakeTransport

  defmodule Server do
    use ConduitMcp.Server

    tool "echo", "Echoes the message" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => message} -> text(message) end)
    end
  end

  defmodule Recorder do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_sampling(_params, ctx) do
      send(test_pid(ctx), {:metadata, :handler, Logger.metadata()})

      {:ok,
       %{"role" => "assistant", "content" => %{"type" => "text", "text" => "x"}, "model" => "m"}}
    end

    @impl true
    def handle_notification(_method, _params, ctx) do
      send(test_pid(ctx), {:metadata, :notifier, Logger.metadata()})
      :ok
    end

    # The notifier's ctx has no assigns: the test pid rides in the name.
    defp test_pid(%{client: {_module, _ref, pid}}), do: pid
  end

  defp client_metadata(metadata),
    do: Map.take(Map.new(metadata), [:mcp_client, :mcp_server, :mcp_transport, :mcp_era])

  # A live process's Logger metadata, read from outside it.
  defp metadata_of(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)

    case List.keyfind(dictionary, :"$logger_metadata$", 0) do
      {_key, metadata} -> Map.new(metadata)
      nil -> %{}
    end
  end

  test "the connection, hook and approver tasks carry the client's metadata; the caller's is untouched" do
    name = {__MODULE__, make_ref()}
    test = self()

    probe = fn label ->
      fn _call, _ctx -> send(test, {:metadata, label, Logger.metadata()}) end
    end

    pre_hook = fn call, ctx -> probe.(:hook).(call, ctx) && :cont end
    on_ask = fn call, ctx -> probe.(:approver).(call, ctx) && {:allow, :once} end

    start_supervised!(
      {Client,
       name: name,
       server_id: "meta",
       protocol: :modern,
       transport: {InProcess, server: Server},
       policy: [ask: ["*"]],
       on_ask: on_ask,
       hooks: [pre_tool_call: [{:all, pre_hook, id: :probe}]]}
    )

    assert :ok = Client.await_ready(name)

    Logger.metadata(request_id: "the caller's own")
    before = Logger.metadata()

    assert {:ok, %Client.ToolResult{is_error: false}} =
             Client.call_tool(name, "echo", %{"message" => "hi"})

    assert Logger.metadata() == before

    expected = %{
      mcp_client: ConduitMcp.Reflect.text(name, 64),
      mcp_server: "meta",
      mcp_transport: :in_process,
      mcp_era: :modern
    }

    assert_received {:metadata, :hook, hook}
    assert client_metadata(hook) == expected
    refute Keyword.has_key?(hook, :request_id)

    assert_received {:metadata, :approver, approver}
    assert client_metadata(approver) == expected

    {:ok, conn, _view} = Registry.lookup({:client, name})
    assert client_metadata(metadata_of(conn)) == expected
  end

  test "legacy handler tasks and the notifier carry it too, with the era once negotiated" do
    name = {__MODULE__, make_ref(), self()}
    conn = start_client(name, protocol: :legacy, handler: Recorder, server_id: "meta")
    ready_legacy(name, conn)

    expected = %{
      mcp_client: ConduitMcp.Reflect.text(name, 64),
      mcp_server: "meta",
      mcp_transport: :stdio,
      mcp_era: :legacy
    }

    assert client_metadata(metadata_of(conn)) == expected

    task = Task.async(fn -> Client.call_tool(name, "slow", %{}) end)
    {id, _message, _opts} = expect_request(conn, "tools/call")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "sampling/createMessage",
      "params" => %{"messages" => [], "maxTokens" => 10}
    }

    FakeTransport.push(conn, {:server_request, 1, request, id})
    assert_receive {:metadata, :handler, handler}
    assert client_metadata(handler) == expected

    FakeTransport.push(conn, {:notification, "notifications/message", %{"level" => "info"}})
    assert_receive {:metadata, :notifier, notifier}

    assert Map.take(client_metadata(notifier), [:mcp_client, :mcp_server, :mcp_transport]) ==
             Map.delete(expected, :mcp_era)

    reply(conn, id, %{"content" => []})
    assert {:ok, _result} = Task.await(task)
    assert Logger.metadata() == []
  end
end

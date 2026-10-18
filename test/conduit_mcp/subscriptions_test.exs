defmodule ConduitMcp.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Notifications
  alias ConduitMcp.Protocol.Modern
  alias ConduitMcp.StreamSpec
  alias ConduitMcp.Subscriptions
  alias ConduitMcp.Subscriptions.Filter

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  defmodule FullServer do
    use ConduitMcp.Server

    tool "echo", "Echo" do
      handle(fn _conn, _params -> text("ok") end)
    end

    resource "open://{id}" do
      read(fn _conn, _params, _opts -> text("open") end)
    end

    resource "vault://{id}" do
      scope("vault:read")
      read(fn _conn, _params, _opts -> text("secret") end)
    end
  end

  defmodule HookedServer do
    use ConduitMcp.Server

    resource "open://{id}" do
      read(fn _conn, _params, _opts -> text("open") end)
    end

    def handle_subscribe_resource(conn, "open://" <> id = uri) do
      if id == conn.assigns[:user], do: {:ok, %{"subscribed" => uri}}, else: {:error, %{}}
    end
  end

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, description: "Echo"

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  defmodule ToolsOnly do
    use ConduitMcp.Endpoint, name: "ToolsOnly", version: "1.0.0"

    component(EchoTool)
  end

  defp parse(notifications, server \\ FullServer, conn \\ %Plug.Conn{}),
    do: Filter.parse(%{"notifications" => notifications}, server, conn)

  defp listen(id, params, era \\ :modern) do
    params = if era == :modern, do: Map.put(params, "_meta", @meta), else: params
    %{"jsonrpc" => "2.0", "id" => id, "method" => "subscriptions/listen", "params" => params}
  end

  describe "Filter.parse/3" do
    test "honours supported fields set to true, and nothing else" do
      assert {:ok, filter} =
               parse(%{
                 "toolsListChanged" => true,
                 "promptsListChanged" => false,
                 "resourcesListChanged" => true,
                 "tasks" => %{},
                 "somethingNew" => true
               })

      assert filter.ack == %{"toolsListChanged" => true, "resourcesListChanged" => true}
      assert filter.topics == [:tools, :resources]
      assert filter.kinds == [:tools_list_changed, :resources_list_changed]
    end

    test "omits a field whose capability the server does not advertise" do
      assert {:ok, filter} =
               parse(
                 %{
                   "toolsListChanged" => true,
                   "promptsListChanged" => true,
                   "resourceSubscriptions" => ["open://1"]
                 },
                 ToolsOnly
               )

      assert filter.ack == %{"toolsListChanged" => true}
    end

    test "authorizes each uri, dropping the unauthorized silently and collapsing duplicates" do
      assert {:ok, filter} =
               parse(%{"resourceSubscriptions" => ["open://1", "vault://a", "open://1"]})

      assert filter.ack == %{"resourceSubscriptions" => ["open://1"]}
      assert filter.topics == [{:resource, "open://1"}]

      scoped = Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["vault:read"])

      assert {:ok, filter} =
               parse(%{"resourceSubscriptions" => ["vault://a"]}, FullServer, scoped)

      assert filter.ack == %{"resourceSubscriptions" => ["vault://a"]}
    end

    test "a server's handle_subscribe_resource/2 must accept each uri; refusals drop silently" do
      conn = Plug.Conn.assign(%Plug.Conn{}, :user, "alice")

      assert {:ok, filter} =
               parse(
                 %{"resourceSubscriptions" => ["open://alice", "open://bob"]},
                 HookedServer,
                 conn
               )

      assert filter.ack == %{"resourceSubscriptions" => ["open://alice"]}
      assert filter.topics == [{:resource, "open://alice"}]

      assert {:ok, %Filter{ack: ack, topics: []}} =
               parse(%{"resourceSubscriptions" => ["open://bob"]}, HookedServer, conn)

      assert ack == %{}
    end

    test "an empty honoured uri list omits the field" do
      assert {:ok, %Filter{ack: ack, topics: []}} =
               parse(%{"resourceSubscriptions" => ["vault://a"]})

      assert ack == %{}
    end

    test "rejects malformed fields with -32602" do
      for notifications <- [
            %{"toolsListChanged" => "yes"},
            %{"resourceSubscriptions" => "open://1"},
            %{"resourceSubscriptions" => [1]}
          ] do
        assert {:error, -32602, _message, nil} = parse(notifications)
      end

      assert {:error, -32602, "notifications must be an object", nil} =
               Filter.parse(%{}, FullServer, %Plug.Conn{})

      assert {:error, -32602, _, nil} =
               Filter.parse(%{"notifications" => []}, FullServer, %Plug.Conn{})
    end

    test "caps resourceSubscriptions at #{1_000} URIs" do
      max = Filter.max_resource_subscriptions()
      uris = for n <- 1..max, do: "open://#{n}"

      assert {:ok, %Filter{ack: %{"resourceSubscriptions" => honoured}}} =
               parse(%{"resourceSubscriptions" => uris})

      assert length(honoured) == max

      assert {:error, -32602, message, nil} =
               parse(%{"resourceSubscriptions" => ["open://0" | uris]})

      assert message =~ "more than #{max}"
    end
  end

  describe "Handler" do
    test "a modern listen dispatches to a :listen stream spec" do
      assert {:stream, %StreamSpec{kind: :listen, request_id: "l1", run: nil} = spec} =
               Handler.dispatch(
                 listen("l1", %{"notifications" => %{"toolsListChanged" => true}}),
                 FullServer,
                 %Plug.Conn{}
               )

      assert spec.method == "subscriptions/listen"
      assert spec.subscription.ack == %{"toolsListChanged" => true}
    end

    test "a modern listen with a bad filter is answered as a plain error" do
      assert {:reply, %{"id" => 1, "error" => %{"code" => -32602}}} =
               Handler.dispatch(listen(1, %{}), FullServer, %Plug.Conn{})
    end

    test "manual handle_request/3 answers a listen -32601: it cannot stream" do
      response =
        Handler.handle_request(
          listen(1, %{"notifications" => %{"toolsListChanged" => true}}),
          FullServer,
          %Plug.Conn{}
        )

      assert %{"id" => 1, "error" => %{"code" => -32601, "message" => message}} = response
      assert message =~ "streaming transport"
      assert Modern.http_status(response) == 404
    end

    test "manual handle_request/3 still runs a streamed tools/call synchronously" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{},
          "_meta" => Map.put(@meta, "progressToken", "t")
        }
      }

      assert %{"id" => 2, "result" => %{"content" => [%{"text" => "ok"}]}} =
               Handler.handle_request(request, FullServer, %Plug.Conn{})
    end

    test "subscriptions/listen is not a legacy method" do
      response =
        Handler.handle_request(
          listen(1, %{"notifications" => %{"toolsListChanged" => true}}, :legacy),
          FullServer,
          %Plug.Conn{}
        )

      assert %{"error" => %{"code" => -32601}} = response
      refute Map.has_key?(Handler.methods(:legacy), "subscriptions/listen")
      assert Handler.methods(:modern)["subscriptions/listen"] == :listen
    end
  end

  describe "registry" do
    test "publish/2 delivers to the topic's subscribers, tagged with their ref" do
      ref = make_ref()
      topic = {:resource, "open://registry-#{System.unique_integer([:positive])}"}

      :ok = Subscriptions.subscribe([topic], ref)
      assert Subscriptions.subscribers(topic) == [self()]

      [_, uri] = Tuple.to_list(topic)
      assert :ok = ConduitMcp.notify_resource_updated(uri)
      assert_received {Subscriptions, ^ref, notification}
      assert notification == Notifications.resource_updated_notification(uri)

      :ok = Subscriptions.leave([topic], "test")
      assert Subscriptions.subscribers(topic) == []
      ConduitMcp.notify_resource_updated(uri)
      refute_received {Subscriptions, ^ref, _}
    end

    test "publish/2 skips a stalled stream whose mailbox is at the cap, with telemetry" do
      topic = {:resource, "open://stalled-#{System.unique_integer([:positive])}"}
      parent = self()

      stalled =
        spawn_link(fn ->
          :ok = Subscriptions.subscribe([topic], make_ref())
          send(parent, :subscribed)
          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> send(stalled, :stop) end)
      assert_receive :subscribed, 1_000

      ref =
        ConduitMcp.TelemetryTestHelper.attach_event_handlers(self(), [
          [:conduit_mcp, :subscription, :drop]
        ])

      cap = Subscriptions.max_queue()
      [_, uri] = Tuple.to_list(topic)
      for _ <- 1..(cap + 3), do: ConduitMcp.notify_resource_updated(uri)

      assert Process.info(stalled, :message_queue_len) == {:message_queue_len, cap}

      for _ <- 1..3 do
        assert_received {[:conduit_mcp, :subscription, :drop], ^ref, %{message_queue_len: ^cap},
                         %{topic: :resource}}
      end

      refute_received {[:conduit_mcp, :subscription, :drop], ^ref, _, _}
    end

    test "admit/3 at the cap supersedes the principal's oldest stream, never another's" do
      principal = "principal-#{System.unique_integer([:positive])}"
      other = "someone-else-#{principal}"

      {other_pid, other_ref} = spawn_admit(other, 2)
      [{p1, r1}, {p2, r2}] = for _ <- 1..2, do: spawn_admit(principal, 2)

      {p3, r3} = spawn_admit(principal, 2)
      assert_receive {:superseded, ^p1, ^r1}
      refute_received {:superseded, _, _}

      {p4, r4} = spawn_admit(principal, 2)
      assert_receive {:superseded, ^p2, ^r2}
      refute_received {:superseded, _, _}

      assert live(principal) == [{p3, r3}, {p4, r4}]
      assert live(other) == [{other_pid, other_ref}]
    end

    test "a burst of concurrent admit/3 calls never holds more than the cap live" do
      principal = "burst-#{System.unique_integer([:positive])}"
      parent = self()

      pids =
        for _ <- 1..20 do
          spawn_link(fn ->
            ref = make_ref()
            :ok = Subscriptions.admit(principal, 3, ref)
            send(parent, {:admitted, self(), length(Subscriptions.live_listeners(principal))})
            hold(parent, ref)
          end)
        end

      on_exit(fn -> Enum.each(pids, &send(&1, :stop)) end)

      for pid <- pids do
        assert_receive {:admitted, ^pid, count}
        assert count <= 3
      end

      assert length(live(principal)) == 3

      for _ <- 1..17, do: assert_receive({:superseded, _pid, _ref})
      refute_received {:superseded, _, _}
    end
  end

  defp live(principal),
    do:
      for({_seq, pid, ref} <- Enum.sort(Subscriptions.live_listeners(principal)), do: {pid, ref})

  # Each stream is its own process; the spawned process holds its entry
  # until told to stop, at the end of the test, and reports a supersession.
  defp spawn_admit(principal, max) do
    parent = self()

    pid =
      spawn_link(fn ->
        ref = make_ref()
        :ok = Subscriptions.admit(principal, max, ref)
        send(parent, {:admitted, self(), ref})
        hold(parent, ref)
      end)

    on_exit(fn -> send(pid, :stop) end)

    assert_receive {:admitted, ^pid, ref}
    {pid, ref}
  end

  defp hold(parent, ref) do
    receive do
      {Subscriptions, ^ref, :superseded} ->
        send(parent, {:superseded, self(), ref})
        hold(parent, ref)

      :stop ->
        :ok
    end
  end
end

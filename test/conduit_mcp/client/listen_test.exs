defmodule ConduitMcp.Client.ListenTest do
  # `subscriptions/listen` and resource subscriptions in the connection
  # (`ConduitMcp.Client.Connection.Listen`), with the test playing the
  # server through `ConduitMcp.Test.Client.FakeTransport`.
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Test.Client.FakeTransport

  @sid "io.modelcontextprotocol/subscriptionId"
  @caps %{
    "tools" => %{"listChanged" => true},
    "prompts" => %{"listChanged" => true},
    "resources" => %{"listChanged" => true, "subscribe" => true}
  }

  defp start_modern(caps \\ @caps) do
    name = {__MODULE__, make_ref()}
    conn = start_client(name)
    ready_modern(name, conn, caps)
    {name, conn}
  end

  defp ack(conn, id, notifications) do
    FakeTransport.push(
      conn,
      {:notification, "notifications/subscriptions/acknowledged",
       %{"notifications" => notifications, "_meta" => %{@sid => id}}}
    )
  end

  defp expect_listen(conn) do
    {id, message, wire_opts} = expect_request(conn, "subscriptions/listen")
    assert wire_opts[:listen] == true
    {id, message["params"]["notifications"]}
  end

  describe "the modern filter" do
    test "no listen until the client has a consumer; a subscriber asks for every advertised kind" do
      {name, conn} = start_modern()

      refute_receive {:fake_transport, ^conn,
                      {:request, %{"method" => "subscriptions/listen"}, _}}

      :ok = Client.subscribe_notifications(name)
      {_id, filter} = expect_listen(conn)

      assert filter == %{
               "toolsListChanged" => true,
               "promptsListChanged" => true,
               "resourcesListChanged" => true
             }
    end

    test "kinds the server does not advertise listChanged for are left out" do
      {name, conn} = start_modern(%{"tools" => %{"listChanged" => true}, "prompts" => %{}})
      :ok = Client.subscribe_notifications(name)
      assert {_id, %{"toolsListChanged" => true} = filter} = expect_listen(conn)
      assert map_size(filter) == 1
    end

    test "a cached list is a consumer of its kind" do
      {name, conn} = start_modern()
      task = Task.async(fn -> Client.list_all_tools(name) end)
      {id, _message, _opts} = expect_request(conn, "tools/list")
      reply(conn, id, %{"tools" => [], "ttlMs" => 60_000, "cacheScope" => "public"})
      assert {:ok, []} = Task.await(task)

      assert {_id, %{"toolsListChanged" => true} = filter} = expect_listen(conn)
      assert map_size(filter) == 1
    end

    test "no fifth listen opens while four are open (HT-9)" do
      {name, conn} = start_modern()
      assert ConduitMcp.Client.Connection.Listen.max_listens() == 4

      # Make-before-break keeps at most two listens in normal operation;
      # four lingering ones (a server that never ends the replaced streams)
      # are put in place directly.
      lingering =
        Map.new(1_001..1_004, fn id ->
          {id, %{filter: %{"x" => true}, status: :closing, acked: %{}}}
        end)

      :sys.replace_state(conn, fn {state, data} ->
        {state, %{data | listen: %{data.listen | listens: lingering}}}
      end)

      :ok = Client.subscribe_notifications(name)
      _ = state(conn)

      refute_receive {:fake_transport, ^conn,
                      {:request, %{"method" => "subscriptions/listen"}, _}}

      assert map_size(state(conn).listen.listens) == 4
    end
  end

  describe "acknowledgment and routing" do
    test "listen notifications are routed with subscriptionId removed; others' are dropped" do
      {name, conn} = start_modern()
      :ok = Client.subscribe_notifications(name)
      {id, _filter} = expect_listen(conn)
      ack(conn, id, %{"toolsListChanged" => true})

      FakeTransport.push(
        conn,
        {:notification, "notifications/tools/list_changed", %{"_meta" => %{@sid => id}}}
      )

      assert_receive {:mcp_notification, ^name, "notifications/tools/list_changed", params}
      assert params == %{}

      FakeTransport.push(
        conn,
        {:notification, "notifications/prompts/list_changed", %{"_meta" => %{@sid => id + 1_000}}}
      )

      refute_receive {:mcp_notification, ^name, "notifications/prompts/list_changed", _}
      refute_receive {:mcp_notification, ^name, "notifications/subscriptions/acknowledged", _}
    end

    test "subscribe/2 answers once the new listen is acknowledged; the old one closes after (make-before-break)" do
      {name, conn} = start_modern()
      :ok = Client.subscribe_notifications(name)
      {first, _filter} = expect_listen(conn)
      ack(conn, first, %{"toolsListChanged" => true})

      task = Task.async(fn -> Client.subscribe(name, "file:///a") end)
      {second, filter} = expect_listen(conn)
      assert filter["resourceSubscriptions"] == ["file:///a"]
      refute_receive {:fake_transport, ^conn, {:cancel, ^first, _, _}}

      ack(conn, second, %{"resourceSubscriptions" => ["file:///a"]})
      assert :ok = Task.await(task)
      assert_receive {:fake_transport, ^conn, {:cancel, ^first, nil, :replaced}}

      # The old listen's late messages are dropped.
      FakeTransport.push(
        conn,
        {:notification, "notifications/resources/updated",
         %{"uri" => "file:///a", "_meta" => %{@sid => first}}}
      )

      refute_receive {:mcp_notification, ^name, "notifications/resources/updated", _}

      FakeTransport.push(
        conn,
        {:notification, "notifications/resources/updated",
         %{"uri" => "file:///a", "_meta" => %{@sid => second}}}
      )

      assert_receive {:mcp_notification, ^name, "notifications/resources/updated",
                      %{"uri" => "file:///a"}}
    end

    test "a URI the acknowledgment leaves out fails subscribe/2 and is forgotten" do
      {name, conn} = start_modern()
      task = Task.async(fn -> Client.subscribe(name, "file:///secret") end)
      {id, _filter} = expect_listen(conn)
      ack(conn, id, %{})

      assert {:error, %Error{kind: :protocol, reason: :subscription_not_acknowledged}} =
               Task.await(task)

      assert MapSet.size(state(conn).listen.subs) == 0
    end

    test "unsubscribe/2 of the last URI closes the listen" do
      {name, conn} = start_modern(%{"resources" => %{"subscribe" => true}})
      task = Task.async(fn -> Client.subscribe(name, "file:///a") end)
      {id, _filter} = expect_listen(conn)
      ack(conn, id, %{"resourceSubscriptions" => ["file:///a"]})
      assert :ok = Task.await(task)

      assert :ok = Client.unsubscribe(name, "file:///a")
      assert_receive {:fake_transport, ^conn, {:cancel, ^id, nil, :replaced}}
      assert state(conn).listen.listens == %{}
    end
  end

  describe "endings" do
    test "a dropped listen marks the caches stale and is reopened after the backoff" do
      {name, conn} = start_modern()
      task = Task.async(fn -> Client.list_all_tools(name) end)
      {list, _message, _opts} = expect_request(conn, "tools/list")
      reply(conn, list, %{"tools" => [], "ttlMs" => 60_000, "cacheScope" => "public"})
      assert {:ok, []} = Task.await(task)
      {id, _filter} = expect_listen(conn)
      ack(conn, id, %{"toolsListChanged" => true})

      FakeTransport.push(conn, {:exchange_done, id, {:error, :stream_closed}})

      {again, _filter} = expect_listen(conn)
      assert again > id
      {:ok, entry} = Cache.list(state(conn).cache, :tools)
      assert entry.stale?
    end

    test "a graceful end is reopened" do
      {name, conn} = start_modern()
      :ok = Client.subscribe_notifications(name)
      {id, _filter} = expect_listen(conn)
      ack(conn, id, %{"toolsListChanged" => true})

      reply(conn, id, %{"_meta" => %{@sid => id}})
      {_again, _filter} = expect_listen(conn)
    end

    test "a listen answered with a JSON-RPC error is not retried" do
      {name, conn} = start_modern()
      :ok = Client.subscribe_notifications(name)
      {id, _filter} = expect_listen(conn)
      reply_error(conn, id, -32_601, "Method not found")

      refute_receive {:fake_transport, ^conn,
                      {:request, %{"method" => "subscriptions/listen"}, _}}

      assert state(conn).listen.off?

      assert {:error, %Error{reason: :listen_not_supported}} = Client.subscribe(name, "file:///a")
    end

    test "a reconnect re-sends the listen with the full filter" do
      {name, conn} = start_modern()
      task = Task.async(fn -> Client.subscribe(name, "file:///a") end)
      {id, _filter} = expect_listen(conn)
      ack(conn, id, %{"resourceSubscriptions" => ["file:///a"]})
      assert :ok = Task.await(task)

      FakeTransport.push(conn, {:closed, :boom})
      assert_receive {:fake_transport, ^conn, :connect}
      FakeTransport.push(conn, {:connected, %{}})
      {discover, _message, _opts} = expect_request(conn, "server/discover")
      reply(conn, discover, discover_result(@caps))

      {_again, filter} = expect_listen(conn)
      assert filter["resourceSubscriptions"] == ["file:///a"]
    end
  end

  describe "legacy" do
    test "subscribe/2 sends resources/subscribe and re-sends it for a new session" do
      name = {__MODULE__, make_ref()}
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn, %{"resources" => %{"subscribe" => true}})

      task = Task.async(fn -> Client.subscribe(name, "file:///a") end)
      {id, message, _opts} = expect_request(conn, "resources/subscribe")
      assert message["params"]["uri"] == "file:///a"
      reply(conn, id, %{})
      assert :ok = Task.await(task)

      FakeTransport.push(conn, {:closed, :boom})
      assert_receive {:fake_transport, ^conn, :connect}
      FakeTransport.push(conn, {:connected, %{}})
      {init, _message, _opts} = expect_request(conn, "initialize")

      reply(conn, init, %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{"resources" => %{"subscribe" => true}},
        "serverInfo" => %{"name" => "old", "version" => "0.1"}
      })

      {_again, again, _opts} = expect_request(conn, "resources/subscribe")
      assert again["params"]["uri"] == "file:///a"

      task = Task.async(fn -> Client.unsubscribe(name, "file:///a") end)
      {id, _message, _opts} = expect_request(conn, "resources/unsubscribe")
      reply(conn, id, %{})
      assert :ok = Task.await(task)
    end

    test "an unanswered resources/subscribe is cancelled at the request timeout" do
      name = {__MODULE__, make_ref()}
      conn = start_client(name, protocol: :legacy, request_timeout: 200)
      ready_legacy(name, conn, %{"resources" => %{"subscribe" => true}})

      task = Task.async(fn -> Client.subscribe(name, "file:///a", timeout: 5_000) end)
      {id, _message, _opts} = expect_request(conn, "resources/subscribe")
      assert_receive {:fake_transport, ^conn, {:cancel, ^id, _handle, :timeout}}, 1_000
      assert {:error, %Error{kind: :timeout}} = Task.await(task)
      assert state(conn).internal == %{}
    end

    test "a resources/subscribe in flight fails when the transport closes" do
      name = {__MODULE__, make_ref()}
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn, %{"resources" => %{"subscribe" => true}})

      task = Task.async(fn -> Client.subscribe(name, "file:///a", timeout: 5_000) end)
      _ = expect_request(conn, "resources/subscribe")
      FakeTransport.push(conn, {:closed, :boom})
      assert {:error, %Error{kind: :transport}} = Task.await(task, 1_000)
    end

    test "a server without resources.subscribe refuses at once" do
      name = {__MODULE__, make_ref()}
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn, %{"resources" => %{}})

      assert {:error, %Error{kind: :protocol, reason: :subscriptions_not_supported}} =
               Client.subscribe(name, "file:///a")
    end
  end

  test "subscribe/2 before the connection is ready waits for it" do
    name = {__MODULE__, make_ref()}
    conn = start_client(name)
    task = Task.async(fn -> Client.subscribe(name, "file:///a") end)
    ready_modern(name, conn, @caps)

    {id, filter} = expect_listen(conn)
    assert filter["resourceSubscriptions"] == ["file:///a"]
    ack(conn, id, %{"resourceSubscriptions" => ["file:///a"]})
    assert :ok = Task.await(task)
  end

  test "a subscribe/2 that timed out before the connection was ready is never applied" do
    name = {__MODULE__, make_ref()}
    conn = start_client(name)

    assert {:error, %Error{kind: :timeout}} =
             Client.subscribe(name, "file:///a", timeout: 200)

    ready_modern(name, conn, @caps)

    refute_receive {:fake_transport, ^conn, {:request, %{"method" => "subscriptions/listen"}, _}}

    assert MapSet.size(state(conn).listen.subs) == 0
  end
end

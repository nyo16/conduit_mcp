defmodule ConduitMcp.Client.ConnectionTest do
  # The connection state machine, driven through the public client API with a
  # fake transport: the test process plays the server.
  use ExUnit.Case, async: true

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Connection.Inbound
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.ServerInfo
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.TelemetryTestHelper
  alias ConduitMcp.Test.Client.FakeHTTPTransport
  alias ConduitMcp.Test.Client.FakeTransport

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @list_changed "notifications/tools/list_changed"

  # Reports each `elicitation_modes/0` call to the process named in the
  # persistent term, and raises once the test flips it to `:raise`.
  defmodule CountingModes do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "decline"}}

    @impl true
    def elicitation_modes do
      case :persistent_term.get(__MODULE__) do
        :raise -> raise "elicitation_modes/0 called after start"
        pid -> send(pid, {:elicitation_modes, self()})
      end

      [:form]
    end
  end

  setup do
    {:ok, name: {__MODULE__, make_ref()}}
  end

  # --- helpers ---------------------------------------------------------------------

  defp start_client(name, opts \\ []) do
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])

    defaults = [
      name: name,
      transport: {FakeTransport, [test_pid: self()] ++ transport_opts},
      backoff: fn _attempt -> 0 end
    ]

    start_supervised!({Client, Keyword.merge(defaults, opts)})
    assert_receive {:fake_transport, conn, :connect}
    conn
  end

  defp discover_result(versions \\ [@modern]) do
    %{
      "resultType" => "complete",
      "supportedVersions" => versions,
      "capabilities" => %{"tools" => %{"listChanged" => true}},
      "instructions" => "Be nice.",
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "fake", "version" => "1.0"}
      }
    }
  end

  defp initialize_result(version \\ @legacy) do
    %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}, "logging" => %{}},
      "serverInfo" => %{"name" => "old", "version" => "0.1"},
      "instructions" => "Legacy."
    }
  end

  defp reply(conn, id, result),
    do:
      FakeTransport.push(
        conn,
        {:response, id, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
      )

  defp reply_error(conn, id, code, data \\ nil) do
    error = %{"code" => code, "message" => "nope", "data" => data}
    FakeTransport.push(conn, {:response, id, %{"jsonrpc" => "2.0", "id" => id, "error" => error}})
  end

  defp expect_request(conn, method) do
    assert_receive {:fake_transport, ^conn,
                    {:request, %{"method" => ^method, "id" => id} = message, wire_opts}}

    {id, message, wire_opts}
  end

  defp ready_modern(name, conn) do
    FakeTransport.push(conn, {:connected, %{}})
    {id, _message, _opts} = expect_request(conn, "server/discover")
    reply(conn, id, discover_result())
    assert :ok = Client.await_ready(name)
  end

  defp ready_legacy(name, conn) do
    FakeTransport.push(conn, {:connected, %{}})
    {id, _message, _opts} = expect_request(conn, "initialize")
    reply(conn, id, initialize_result())
    assert_receive {:fake_transport, ^conn, {:notify, %{"method" => "notifications/initialized"}}}
    assert :ok = Client.await_ready(name)
  end

  defp attach(name, events),
    do: TelemetryTestHelper.attach_event_handlers(self(), events, match: %{client: name})

  defp state(conn) do
    {_state, data} = :sys.get_state(conn)
    data
  end

  # Bounded retry over a synchronous `:sys` read; for facts that depend on a
  # message from a third process (a `:DOWN`, a task's request) reaching the
  # connection. Bounded by time, not attempts: a fixed number of fast `:sys`
  # round trips can all finish before a loaded scheduler runs that third
  # process (500 attempts did, about once in 20 full-suite runs).
  defp eventually(fun, timeout \\ 2_000),
    do: eventually_until(fun, System.monotonic_time(:millisecond) + timeout)

  defp eventually_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
      true -> eventually_until(fun, deadline)
    end
  end

  # Nothing outlives a test: no pending request, no caller monitor, no task.
  defp assert_no_leaks(name, conn) do
    data = state(conn)
    assert data.pending == %{}
    assert data.refs == %{}

    {:ok, task_sup, _value} = Registry.lookup({:task_sup, name})

    for pid <- Task.Supervisor.children(task_sup) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    assert Task.Supervisor.children(task_sup) == []
  end

  # --- discovery ---------------------------------------------------------------------

  describe "era discovery (protocol: :auto)" do
    test "a DiscoverResult makes the connection modern", %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})

      {id, message, wire_opts} = expect_request(conn, "server/discover")
      assert wire_opts[:probe] == true
      meta = message["params"]["_meta"]
      assert meta["io.modelcontextprotocol/protocolVersion"] == @modern
      assert meta["io.modelcontextprotocol/clientCapabilities"] == %{}
      assert %{"name" => "conduit_mcp"} = meta["io.modelcontextprotocol/clientInfo"]

      reply(conn, id, discover_result())

      assert_receive {:fake_transport, ^conn, {:set_session, %{era: :modern, version: @modern}}}
      assert :ok = Client.await_ready(name)
      assert {:ok, :modern} = Client.era(name)

      assert {:ok,
              %{
                era: :modern,
                version: @modern,
                instructions: "Be nice.",
                server_info: %ServerInfo{name: "fake"},
                capabilities: %{"tools" => %{"listChanged" => true}}
              }} = Client.server_info(name)

      refute_received {:fake_transport, ^conn, {:request, %{"method" => "initialize"}, _}}
      assert_no_leaks(name, conn)
    end

    test "an unrecognised error falls back to initialize", %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})
      {id, _message, _opts} = expect_request(conn, "server/discover")
      reply_error(conn, id, -32_601)

      {init_id, init, _opts} = expect_request(conn, "initialize")
      assert init["params"]["protocolVersion"] == @legacy
      assert init["params"]["capabilities"] == %{}
      assert %{"name" => "conduit_mcp"} = init["params"]["clientInfo"]
      refute Map.has_key?(init["params"], "_meta")

      reply(conn, init_id, initialize_result())

      assert_receive {:fake_transport, ^conn,
                      {:notify, %{"method" => "notifications/initialized"}}}

      assert :ok = Client.await_ready(name)

      assert {:ok, %{state: :ready, era: :legacy, version: @legacy}} = Client.status(name)

      assert {:ok, %{instructions: "Legacy.", server_info: %ServerInfo{name: "old"}}} =
               Client.server_info(name)

      assert_no_leaks(name, conn)
    end

    test "silence falls back to initialize after probe_timeout", %{name: name} do
      conn = start_client(name, probe_timeout: 10)
      FakeTransport.push(conn, {:connected, %{}})
      {discover_id, _message, _opts} = expect_request(conn, "server/discover")

      {init_id, _init, _opts} = expect_request(conn, "initialize")
      reply(conn, init_id, initialize_result())
      assert :ok = Client.await_ready(name)

      # The probe's answer, if it ever comes, is no longer awaited.
      reply(conn, discover_id, discover_result())
      assert {:ok, :legacy} = Client.era(name)
      assert_no_leaks(name, conn)
    end

    test "-32022 retries discover with the server's version and never initializes",
         %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})
      {id, _message, _opts} = expect_request(conn, "server/discover")
      reply_error(conn, id, -32_022, %{"supported" => [@modern], "requested" => @modern})

      {retry_id, retry, _opts} = expect_request(conn, "server/discover")
      assert retry_id > id
      assert retry["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == @modern

      reply(conn, retry_id, discover_result())
      assert :ok = Client.await_ready(name)
      assert {:ok, :modern} = Client.era(name)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "initialize"}, _}}
      assert_no_leaks(name, conn)
    end

    test "a second -32022 closes the connection instead of falling back", %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})

      for _attempt <- 1..2 do
        {id, _message, _opts} = expect_request(conn, "server/discover")
        reply_error(conn, id, -32_022, %{"supported" => [@modern]})
      end

      assert {:error, %Error{kind: :closed, reason: :no_common_version}} =
               Client.await_ready(name)

      refute_received {:fake_transport, ^conn, {:request, %{"method" => "initialize"}, _}}
      assert_no_leaks(name, conn)
    end

    test "-32022 with no version in common closes without initialize", %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})
      {id, _message, _opts} = expect_request(conn, "server/discover")
      reply_error(conn, id, -32_022, %{"supported" => ["2099-01-01"]})

      assert {:error, %Error{kind: :closed, reason: :no_common_version}} =
               Client.await_ready(name)

      assert {:ok, %{state: :closed, reason: %Error{reason: :no_common_version}}} =
               Client.status(name)

      refute_received {:fake_transport, ^conn, {:request, %{"method" => "initialize"}, _}}
    end

    test "a server that exits on the probe is retried with initialize", %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})
      _ = expect_request(conn, "server/discover")
      FakeTransport.push(conn, {:closed, {:exit_status, 1}})

      assert_receive {:fake_transport, ^conn, {:close, :closed_during_probe}}
      assert_receive {:fake_transport, ^conn, :connect}
      FakeTransport.push(conn, {:connected, %{}})
      {id, _message, _opts} = expect_request(conn, "initialize")
      reply(conn, id, initialize_result())
      assert :ok = Client.await_ready(name)
      assert_no_leaks(name, conn)
    end
  end

  describe "pinned eras and prior" do
    test "protocol: :legacy starts with initialize", %{name: name} do
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "server/discover"}, _}}
      assert {:ok, :legacy} = Client.era(name)
    end

    test "protocol: :modern closes on legacy evidence instead of falling back", %{name: name} do
      conn = start_client(name, protocol: :modern)
      FakeTransport.push(conn, {:connected, %{}})
      {id, _message, wire_opts} = expect_request(conn, "server/discover")
      assert wire_opts[:probe] == false
      reply_error(conn, id, -32_601)

      assert {:error, %Error{kind: :closed, reason: :not_modern}} = Client.await_ready(name)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "initialize"}, _}}
    end

    test "a pinned legacy version must be the one the server answers", %{name: name} do
      conn = start_client(name, protocol: "2025-06-18")
      FakeTransport.push(conn, {:connected, %{}})
      {id, init, _opts} = expect_request(conn, "initialize")
      assert init["params"]["protocolVersion"] == "2025-06-18"
      reply(conn, id, initialize_result(@legacy))

      assert {:error, %Error{kind: :closed, reason: :no_common_version}} =
               Client.await_ready(name)
    end

    test "prior: :legacy skips the probe once, and probes after a refusal", %{name: name} do
      conn = start_client(name, prior: :legacy)
      FakeTransport.push(conn, {:connected, %{}})
      {id, _message, _opts} = expect_request(conn, "initialize")
      reply_error(conn, id, -32_601)

      assert_receive {:fake_transport, ^conn, :connect}
      ready_modern(name, conn)
      assert {:ok, :modern} = Client.era(name)
    end
  end

  # --- requests ------------------------------------------------------------------------

  describe "requests" do
    test "a request past its deadline is cancelled and its late response dropped",
         %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      ref =
        attach(name, [
          [:conduit_mcp, :client, :request, :cancel],
          [:conduit_mcp, :client, :response, :dropped]
        ])

      assert {:error, %Error{kind: :timeout}} = Client.call_tool(name, "slow", %{}, timeout: 20)

      assert_received {:fake_transport, ^conn,
                       {:request, %{"method" => "tools/call", "id" => id}, _opts}}

      assert_received {:fake_transport, ^conn, {:cancel, ^id, {:fake_handle, ^id}, :timeout}}

      assert_receive {[:conduit_mcp, :client, :request, :cancel], ^ref, %{count: 1},
                      %{reason: :timeout, request_id: ^id, method: "tools/call"}}

      reply(conn, id, %{"content" => []})

      assert_receive {[:conduit_mcp, :client, :response, :dropped], ^ref, %{count: 1},
                      %{request_id: ^id}}

      refute_received {_mref, {:response, _message}}
      assert_no_leaks(name, conn)
    end

    test "a caller that dies has its request cancelled", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      caller = spawn(fn -> Client.call_tool(name, "slow", %{}) end)
      {id, _message, _opts} = expect_request(conn, "tools/call")
      Process.exit(caller, :kill)

      assert_receive {:fake_transport, ^conn, {:cancel, ^id, {:fake_handle, ^id}, :caller_down}}
      assert_no_leaks(name, conn)
    end

    test "a postponed request whose deadline passed is never sent", %{name: name} do
      conn = start_client(name)

      assert {:error, %Error{kind: :timeout}} = Client.list_tools(name, timeout: 10)

      # `await_ready` is postponed behind the expired request, so by the time
      # it returns the replay has been handled.
      ready_modern(name, conn)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "tools/list"}, _}}
      assert_no_leaks(name, conn)
    end

    test "requests made before ready are sent once ready", %{name: name} do
      conn = start_client(name)
      task = Task.async(fn -> Client.list_tools(name) end)
      eventually(fn -> state(conn).queued == 1 end)

      ready_modern(name, conn)
      {id, _message, _opts} = expect_request(conn, "tools/list")

      reply(conn, id, %{
        "tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}],
        "nextCursor" => "page-2"
      })

      assert {:ok, %{tools: [%{name: "echo", server_id: server_id}], next_cursor: "page-2"}} =
               Task.await(task)

      assert server_id == inspect(name)
      assert_no_leaks(name, conn)
    end

    test "max_in_flight refuses the next request with :overloaded", %{name: name} do
      conn = start_client(name, max_in_flight: 1)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "slow", %{}) end)
      {id, _message, _opts} = expect_request(conn, "tools/call")

      assert {:error, %Error{kind: :overloaded, reason: :max_in_flight}} =
               Client.call_tool(name, "other", %{})

      reply(conn, id, %{"content" => [], "isError" => true})
      assert {:ok, %ToolResult{is_error: true}} = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "the 65th request in flight is :overloaded at the default cap, and starts nothing (HT-9)",
         %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)
      assert state(conn).config.max_in_flight == 64

      tasks = for _ <- 1..64, do: Task.async(fn -> Client.call_tool(name, "slow", %{}) end)
      ids = for _ <- 1..64, do: elem(expect_request(conn, "tools/call"), 0)

      {:ok, task_sup, _value} = Registry.lookup({:task_sup, name})
      children = Task.Supervisor.children(task_sup)

      assert {:error, %Error{kind: :overloaded, reason: :max_in_flight}} =
               Client.call_tool(name, "other", %{})

      refute_received {:fake_transport, ^conn, {:request, _message, _opts}}
      assert map_size(state(conn).pending) == 64
      assert Task.Supervisor.children(task_sup) == children

      for id <- ids, do: reply(conn, id, %{"content" => []})
      for task <- tasks, do: assert({:ok, %ToolResult{}} = Task.await(task))
      assert_no_leaks(name, conn)
    end

    test "max_queued refuses requests beyond the queue while connecting", %{name: name} do
      conn = start_client(name, max_queued: 1)
      task = Task.async(fn -> Client.list_tools(name) end)
      eventually(fn -> state(conn).queued == 1 end)

      assert {:error, %Error{kind: :overloaded, reason: :max_queued}} = Client.list_tools(name)

      ready_modern(name, conn)
      {id, _message, _opts} = expect_request(conn, "tools/list")
      reply(conn, id, %{"tools" => []})
      assert {:ok, %{tools: []}} = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "await_ready and subscribe calls while connecting count against max_queued",
         %{name: name} do
      conn = start_client(name, max_queued: 1)
      task = Task.async(fn -> Client.await_ready(name) end)
      eventually(fn -> state(conn).queued == 1 end)

      assert {:error, %Error{kind: :overloaded, reason: :max_queued}} =
               Client.await_ready(name, 200)

      assert {:error, %Error{kind: :overloaded, reason: :max_queued}} =
               Client.subscribe(name, "file:///a", timeout: 200)

      ready_modern(name, conn)
      assert :ok = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "progress reaches the caller, keyed by a progressToken equal to the id",
         %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)
      test_pid = self()

      task =
        Task.async(fn -> Client.call_tool(name, "slow", %{}, on_progress: test_pid) end)

      {id, message, _opts} = expect_request(conn, "tools/call")
      assert message["params"]["_meta"]["progressToken"] == id

      progress = %{"progressToken" => id, "progress" => 1, "total" => 2}
      FakeTransport.push(conn, {:notification, "notifications/progress", progress})
      assert_receive {:mcp_progress, ^name, ^progress}

      FakeTransport.push(
        conn,
        {:notification, "notifications/progress", %{"progressToken" => 0, "progress" => 1}}
      )

      reply(conn, id, %{"content" => [%{"type" => "text", "text" => "done"}]})
      assert {:ok, %ToolResult{content: [%{"text" => "done"}]}} = Task.await(task)
      refute_received {:mcp_progress, ^name, %{"progressToken" => 0}}
      assert_no_leaks(name, conn)
    end

    test "user _meta is sent, but never over the reserved keys", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task =
        Task.async(fn ->
          Client.call_tool(name, "echo", %{"message" => "hi"},
            meta: %{"io.modelcontextprotocol/protocolVersion" => "1999-01-01", "trace" => "t1"}
          )
        end)

      {id, message, _opts} = expect_request(conn, "tools/call")
      assert message["params"]["arguments"] == %{"message" => "hi"}
      assert message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == @modern
      assert message["params"]["_meta"]["trace"] == "t1"

      reply(conn, id, %{"content" => []})
      assert {:ok, %ToolResult{}} = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "-32022 on a ready connection re-discovers and retries the request once",
         %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_tools(name) end)
      {first, _message, _opts} = expect_request(conn, "tools/list")
      reply_error(conn, first, -32_022, %{"supported" => [@modern]})

      {discover, _message, wire_opts} = expect_request(conn, "server/discover")
      assert wire_opts[:probe] == false
      reply(conn, discover, discover_result())

      {second, _message, _opts} = expect_request(conn, "tools/list")
      assert second > discover
      reply(conn, second, %{"tools" => []})

      assert {:ok, %{tools: []}} = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "a JSON-RPC error answer is a :protocol error", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.read_resource(name, "file:///missing") end)
      {id, _message, _opts} = expect_request(conn, "resources/read")
      reply_error(conn, id, -32_602)

      assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, -32_602}}} = Task.await(task)
      assert_no_leaks(name, conn)
    end
  end

  describe "era-dependent operations" do
    test "modern: ping is server/discover, set_log_level goes into _meta", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.ping(name) end)
      {id, _message, _opts} = expect_request(conn, "server/discover")
      reply(conn, id, discover_result())
      assert :ok = Task.await(task)

      assert :ok = Client.set_log_level(name, :warning)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "logging/setLevel"}, _}}

      task = Task.async(fn -> Client.list_prompts(name) end)
      {id, message, _opts} = expect_request(conn, "prompts/list")
      assert message["params"]["_meta"]["io.modelcontextprotocol/logLevel"] == "warning"
      reply(conn, id, %{"prompts" => []})
      assert {:ok, %{prompts: []}} = Task.await(task)

      assert {:error, %Error{kind: :protocol, reason: {:unsupported_in_era, :modern}}} =
               Client.notify_roots_changed(name)

      assert_no_leaks(name, conn)
    end

    test "legacy: ping and logging/setLevel are requests", %{name: name} do
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn)

      task = Task.async(fn -> Client.ping(name) end)
      {id, message, _opts} = expect_request(conn, "ping")
      refute Map.has_key?(message["params"], "_meta")
      reply(conn, id, %{})
      assert :ok = Task.await(task)

      task = Task.async(fn -> Client.set_log_level(name, "error") end)
      {id, message, _opts} = expect_request(conn, "logging/setLevel")
      assert message["params"] == %{"level" => "error"}
      reply(conn, id, %{})
      assert :ok = Task.await(task)

      # No handler, so no roots capability to announce changes of.
      assert {:error, %Error{kind: :protocol, reason: :roots_not_declared}} =
               Client.notify_roots_changed(name)

      assert_no_leaks(name, conn)
    end

    test "legacy: a server ping is answered {}, other server requests -32601", %{name: name} do
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn)

      FakeTransport.push(
        conn,
        {:server_request, 9, %{"jsonrpc" => "2.0", "id" => 9, "method" => "ping"}, nil}
      )

      assert_receive {:fake_transport, ^conn, {:respond, %{"id" => 9, "result" => %{}}}}

      FakeTransport.push(
        conn,
        {:server_request, 10,
         %{"jsonrpc" => "2.0", "id" => 10, "method" => "sampling/createMessage"}, nil}
      )

      assert_receive {:fake_transport, ^conn,
                      {:respond, %{"id" => 10, "error" => %{"code" => -32_601}}}}
    end
  end

  # --- reconnect, close --------------------------------------------------------------

  describe "handler capabilities" do
    for protocol <- [:modern, :legacy] do
      @protocol protocol
      test "are built from the handler once, at start (#{protocol})", %{name: name} do
        :persistent_term.put(CountingModes, self())
        conn = start_client(name, handler: CountingModes, protocol: @protocol)
        assert_received {:elicitation_modes, _pid}
        :persistent_term.put(CountingModes, :raise)
        on_exit(fn -> :persistent_term.erase(CountingModes) end)

        if @protocol == :modern, do: ready_modern(name, conn), else: ready_legacy(name, conn)

        task = Task.async(fn -> Client.list_tools(name) end)
        {id, message, _wire_opts} = expect_request(conn, "tools/list")
        reply(conn, id, %{"tools" => []})
        assert {:ok, %{tools: []}} = Task.await(task)

        if @protocol == :modern do
          assert message["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"] ==
                   %{"elicitation" => %{"form" => %{}}}
        end

        assert Process.alive?(conn)
      end
    end
  end

  describe "reconnect and give-up" do
    for {label, backoff} <- [
          {"raises", quote(do: fn _attempt -> raise "boom" end)},
          {"returns a negative delay", quote(do: fn _attempt -> -5 end)}
        ] do
      @backoff backoff
      test "a :backoff that #{label} falls back to full jitter", %{name: name} do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            conn = start_client(name, backoff: unquote(@backoff))
            ready_modern(name, conn)
            FakeTransport.push(conn, {:closed, :boom})

            # `full_jitter(1)` waits at most 1 s.
            assert_receive {:fake_transport, ^conn, :connect}, 2_000
            assert Process.alive?(conn)
          end)

        assert log =~ "ConduitMcp.Client :backoff"
      end
    end

    test "pending requests fail, the transport reconnects, then gives up", %{name: name} do
      conn = start_client(name, max_reconnects: 1)
      ready_modern(name, conn)
      ref = attach(name, [[:conduit_mcp, :client, :connection, :transition]])

      task = Task.async(fn -> Client.call_tool(name, "slow", %{}) end)
      _ = expect_request(conn, "tools/call")
      FakeTransport.push(conn, {:closed, :boom})

      assert {:error, %Error{kind: :transport, reason: :boom}} = Task.await(task)
      assert_receive {:fake_transport, ^conn, {:close, :boom}}

      assert_receive {[:conduit_mcp, :client, :connection, :transition], ^ref, _,
                      %{from: :ready, to: :reconnecting, reason: :boom, attempt: 1}}

      assert_receive {:fake_transport, ^conn, {:init, _opts}}
      assert_receive {:fake_transport, ^conn, :connect}
      FakeTransport.push(conn, {:closed, :refused})

      assert_receive {[:conduit_mcp, :client, :connection, :transition], ^ref, _,
                      %{from: :connecting, to: :closed, reason: :gave_up}}

      assert {:ok, %{state: :closed, reason: {:gave_up, :refused}}} = Client.status(name)
      assert {:error, %Error{kind: :closed, reason: :gave_up}} = Client.list_tools(name)
      refute_received {:fake_transport, ^conn, :connect}

      assert :ok = Client.reconnect(name)
      assert_receive {:fake_transport, ^conn, :connect}
      ready_modern(name, conn)
      assert_no_leaks(name, conn)
    end

    test "on_give_up: :stop exits so the supervisor restarts the connection",
         %{name: name} do
      conn = start_client(name, max_reconnects: 0, on_give_up: :stop)
      monitor = Process.monitor(conn)
      FakeTransport.push(conn, {:closed, :refused})

      assert_receive {:DOWN, ^monitor, :process, ^conn, {:shutdown, {:gave_up, :refused}}}
      assert_receive {:fake_transport, restarted, :connect}
      assert restarted != conn
      assert_no_leaks(name, restarted)
    end

    test "close/1 fails pending requests and answers at once until reconnect/1",
         %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "slow", %{}) end)
      _ = expect_request(conn, "tools/call")
      assert :ok = Client.close(name)

      assert {:error, %Error{kind: :closed, reason: :closed_by_user}} = Task.await(task)
      assert_receive {:fake_transport, ^conn, {:close, :closed_by_user}}
      assert {:ok, %{state: :closed}} = Client.status(name)
      assert {:error, %Error{kind: :closed}} = Client.ping(name)
      assert {:error, %Error{kind: :closed}} = Client.await_ready(name)
      assert {:error, %Error{reason: :not_ready}} = Client.server_info(name)

      assert :ok = Client.reconnect(name)
      assert_receive {:fake_transport, ^conn, :connect}
      ready_modern(name, conn)
      assert_no_leaks(name, conn)
    end

    test "two missed health checks restart the transport", %{name: name} do
      conn = start_client(name, health_check_interval: 20)
      ready_modern(name, conn)

      _ = expect_request(conn, "server/discover")
      _ = expect_request(conn, "server/discover")
      assert_receive {:fake_transport, ^conn, {:close, :health_check_failed}}
      assert_receive {:fake_transport, ^conn, :connect}
    end

    test "an answered health check keeps the connection", %{name: name} do
      conn = start_client(name, health_check_interval: 20)
      ready_modern(name, conn)

      for _check <- 1..3 do
        {id, _message, _opts} = expect_request(conn, "server/discover")
        reply(conn, id, discover_result())
      end

      refute_received {:fake_transport, ^conn, {:close, _}}
      assert {:ok, %{state: :ready}} = Client.status(name)
    end
  end

  # --- notifications -------------------------------------------------------------------

  describe "notifications" do
    test "a list_changed flood reaches subscribers at most twice", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)
      assert :ok = Client.subscribe_notifications(name)
      assert :ok = Client.subscribe_notifications(name)

      for _ <- 1..100, do: FakeTransport.push(conn, {:notification, @list_changed, %{}})

      assert_receive {:mcp_notification, ^name, @list_changed, %{}}
      assert_receive {:mcp_notification, ^name, @list_changed, %{}}, 1_000

      refute_receive {:mcp_notification, ^name, @list_changed, _},
                     Inbound.window_ms() + 100

      assert_no_leaks(name, conn)
    end

    test "other notifications are fanned out as they come", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)
      ref = attach(name, [[:conduit_mcp, :client, :notification]])
      assert :ok = Client.subscribe_notifications(name)

      params = %{"level" => "info", "data" => "hello"}
      FakeTransport.push(conn, {:notification, "notifications/message", params})

      assert_receive {:mcp_notification, ^name, "notifications/message", ^params}

      assert_receive {[:conduit_mcp, :client, :notification], ^ref, %{count: 1},
                      %{method: "notifications/message"}}

      assert :ok = Client.unsubscribe_notifications(name)
      FakeTransport.push(conn, {:notification, "notifications/message", params})
      _ = :sys.get_state(conn)
      refute_received {:mcp_notification, ^name, _, _}
    end

    test "a subscriber that exits is removed", %{name: name} do
      conn = start_client(name)
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Client.subscribe_notifications(name, subscriber)
      assert map_size(state(conn).subscribers) == 1

      Process.exit(subscriber, :kill)
      eventually(fn -> state(conn).subscribers == %{} end)
    end
  end

  # --- telemetry and redaction -------------------------------------------------------

  describe "telemetry" do
    test "request and tool_call spans run in the caller with allowlisted metadata",
         %{name: name} do
      # A responder plays the server, so the call can run in the test process
      # (spans are emitted by the caller).
      responder = spawn_link(fn -> respond_loop() end)

      start_supervised!(
        {Client, name: name, transport: {FakeTransport, test_pid: responder, auto_connect: true}}
      )

      assert :ok = Client.await_ready(name)

      ref =
        TelemetryTestHelper.attach_event_handlers(self(), [
          [:conduit_mcp, :client, :request, :start],
          [:conduit_mcp, :client, :request, :stop],
          [:conduit_mcp, :client, :tool_call, :start],
          [:conduit_mcp, :client, :tool_call, :stop]
        ])

      assert {:ok, %ToolResult{}} = Client.call_tool(name, "echo", %{"password" => "hunter2"})

      assert_received {[:conduit_mcp, :client, :tool_call, :start], ^ref, %{system_time: _},
                       %{client: ^name, tool_name: "echo", era: :modern, transport: :stdio}}

      assert_received {[:conduit_mcp, :client, :request, :start], ^ref, _,
                       %{client: ^name, method: "tools/call"}}

      assert_received {[:conduit_mcp, :client, :request, :stop], ^ref, %{duration: _},
                       %{status: :ok, error_kind: nil, request_id: id} = request_meta}

      assert is_integer(id)

      assert_received {[:conduit_mcp, :client, :tool_call, :stop], ^ref,
                       %{duration: _, rounds: 1}, %{status: :ok, is_error: false} = tool_meta}

      for meta <- [request_meta, tool_meta] do
        refute inspect(meta) =~ "hunter2"
        refute inspect(meta) =~ "secret-result"
      end
    end

    test "the connection reports its transitions", %{name: name} do
      ref = attach(name, [[:conduit_mcp, :client, :connection, :transition]])
      conn = start_client(name)

      assert_receive {[:conduit_mcp, :client, :connection, :transition], ^ref, _,
                      %{from: nil, to: :connecting, attempt: 0, transport: :stdio}}

      ready_modern(name, conn)

      assert_receive {[:conduit_mcp, :client, :connection, :transition], ^ref, _,
                      %{from: :connecting, to: :discovering}}

      assert_receive {[:conduit_mcp, :client, :connection, :transition], ^ref, _,
                      %{from: :discovering, to: :ready, era: :modern}}
    end

    test "crash-report state hides transport state and queued arguments", %{name: name} do
      conn = start_client(name, transport_opts: [token: "s3cr3t-token"])

      task =
        Task.async(fn -> Client.call_tool(name, "login", %{"password" => "hunter2"}) end)

      eventually(fn -> state(conn).queued == 1 end)

      status = conn |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
      refute status =~ "s3cr3t-token"
      refute status =~ "hunter2"
      assert status =~ ":redacted"

      assert :ok = Client.close(name)
      assert {:error, %Error{kind: :closed}} = Task.await(task)
      assert_no_leaks(name, conn)
    end
  end

  test "crash-report state hides Mcp-Param-* header copies of pending and queued calls",
       %{name: name} do
    conn =
      start_client(name,
        transport: {FakeHTTPTransport, test_pid: self()},
        backoff: fn _attempt -> 60_000 end
      )

    ready_modern(name, conn)

    schema = %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
    }

    task = Task.async(fn -> Client.list_all_tools(name) end)
    {id, _message, _opts} = expect_request(conn, "tools/list")

    reply(conn, id, %{
      "tools" => [%{"name" => "geo", "inputSchema" => schema}],
      "ttlMs" => 60_000,
      "cacheScope" => "public"
    })

    assert {:ok, _page} = Task.await(task)

    args = %{"region" => "PENDING-s3cr3t"}

    pending =
      Task.async(fn -> Client.call_tool(name, "geo", args, assigns: %{k: "ASSIGN-s3cr3t"}) end)

    {_id, _message, wire_opts} = expect_request(conn, "tools/call")
    assert inspect(wire_opts[:headers]) =~ "PENDING-s3cr3t"
    assert_redacted(conn, ["PENDING-s3cr3t", "ASSIGN-s3cr3t"])

    FakeTransport.push(conn, {:closed, :boom})
    assert {:error, %Error{kind: :transport}} = Task.await(pending)

    queued =
      Task.async(fn ->
        Client.call_tool(name, "geo", %{"region" => "QUEUED-s3cr3t"},
          assigns: %{k: "QASSIGN-s3cr3t"}
        )
      end)

    eventually(fn -> state(conn).queued == 1 end)
    assert_redacted(conn, ["QUEUED-s3cr3t", "QASSIGN-s3cr3t"])

    assert :ok = Client.close(name)
    assert {:error, %Error{kind: :closed}} = Task.await(queued)
  end

  defp assert_redacted(conn, secrets) do
    status = conn |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
    for secret <- secrets, do: refute(status =~ secret, secret)
  end

  defp respond_loop do
    receive do
      {:fake_transport, conn, {:request, %{"id" => id, "method" => "server/discover"}, _opts}} ->
        reply(conn, id, discover_result())

      {:fake_transport, conn, {:request, %{"id" => id, "method" => "tools/call"}, _opts}} ->
        reply(conn, id, %{"content" => [%{"type" => "text", "text" => "secret-result"}]})

      _other ->
        :ok
    end

    respond_loop()
  end
end

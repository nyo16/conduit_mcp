defmodule ConduitMcp.Client.HubTest do
  # The multi-server hub end to end over `ConduitMcp.Client.Transport.InProcess`:
  # supervision and restarts, naming and collisions (HB-1, HB-2), governance
  # with per-server overrides (PO-3, PO-7), taint (HB-3).
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ConduitMcp.Test.Client.Harness, only: [eventually: 1]
  import ExUnit.CaptureLog

  alias ConduitMcp.Client
  alias ConduitMcp.Client.{Error, Hub, Policy, Tool, ToolResult, ToolSet}
  alias ConduitMcp.Client.Transport.InProcess
  alias ConduitMcp.TelemetryTestHelper

  doctest ConduitMcp.Client.Hub

  # One server module for every hub server: its tools come from the conn's
  # assigns, and every call is reported to the test (the server-side
  # counter for "nothing was sent").
  defmodule Server do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(conn), do: {:ok, %{"tools" => conn.assigns.tools}}

    @impl true
    def handle_call_tool(conn, name, params) do
      send(conn.assigns.test_pid, {:called, conn.assigns.server, name, params})

      case name do
        "fail" ->
          {:ok, %{"content" => [%{"type" => "text", "text" => "it broke"}], "isError" => true}}

        "block" ->
          receive do: (:never -> {:ok, %{}})

        _other ->
          {:ok, %{"content" => [%{"type" => "text", "text" => "#{conn.assigns.server}:#{name}"}]}}
      end
    end
  end

  # The cross-server truncation collision: both names are over-length, and
  # sha256("alpha" <> <<0>> <> @long_a) and sha256("beta" <> <<0>> <> @long_b)
  # share their first 8 hex digits, so both become "trunc_66c73463".
  @pad String.duplicate("long_tool_name_", 5)
  @long_a @pad <> "a26111"
  @long_b @pad <> "b53096"

  setup do
    {:ok, hub: {__MODULE__, make_ref()}}
  end

  defp tool(name, description \\ "d"),
    do: %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object"}}

  defp server(id, tools, extra \\ []) do
    transport_opts =
      [
        server: Server,
        assigns: %{tools: tools, test_pid: self(), server: id}
      ] ++ Keyword.get(extra, :transport, [])

    {id, [transport: {InProcess, transport_opts}] ++ Keyword.delete(extra, :transport)}
  end

  defp start_hub(hub, servers, opts \\ []) do
    defaults = [name: hub, policy: :allow_all, servers: servers, restart_backoff: fn _ -> 0 end]
    start_supervised!({Hub, Keyword.merge(defaults, opts)})
    await_servers(hub, Enum.map(servers, &elem(&1, 0)))
  end

  defp await_servers(hub, ids) do
    eventually(fn ->
      Enum.all?(ids, &(Client.await_ready(Hub.client(hub, &1), 1_000) == :ok))
    end)
  end

  defp names(hub, opts \\ []) do
    {:ok, toolset} = Hub.list_tools(hub, opts)
    ToolSet.names(toolset)
  end

  defp attach(events, match),
    do: TelemetryTestHelper.attach_event_handlers(self(), events, match: match)

  describe "starting" do
    test "without :policy raises naming the option (R6, PO-2)", %{hub: hub} do
      for start <- [&Hub.child_spec/1, &Hub.start_link/1] do
        assert_raise ArgumentError, ~r/required :policy option not found/, fn ->
          start.(name: hub, servers: [server("a", [])])
        end
      end

      assert_raise ArgumentError, ~r/a hub needs a policy/, fn ->
        Hub.child_spec(name: hub, policy: nil)
      end
    end

    test "duplicate or invalid server ids fail start (HB-1)", %{hub: hub} do
      assert_raise ArgumentError, ~r/duplicate server_id "a"/, fn ->
        Hub.child_spec(name: hub, policy: :allow_all, servers: [server("a", []), server("a", [])])
      end

      assert_raise ArgumentError, ~r/duplicate server_id "a"/, fn ->
        {_id, opts} = server("a", [])
        Hub.child_spec(name: hub, policy: :allow_all, servers: [{"a", opts}, {:a, opts}])
      end

      for bad <- ["Upper", "a__b", "trailing_", ""] do
        assert_raise ArgumentError, ~r/invalid server_id/, fn ->
          Hub.child_spec(name: hub, policy: :allow_all, servers: [server(bad, [])])
        end
      end
    end

    test "the hub names :name and :server_id itself", %{hub: hub} do
      {id, opts} = server("a", [])

      assert_raise ArgumentError, ~r/:name is set by the hub/, fn ->
        Hub.child_spec(name: hub, policy: :allow_all, servers: [{id, [name: :x] ++ opts}])
      end

      assert_raise ArgumentError, ~r/:policy cannot be nil/, fn ->
        Hub.child_spec(name: hub, policy: :allow_all, servers: [{id, [policy: nil] ++ opts}])
      end
    end

    test "servers start in the background and report their state", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")]), server("beta", [tool("echo")])])

      assert {:ok, ["alpha", "beta"]} = Hub.servers(hub)

      assert {:ok, [%{id: "alpha", state: :ready, era: :modern}, %{id: "beta", state: :ready}]} =
               Hub.status(hub)

      assert {:error, %Error{kind: :unavailable}} = Hub.servers({__MODULE__, :missing})
    end
  end

  describe "list_tools/2" do
    test "orders by server then tool and excludes every collider (HB-1)", %{hub: hub} do
      ref = attach([[:conduit_mcp, :client, :hub, :collision]], %{hub: hub})

      rejected =
        attach([[:conduit_mcp, :client, :tool, :rejected]], %{client: Hub.client(hub, "alpha")})

      log =
        capture_log(fn ->
          start_hub(hub, [
            server("alpha", [tool("zeta"), tool("fs.read"), tool("fs_read"), tool("alpha")]),
            server("beta", [tool("echo")])
          ])

          assert names(hub) == ["alpha__zeta", "alpha__alpha", "beta__echo"]
        end)

      assert log =~ "alpha/fs_read, alpha/fs_read all map to the exposed name alpha__fs_read"

      assert_receive {[:conduit_mcp, :client, :hub, :collision], ^ref, %{count: 2},
                      %{hub: ^hub, exposed_name: "alpha__fs_read", colliders: colliders}}

      assert colliders == [{"alpha", "fs_read"}, {"alpha", "fs_read"}]

      for _ <- 1..2 do
        assert_receive {[:conduit_mcp, :client, :tool, :rejected], ^rejected, _,
                        %{server_id: "alpha", reason: :collision}}
      end

      # Memoized: listing the same names again reports nothing new.
      assert names(hub) == ["alpha__zeta", "alpha__alpha", "beta__echo"]
      refute_receive {[:conduit_mcp, :client, :hub, :collision], ^ref, _, _}
    end

    test "a cross-server truncation collision exposes neither tool (HB-1)", %{hub: hub} do
      ref = attach([[:conduit_mcp, :client, :hub, :collision]], %{hub: hub})

      capture_log(fn ->
        start_hub(hub, [
          server("alpha", [tool(@long_a), tool("ok")]),
          server("beta", [tool(@long_b)])
        ])

        assert names(hub) == ["alpha__ok"]
      end)

      assert_receive {_, ^ref, %{count: 2}, %{exposed_name: "trunc_66c73463", colliders: c}}
      assert Enum.map(c, &elem(&1, 0)) == ["alpha", "beta"]
    end

    test "the self-reported serverInfo.name changes nothing (HB-1)", %{hub: hub} do
      honest = [server("alpha", [tool("echo")], transport: [server_name: "alpha"])]
      start_hub(hub, honest)

      liar = {__MODULE__, make_ref()}
      start_hub(liar, [server("alpha", [tool("echo")], transport: [server_name: "beta"])])

      assert {:ok, %{server_info: %{name: "beta"}}} =
               Client.server_info(Hub.client(liar, "alpha"))

      assert names(hub) == names(liar)
      assert names(liar) == ["alpha__echo"]
    end

    test "a filtered tool never reaches the toolset or adapter output (PO-7)", %{hub: hub} do
      start_hub(
        hub,
        [
          server("alpha", [tool("echo"), tool("secret_dump", "TOP-SECRET-DESCRIPTION")]),
          server("beta", [tool("echo"), tool("drop_tables", "DROPS-EVERYTHING")],
            tools: [exclude: ["*/drop_*"]]
          )
        ],
        tools: [exclude: ["alpha/secret_*"]]
      )

      assert names(hub) == ["alpha__echo", "beta__echo"]

      for {provider, opts} <- [
            anthropic: [],
            openai: [api: :chat],
            openai: [api: :responses],
            gemini: []
          ] do
        {:ok, listing} = ConduitMcp.Client.Adapters.tools(hub, provider, opts)
        encoded = JSON.encode!(listing.tools)

        for hidden <- ["secret_dump", "TOP-SECRET", "drop_tables", "DROPS-EVERYTHING"],
            do: refute(encoded =~ hidden, "#{provider} output leaked #{hidden}")

        assert encoded =~ "alpha__echo"
      end

      assert {:error, %Error{kind: :not_found}} =
               Client.tool(Hub.client(hub, "alpha"), "secret_dump")
    end

    test "a server that is down is left out", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")]), server("beta", [tool("echo")])],
        restart_backoff: fn _ -> 60_000 end
      )

      {:ok, toolset} = Hub.list_tools(hub)
      kill_server(hub, "alpha")

      eventually(fn -> match?({:ok, [%{state: :failed}, _]}, Hub.status(hub)) end)
      assert names(hub) == ["beta__echo"]

      assert {:error, %Error{kind: :unavailable}} =
               Hub.call_tool(hub, "alpha__echo", %{}, toolset: toolset)

      refute_received {:called, "alpha", _, _}
    end
  end

  describe "call_tool/4" do
    test "routes to the owning server; an unknown name sends nothing (HB-2)", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")]), server("beta", [tool("echo")])])
      {:ok, toolset} = Hub.list_tools(hub)

      assert {:ok, %ToolResult{content: [%{"text" => "beta:echo"}]}} =
               Hub.call_tool(hub, "beta__echo", %{"x" => 1}, toolset: toolset)

      assert_received {:called, "beta", "echo", %{"x" => 1}}

      for name <- ["gamma__echo", "echo", "alpha__echo\u200B", "beta__echo__x", ""] do
        assert {:ok, %ToolResult{is_error: true, content: [%{"text" => text}]}} =
                 Hub.call_tool(hub, name, %{}, toolset: toolset)

        assert text =~ "unknown tool"
      end

      # Without a toolset, the current one is built.
      assert {:ok, %ToolResult{is_error: true}} = Hub.call_tool(hub, "nope__echo")

      assert {:ok, %ToolResult{content: [%{"text" => "alpha:echo"}]}} =
               Hub.call_tool(hub, "alpha__echo")

      assert_received {:called, "alpha", "echo", _}
      refute_received {:called, _, _, _}
    end

    test "policy matches the {server_id, tool} pair, not the exposed name (PO-3)", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")]), server("beta", [tool("echo")])],
        policy: [allow: ["*/echo"], deny: ["alpha/echo", "*/beta__echo"]]
      )

      assert {:error, %Error{kind: :denied, reason: :deny_rule}} =
               Hub.call_tool(hub, "alpha__echo")

      assert {:ok, %ToolResult{is_error: false}} = Hub.call_tool(hub, "beta__echo")
      refute_received {:called, "alpha", _, _}
    end

    test "per-server policy, hooks and trust override or extend the hub's", %{hub: hub} do
      test_pid = self()
      hook = fn tag -> fn _call, _ctx -> send(test_pid, {:hook, tag}) && :cont end end

      start_hub(
        hub,
        [
          server("alpha", [tool("echo")],
            hooks: [pre_tool_call: [{:all, hook.(:alpha)}]],
            policy: [deny: ["*/*"]]
          ),
          server("beta", [tool("echo")], trusted: true)
        ],
        hooks: [pre_tool_call: [{:all, hook.(:hub)}]]
      )

      assert {:error, %Error{kind: :denied}} = Hub.call_tool(hub, "alpha__echo")
      assert_received {:hook, :hub}
      assert_received {:hook, :alpha}

      assert {:ok, _} = Hub.call_tool(hub, "beta__echo")
      assert_received {:hook, :hub}
      refute_received {:hook, :alpha}

      assert {:ok, ref} = Hub.__lookup__(hub)
      [{_, alpha}, {_, beta}] = ref.config.servers
      refute alpha.governance.trusted
      assert beta.governance.trusted
    end

    test "a taint predicate sees the provenance of the turn (HB-3)", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("read")]), server("beta", [tool("send")])],
        policy: [
          allow: ["*/*"],
          allow_new_tools: true,
          deny: [{:all, ["beta/send", Policy.tainted()]}]
        ]
      )

      assert {:ok, _} = Hub.call_tool(hub, "beta__send")
      assert {:ok, _} = Hub.call_tool(hub, "beta__send", %{}, taint: ["beta"])

      assert {:error, %Error{kind: :denied, reason: :deny_rule}} =
               Hub.call_tool(hub, "beta__send", %{}, taint: MapSet.new(["alpha"]))

      assert {:ok, _} = Hub.call_tool(hub, "alpha__read", %{}, taint: ["beta"])

      assert_raise ArgumentError, ~r/:taint/, fn ->
        Hub.call_tool(hub, "alpha__read", %{}, taint: [:beta])
      end
    end
  end

  describe "supervision" do
    test "a killed server leaves the others serving and comes back (HB-4)", %{hub: hub} do
      ref =
        attach(
          [
            [:conduit_mcp, :client, :hub, :server_failed],
            [:conduit_mcp, :client, :hub, :server_restarted]
          ],
          %{hub: hub}
        )

      start_hub(hub, [server("alpha", [tool("echo")]), server("beta", [tool("echo")])])
      assert names(hub) == ["alpha__echo", "beta__echo"]
      old = kill_server(hub, "alpha")

      assert_receive {[:conduit_mcp, :client, :hub, :server_failed], ^ref, %{delay: 0},
                      %{hub: ^hub, server_id: "alpha", attempt: 1, reason: :killed}}

      assert {:ok, %ToolResult{content: [%{"text" => "beta:echo"}]}} =
               Hub.call_tool(hub, "beta__echo")

      # A restart racing the old processes' exit may fail and be retried
      # (attempt > 1); it ends restarted either way.
      assert_receive {[:conduit_mcp, :client, :hub, :server_restarted], ^ref, _,
                      %{server_id: "alpha", attempt: attempt}}

      assert attempt >= 1

      await_servers(hub, ["alpha"])

      assert {:ok, new, _} =
               ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, "alpha")})

      assert new != old
      assert names(hub) == ["alpha__echo", "beta__echo"]
    end

    test "a crash-looping server never takes the hub down", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")]), server("beta", [tool("echo")])])
      {:ok, hub_pid, _} = ConduitMcp.Client.Registry.lookup({:hub, hub})

      for _ <- 1..10 do
        killed = kill_server(hub, "alpha")
        await_replaced(hub, "alpha", killed)
      end

      assert Process.alive?(hub_pid)
      assert names(hub) == ["alpha__echo", "beta__echo"]
    end

    test "the manager restarts without restarting servers or losing added ones", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")])])
      {added, opts} = server("beta", [tool("echo")])
      :ok = Hub.add_server(hub, added, opts)
      await_servers(hub, ["beta"])

      {:ok, alpha, _} = ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, "alpha")})
      {:ok, manager, _} = ConduitMcp.Client.Registry.lookup({:hub_manager, hub})
      monitor = Process.monitor(manager)
      Process.exit(manager, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}

      eventually(fn ->
        match?(
          {:ok, pid, _} when pid != manager,
          ConduitMcp.Client.Registry.lookup({:hub_manager, hub})
        )
      end)

      assert {:ok, ["alpha", "beta"]} = Hub.servers(hub)

      assert {:ok, ^alpha, _} =
               ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, "alpha")})

      # Still monitored: a crash after the manager's restart is noticed.
      killed = kill_server(hub, "alpha")
      await_replaced(hub, "alpha", killed)
      assert names(hub) == ["alpha__echo", "beta__echo"]
    end
  end

  describe "add_server/3 and remove_server/2" do
    test "are reflected in list_tools; add is idempotent", %{hub: hub} do
      start_hub(hub, [server("alpha", [tool("echo")])])
      assert names(hub) == ["alpha__echo"]

      {id, opts} = server("gamma", [tool("echo"), tool("more")])
      assert :ok = Hub.add_server(hub, id, opts)
      await_servers(hub, ["gamma"])
      assert names(hub) == ["alpha__echo", "gamma__echo", "gamma__more"]

      {_id, other} = server("gamma", [tool("different")])
      assert :ok = Hub.add_server(hub, :gamma, other)
      assert names(hub) == ["alpha__echo", "gamma__echo", "gamma__more"]

      assert :ok = Hub.remove_server(hub, "alpha")
      assert names(hub) == ["gamma__echo", "gamma__more"]
      assert {:ok, ["gamma"]} = Hub.servers(hub)
      # The Registry drops a dead process's entry asynchronously.
      eventually(fn ->
        ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, "alpha")}) == :error
      end)

      assert {:error, %Error{kind: :not_found}} = Hub.remove_server(hub, "alpha")

      assert_raise ArgumentError, ~r/invalid server_id/, fn ->
        Hub.add_server(hub, "Bad", opts)
      end

      assert_raise ArgumentError, ~r/:server_id is set by the hub/, fn ->
        Hub.add_server(hub, "delta", [server_id: "x"] ++ opts)
      end
    end
  end

  describe "naming property (HB-2)" do
    # Hub-shaped data: several servers, names that sanitize alike, over-length
    # names. Every accepted tool gets a distinct exposed name that resolves back
    # to exactly that tool.
    property "exposed names are injective over accepted tools" do
      check all(
              ids <- map(integer(1..4), &Enum.take(~w(alpha alpha_b a beta), &1)),
              lists <- list_of(tool_names(), length: length(ids)),
              prefix <- member_of(["", "mcp_"])
            ) do
        servers =
          for {id, names} <- Enum.zip(ids, lists) do
            {id,
             for name <- Enum.uniq(names) do
               {:ok, tool} = Tool.from_wire(id, %{"name" => name, "inputSchema" => %{}})
               tool
             end}
          end

        {toolset, report} = ConduitMcp.Client.Naming.build(servers, prefix: prefix)
        entries = ToolSet.entries(toolset)
        targets = Enum.map(entries, fn {_name, tool} -> {tool.server_id, tool.name} end)

        assert length(Enum.uniq(targets)) == length(entries)

        for {name, tool} <- entries do
          assert name =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/
          assert {:ok, ^tool} = ToolSet.resolve(toolset, name)
          assert {:ok, ^name} = ToolSet.exposed_name(toolset, tool.server_id, tool.name)
        end

        collided = for {_name, colliders} <- report.collisions, target <- colliders, do: target
        assert MapSet.disjoint?(MapSet.new(collided), MapSet.new(targets))
      end
    end
  end

  defp tool_names do
    list_of(
      one_of([
        member_of(~w(read read_file read.file Read-File search fs__x x_)),
        map(integer(50..80), &String.duplicate("t", &1))
      ]),
      max_length: 6
    )
  end

  defp kill_server(hub, id) do
    {:ok, pid, _} = ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, id)})
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    pid
  end

  # The Registry drops a dead client's entry asynchronously, so readiness
  # alone can still be the killed process's; wait for its replacement.
  defp await_replaced(hub, id, killed) do
    eventually(fn ->
      match?(
        {:ok, pid, _} when pid != killed,
        ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, id)})
      )
    end)

    await_servers(hub, [id])
  end
end

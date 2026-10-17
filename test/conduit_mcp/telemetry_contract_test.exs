defmodule ConduitMcp.TelemetryContractTest do
  # Pins every event's key sets to `ConduitMcp.Telemetry`'s "Key reference"
  # (TL-1): a wildcard handler records what real server and client flows
  # emit, and each emission must carry exactly the documented measurement
  # keys, every "always" metadata key, and nothing outside "always" and
  # "sometimes". The flows cover every event in `events/0`, so a new event
  # fails here until a flow emits it.
  #
  # `async: false`: the handler is attached to every event, the janitors
  # sweep node-wide tables, and the listen uses the node-wide
  # `ConduitMcp.Subscriptions` registry.
  use ExUnit.Case, async: false

  @moduletag :integration

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.{Adapters, Hub, Secret, ToolResult}
  alias ConduitMcp.Client.Transport.{InProcess, StreamableHTTP}
  alias ConduitMcp.TelemetryTestHelper
  alias ConduitMcp.Test.Client.{FakeTransport, HTTPServers}

  @token "contract-token"

  defmodule Server do
    use ConduitMcp.Server

    alias ConduitMcp.Cancellation
    alias ConduitMcp.Test.Client.HTTPServers

    tool "echo", "Echoes the message" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => message} -> text(message) end)
    end

    tool "approve", "Answers after the user approves" do
      handle(fn conn, _params ->
        case conn.assigns[:mcp_input] do
          nil ->
            elicit =
              ConduitMcp.MRTR.elicit("Approve?", %{"type" => "object", "properties" => %{}})

            {:input_required, %{"ok" => elicit}, %{"step" => 1}}

          %{responses: %{"ok" => %{"action" => action}}} ->
            text("approval: " <> action)
        end
      end)
    end

    tool "progress", "Reports progress" do
      handle(fn conn, _params ->
        ConduitMcp.Progress.report(conn, 1, total: 2)
        text("done")
      end)
    end

    tool "slow", "Runs until cancelled" do
      param(:test, :string, "Test key", required: true)

      handle(fn conn, %{"test" => key} ->
        send(HTTPServers.test_pid(key), :slow_started)
        wait_cancelled(conn)
      end)
    end

    resource "test://doc" do
      description("A document")
      mime_type("text/plain")
      read(fn _conn, _params, _opts -> raw_resource("doc", "text/plain") end)
    end

    prompt "greeting", "A greeting" do
      arg(:name, :string, "Name")
      get(fn _conn, args -> [user("Hello, #{args["name"]}!")] end)
    end

    defp wait_cancelled(conn) do
      if Cancellation.cancelled?(conn) do
        text("cancelled")
      else
        receive do
        after
          5 -> wait_cancelled(conn)
        end
      end
    end
  end

  defmodule HubServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(conn), do: {:ok, %{"tools" => conn.assigns.tools}}

    @impl true
    def handle_call_tool(_conn, name, _params),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => name}]}}
  end

  # The Ext.Tasks janitor's store, without touching the node's task table.
  defmodule NullStore do
    def cleanup(_ttl), do: 0
  end

  defmodule Approver do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "accept", "content" => %{}}}
  end

  defmodule Raiser do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_sampling(_params, _ctx), do: raise("sampling handler failed")
  end

  setup do
    previous = Application.get_env(:conduit_mcp, :mrtr_keys)
    Application.put_env(:conduit_mcp, :mrtr_keys, [{"contract", :crypto.strong_rand_bytes(32)}])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:conduit_mcp, :mrtr_keys, previous),
        else: Application.delete_env(:conduit_mcp, :mrtr_keys)
    end)
  end

  test "the moduledoc's key reference lists every event" do
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(ConduitMcp.Telemetry)
    assert moduledoc =~ "### Key reference"

    for {event, _measurements, _always, _sometimes} <- ConduitMcp.Telemetry.__event_specs__() do
      assert moduledoc =~ "| `#{inspect(event)}` |", inspect(event)
    end
  end

  test "every event emitted by real flows carries exactly its documented keys" do
    collector = spawn_link(fn -> collect([]) end)

    _ref =
      TelemetryTestHelper.attach_event_handlers(collector, ConduitMcp.Telemetry.events(),
        match: %{}
      )

    capture_flows(fn ->
      http_flows(collector)
      connection_flows(collector)
      governance_flows(collector)
      hub_flows(collector)
      janitor_flows(collector)
    end)

    emitted = collected(collector)
    specs = Map.new(ConduitMcp.Telemetry.__event_specs__(), fn {e, m, a, s} -> {e, {m, a, s}} end)

    violations =
      emitted
      |> Enum.flat_map(fn {event, measurements, metadata} ->
        {documented_measurements, always, sometimes} = Map.fetch!(specs, event)
        keys = Map.keys(metadata)

        [
          {:measurements, sorted(Map.keys(measurements)), sorted(documented_measurements)},
          {:undocumented_metadata, sorted(keys -- (always ++ sometimes)), []},
          {:missing_metadata, sorted(always -- keys), []}
        ]
        |> Enum.reject(fn {_check, got, want} -> got == want end)
        |> Enum.map(&{event, &1})
      end)
      |> Enum.uniq()

    assert violations == []

    missing = ConduitMcp.Telemetry.events() -- Enum.map(emitted, &elem(&1, 0))
    assert missing == [], "no flow emitted #{inspect(missing)}"
  end

  defp sorted(keys), do: Enum.sort(keys)

  # Logs are noise here (crashing handlers, failed auth, the default
  # client warnings); they are scanned in `SecretScanTest`.
  defp capture_flows(fun), do: ExUnit.CaptureLog.capture_log(fun)

  # --- the collector ---------------------------------------------------------

  defp collect(acc) do
    receive do
      {:get, from} ->
        send(from, {:collected, Enum.reverse(acc)})
        collect(acc)

      {event, _ref, measurements, metadata} when is_list(event) ->
        collect([{event, measurements, metadata} | acc])
    end
  end

  defp collected(collector) do
    send(collector, {:get, self()})
    assert_receive {:collected, emitted}
    emitted
  end

  defp await_event(collector, event, timeout \\ 3_000) do
    eventually(fn -> Enum.any?(collected(collector), &(elem(&1, 0) == event)) end, timeout)
  end

  # --- server and client over HTTP ---------------------------------------------

  defp http_flows(collector) do
    limiter = [backend: ConduitMcp.TestRateLimiter, limit: 10_000, scale: 60_000]

    url =
      HTTPServers.serve_mcp(Server,
        session: [],
        auth: [strategy: :bearer_token, token: @token],
        rate_limit: limiter,
        message_rate_limit: limiter
      )

    auth = [auth: {:bearer, Secret.new(@token)}]
    modern = start_http(url, auth, protocol: :modern, handler: Approver)

    assert {:ok, %ToolResult{}} = Client.call_tool(modern, "echo", %{"message" => "hi"})

    assert {:ok, %ToolResult{content: [%{"text" => "approval: accept"}]}} =
             Client.call_tool(modern, "approve", %{})

    assert {:ok, _contents} = Client.read_resource(modern, "test://doc")
    assert {:ok, _prompt} = Client.get_prompt(modern, "greeting", %{"name" => "Ada"})
    assert {:ok, _tools} = Client.list_all_tools(modern)

    # A raise in the caller's progress callback ends both spans with
    # `:exception`.
    assert_raise RuntimeError, fn ->
      Client.call_tool(modern, "progress", %{}, on_progress: fn _ -> raise "progress" end)
    end

    :ok = Client.subscribe_notifications(modern)
    await_event(collector, [:conduit_mcp, :subscription, :start])
    :ok = stop_supervised({Client, modern})
    await_event(collector, [:conduit_mcp, :subscription, :stop])

    # Legacy: a timed-out call is cancelled by `notifications/cancelled`.
    legacy = start_http(url, auth, protocol: :legacy)
    key = HTTPServers.register_test()

    assert {:error, %Client.Error{kind: :timeout}} =
             Client.call_tool(legacy, "slow", %{"test" => key}, timeout: 300)

    assert_receive :slow_started
    await_event(collector, [:conduit_mcp, :request, :cancelled])

    # A client without the token fails authentication.
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client, name: name, transport: {StreamableHTTP, url: url}, backoff: fn _ -> 60_000 end},
      id: name
    )

    assert {:error, _closed} = Client.await_ready(name, 5_000)
  end

  defp start_http(url, transport_opts, opts) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       [
         name: name,
         transport: {StreamableHTTP, [url: url] ++ transport_opts},
         backoff: fn _ -> 0 end
       ] ++ opts},
      id: {Client, name}
    )

    assert :ok = Client.await_ready(name, 5_000)
    name
  end

  # --- connection internals over the fake transport -------------------------

  defp connection_flows(collector) do
    name = {__MODULE__, make_ref()}
    conn = start_client(name, server_id: "fake")
    ready_modern(name, conn)

    tool = fn description ->
      %{"name" => "a", "description" => description, "inputSchema" => %{"type" => "object"}}
    end

    bad = %{"name" => "bad name", "inputSchema" => %{"type" => "object"}}

    task = Task.async(fn -> Client.list_all_tools(name) end)
    {id, _message, _opts} = expect_request(conn, "tools/list")
    reply(conn, id, %{"tools" => [tool.("old"), bad]})
    assert {:ok, _tools} = Task.await(task)

    FakeTransport.push(conn, {:notification, "notifications/tools/list_changed", %{}})
    {id, _message, _opts} = expect_request(conn, "tools/list")
    reply(conn, id, %{"tools" => [tool.("new")]})
    await_event(collector, [:conduit_mcp, :client, :tool, :definition_changed])

    # Timed out, then answered late.
    assert {:error, %Client.Error{kind: :timeout}} = Client.call_tool(name, "a", %{}, timeout: 50)
    {id, _message, _opts} = expect_request(conn, "tools/call")
    reply(conn, id, %{"content" => []})
    await_event(collector, [:conduit_mcp, :client, :response, :dropped])

    # A backlog in the connection's mailbox.
    :ok = :sys.suspend(conn)

    for _ <- 1..1_100,
        do: FakeTransport.push(conn, {:notification, "notifications/message", %{}})

    :ok = :sys.resume(conn)
    await_event(collector, [:conduit_mcp, :client, :transport, :mailbox])

    # A legacy sampling handler that raises.
    legacy = {__MODULE__, make_ref()}
    conn = start_client(legacy, protocol: :legacy, handler: Raiser)
    ready_legacy(legacy, conn)
    call = Task.async(fn -> Client.call_tool(legacy, "t", %{}) end)
    {call_id, _message, _opts} = expect_request(conn, "tools/call")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "sampling/createMessage",
      "params" => %{"messages" => [], "maxTokens" => 10}
    }

    FakeTransport.push(conn, {:server_request, 1, request, call_id})
    await_event(collector, [:conduit_mcp, :client, :input_request, :exception])
    reply(conn, call_id, %{"content" => []})
    assert {:ok, _result} = Task.await(call)
  end

  # --- governance over InProcess ----------------------------------------------

  defp governance_flows(collector) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       name: name,
       server_id: "gov",
       protocol: :modern,
       transport: {InProcess, server: Server},
       policy: [allow: ["gov/*"]],
       hooks: [
         pre_tool_call: [{:all, fn _call, _ctx -> :cont end, id: :pass}],
         post_tool_call: [{:all, fn _call, _result, _ctx -> raise "no" end, on_error: :ignore}]
       ]},
      id: name
    )

    assert :ok = Client.await_ready(name)

    assert {:ok, %ToolResult{}} =
             Client.call_tool(name, "echo", %{"message" => "hi"}, principal: "alice")

    assert {:ok, _contents} = Client.read_resource(name, "test://doc")
    await_event(collector, [:conduit_mcp, :client, :hook, :exception])
  end

  # --- hub and adapters ---------------------------------------------------------

  defp hub_flows(collector) do
    hub = {__MODULE__, make_ref()}
    open = %{"type" => "object", "properties" => %{}, "additionalProperties" => true}

    tools = [
      %{"name" => "a.b", "inputSchema" => %{"type" => "object"}},
      %{"name" => "a_b", "inputSchema" => %{"type" => "object"}},
      %{"name" => "open", "inputSchema" => open}
    ]

    servers =
      for id <- ["alpha", "beta"],
          do: {id, [transport: {InProcess, server: HubServer, assigns: %{tools: tools}}]}

    start_supervised!(
      {Hub, name: hub, policy: :allow_all, servers: servers, restart_backoff: fn _ -> 0 end},
      id: hub
    )

    eventually(fn ->
      Enum.all?(["alpha", "beta"], &(Client.await_ready(Hub.client(hub, &1), 1_000) == :ok))
    end)

    assert {:ok, _listing} = Adapters.tools(hub, :openai, api: :chat)
    await_event(collector, [:conduit_mcp, :client, :hub, :collision])
    await_event(collector, [:conduit_mcp, :client, :adapter, :strict_fallback])

    {:ok, pid, _} = ConduitMcp.Client.Registry.lookup({:supervisor, Hub.client(hub, "alpha")})
    Process.exit(pid, :kill)
    await_event(collector, [:conduit_mcp, :client, :hub, :server_restarted])
  end

  # --- janitors -------------------------------------------------------------------

  defp janitor_flows(collector) do
    _removed = ConduitMcp.Cancellation.cleanup(60_000)

    janitors = [
      {ConduitMcp.Session.Janitor, store: ConduitMcp.Session.EtsStore},
      {ConduitMcp.Session.Janitor,
       store: ConduitMcp.Cancellation, telemetry_event: [:conduit_mcp, :cancellation, :janitor]},
      {ConduitMcp.Session.Janitor,
       store: NullStore, telemetry_event: [:conduit_mcp, :ext_tasks, :cleanup]},
      {ConduitMcp.Tasks.Janitor, []}
    ]

    for {module, opts} <- janitors do
      name = Module.concat(__MODULE__, "Janitor#{System.unique_integer([:positive])}")
      start_supervised!({module, [name: name, interval: 10] ++ opts}, id: name)
    end

    for event <- [
          [:conduit_mcp, :session, :cleanup],
          [:conduit_mcp, :cancellation, :janitor],
          [:conduit_mcp, :ext_tasks, :cleanup],
          [:conduit_mcp, :tasks, :cleanup]
        ],
        do: await_event(collector, event)
  end
end

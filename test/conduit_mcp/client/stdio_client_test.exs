defmodule ConduitMcp.Client.StdioClientTest do
  # The client end to end over `ConduitMcp.Client.Transport.Stdio` against
  # `test/support/fixtures/stdio_server.exs`: an Elixir process serving this
  # library's own server modules on stdin/stdout, in both protocol eras.
  use ExUnit.Case, async: true

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Prompt
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Resource
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.Stdio
  alias ConduitMcp.TelemetryTestHelper
  alias ConduitMcp.Test.Client.StdioFixture
  alias ConduitMcp.Test.Client.StdioMrtrServer

  @moduletag :stdio

  if Stdio.windows?(), do: @moduletag(skip: "the stdio fixtures are POSIX scripts")

  # An Elixir fixture boots in about half a second; a loaded runner can be
  # several times slower.
  @boot 15_000

  defmodule ElicitHandler do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "accept", "content" => %{}}}
  end

  defp start_client(transport, opts) do
    name = {__MODULE__, make_ref()}
    start_supervised!({Client, Keyword.merge([name: name, transport: transport], opts)})
    name
  end

  defp start_ready(transport, opts) do
    name = start_client(transport, opts)
    assert :ok = Client.await_ready(name, @boot)
    name
  end

  # No request left pending, no task left running, and once the client
  # stops the server process is gone.
  defp assert_no_leaks(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {_state, data} = :sys.get_state(conn)
    assert data.pending == %{}

    {:ok, task_sup, _value} = Registry.lookup({:task_sup, name})
    assert Task.Supervisor.children(task_sup) == []

    owner = StdioFixture.port_owner(name)
    os_pid = StdioFixture.os_pid(owner)
    :ok = stop_supervised({Client, name})
    StdioFixture.await_reaped(owner)
    refute StdioFixture.os_alive?(os_pid)
  end

  for protocol <- [:modern, :legacy, :auto] do
    @protocol protocol

    test "ConduitMcp.TestServer over stdio, protocol: #{inspect(protocol)}" do
      name = start_ready(StdioFixture.server(), protocol: @protocol)
      era = if @protocol == :legacy, do: :legacy, else: :modern
      assert {:ok, ^era} = Client.era(name)
      assert :ok = Client.ping(name)

      assert {:ok, %{tools: tools, next_cursor: nil}} = Client.list_tools(name)
      assert %Tool{} = Enum.find(tools, &(&1.name == "echo"))

      assert {:ok, %ToolResult{is_error: false, content: [%{"text" => "hi"}]}} =
               Client.call_tool(name, "echo", %{"message" => "hi"})

      assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, -32_000}}} =
               Client.call_tool(name, "fail")

      assert {:ok, %{resources: [%Resource{uri: "test://resource1"} | _]}} =
               Client.list_resources(name)

      assert {:ok, %{"contents" => [%{"text" => "Test content"} | _]}} =
               Client.read_resource(name, "test://resource1")

      assert {:ok, %{prompts: prompts}} = Client.list_prompts(name)
      assert Enum.any?(prompts, &match?(%Prompt{name: "greeting"}, &1))

      assert {:ok, %{"messages" => [%{"content" => %{"text" => "Hello, Ada!"}} | _]}} =
               Client.get_prompt(name, "greeting", %{name: "Ada"})

      assert_no_leaks(name)
    end
  end

  # The server's sealed `InputRequiredResult` crosses stdio, the caller's
  # MRTR loop hands the elicitation to `ElicitHandler`, and the retry with
  # the echoed `requestState` completes the call.
  test "an MRTR round trip completes over modern stdio" do
    name =
      start_ready(StdioFixture.server("normal", server: StdioMrtrServer),
        protocol: :modern,
        handler: ElicitHandler
      )

    assert {:ok, %ToolResult{content: [%{"text" => "hi"}]}} =
             Client.call_tool(name, "echo", %{"message" => "hi"})

    assert {:ok, %ToolResult{content: [%{"text" => "approval: accept"}], is_error: false}} =
             Client.call_tool(name, "approve")

    assert_no_leaks(name)
  end

  # Modern stdio listen: the listen request never completes, its
  # notifications are demultiplexed by `subscriptionId`, and a reconnect
  # (a new server process) re-sends it.
  test "subscriptions/listen over modern stdio, re-sent after a reconnect" do
    name =
      start_ready(StdioFixture.server("normal", server: StdioMrtrServer),
        protocol: :modern,
        backoff: fn _attempt -> 0 end
      )

    :ok = Client.subscribe_notifications(name)
    first = await_listen(name)

    assert {:ok, %ToolResult{content: [%{"text" => "touched"}]}} = Client.call_tool(name, "touch")
    assert_receive {:mcp_notification, ^name, "notifications/tools/list_changed", params}, 2_000
    refute Map.has_key?(params, "_meta")

    :ok = Client.reconnect(name)
    assert :ok = Client.await_ready(name, @boot)
    second = await_listen(name)
    assert second > first

    assert {:ok, %ToolResult{}} = Client.call_tool(name, "touch")
    assert_receive {:mcp_notification, ^name, "notifications/tools/list_changed", _params}, 2_000

    assert_no_leaks(name)
  end

  defp await_listen(name, deadline \\ System.monotonic_time(:millisecond) + @boot) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {_state, data} = :sys.get_state(conn)

    cond do
      data.listen.active != nil ->
        data.listen.active

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the listen was never acknowledged")

      true ->
        receive do
        after
          10 -> await_listen(name, deadline)
        end
    end
  end

  test "a server that never answers server/discover is legacy after probe_timeout" do
    name = start_ready(StdioFixture.server("never_answer_discover"), probe_timeout: 200)
    assert {:ok, :legacy} = Client.era(name)

    assert {:ok, %ToolResult{content: [%{"text" => "late"}]}} =
             Client.call_tool(name, "echo", %{"message" => "late"})

    assert_no_leaks(name)
  end

  test "a timed-out request is cancelled and its late answer dropped" do
    name = start_ready(StdioFixture.server("slow:300"), protocol: :legacy)

    ref =
      TelemetryTestHelper.attach_event_handlers(
        self(),
        [
          [:conduit_mcp, :client, :request, :cancel],
          [:conduit_mcp, :client, :response, :dropped]
        ],
        match: %{client: name}
      )

    assert {:error, %Error{kind: :timeout}} =
             Client.call_tool(name, "echo", %{"message" => "x"}, timeout: 50)

    assert_receive {[:conduit_mcp, :client, :request, :cancel], ^ref, _, %{reason: :timeout}}
    assert_receive {[:conduit_mcp, :client, :response, :dropped], ^ref, _, _}, 2_000

    assert {:ok, %ToolResult{content: [%{"text" => "y"}]}} =
             Client.call_tool(name, "echo", %{"message" => "y"})

    assert_no_leaks(name)
  end

  test "interleaved junk lines are tolerated" do
    name = start_ready(StdioFixture.server("garbage_stdout"), protocol: :legacy)

    assert {:ok, %ToolResult{content: [%{"text" => "ok"}]}} =
             Client.call_tool(name, "echo", %{"message" => "ok"})

    assert_no_leaks(name)
  end

  test "more junk lines in a row than the budget restart the server" do
    name =
      start_client(StdioFixture.server("garbage_stdout:11", stderr: :discard),
        protocol: :legacy,
        max_reconnects: 0
      )

    assert {:error, %Error{kind: :closed, data: {:gave_up, :junk_output}}} =
             Client.await_ready(name, @boot)
  end

  test "a server that exits is restarted (exit_status ⇒ reconnect)" do
    # initialize, then tools/list: the second answer is the server's last.
    name =
      start_ready(StdioFixture.server("exit_after:2"), protocol: :legacy, backoff: fn _ -> 0 end)

    ref =
      TelemetryTestHelper.attach_event_handlers(
        self(),
        [[:conduit_mcp, :client, :connection, :transition]],
        match: %{client: name, to: :reconnecting}
      )

    first = StdioFixture.os_pid(StdioFixture.port_owner(name))
    assert {:ok, %{tools: [_ | _]}} = Client.list_tools(name)

    assert_receive {_event, ^ref, _, %{reason: :exit_status}}, @boot

    # The new server answered `initialize`; it has one answer left.
    assert :ok = Client.await_ready(name, @boot)
    second = StdioFixture.os_pid(StdioFixture.port_owner(name))
    assert second != first
    refute StdioFixture.os_alive?(first)

    assert_no_leaks(name)
  end

  test "a 20 MB line fails with :message_too_large and the server is stopped" do
    name =
      start_ready(StdioFixture.server("huge_line", stderr: :discard),
        protocol: :legacy,
        max_reconnects: 0
      )

    owner = StdioFixture.port_owner(name)
    os_pid = StdioFixture.os_pid(owner)

    assert {:error, %Error{kind: :transport, reason: :message_too_large}} =
             Client.call_tool(name, "echo", %{"message" => "boom"})

    StdioFixture.await_reaped(owner)
    refute StdioFixture.os_alive?(os_pid)

    assert {:ok, %{state: :closed, reason: {:gave_up, :message_too_large}}} = Client.status(name)
  end

  test "killing the connection still stops the server" do
    name = start_ready(StdioFixture.server(), protocol: :legacy)
    {:ok, conn, _view} = Registry.lookup({:client, name})
    owner = StdioFixture.port_owner(name)
    os_pid = StdioFixture.os_pid(owner)

    Process.exit(conn, :kill)

    # The linked port owner traps the exit: EOF, then TERM/KILL if needed.
    StdioFixture.await_reaped(owner)
    refute StdioFixture.os_alive?(os_pid)

    # The client's supervisor restarted the connection with a new server.
    assert :ok = Client.await_ready(name, @boot)
    assert_no_leaks(name)
  end

  test "a server that ignores EOF is stopped with TERM when the client stops" do
    server = StdioFixture.server("ignore_eof", stdin_grace: 300, term_grace: 5_000)
    name = start_ready(server, protocol: :legacy)
    owner = StdioFixture.port_owner(name)
    os_pid = StdioFixture.os_pid(owner)

    started = System.monotonic_time(:millisecond)
    :ok = stop_supervised({Client, name})
    elapsed = StdioFixture.await_reaped(owner, since: started)

    # Not before the stdin grace; KILL would not come before 5 300 ms.
    assert elapsed >= 300 and elapsed < 5_000
    refute StdioFixture.os_alive?(os_pid)
  end
end

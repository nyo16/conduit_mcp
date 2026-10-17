defmodule ConduitMcp.Client.HubWireTest do
  # The hub where the test plays each server
  # (`ConduitMcp.Test.Client.FakeTransport`): multi-round-trip retries stay
  # on their server (MR-3), and a misbehaving server's tool list (HB-4).
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client.{Error, Hub, ToolResult, ToolSet}
  alias ConduitMcp.Test.Client.FakeTransport

  @tools_changed "notifications/tools/list_changed"

  defmodule Sampler do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_sampling(_params, _ctx) do
      {:ok,
       %{"role" => "assistant", "content" => %{"type" => "text", "text" => "hi"}, "model" => "m"}}
    end
  end

  # Answers `roots/list` from the client's own assigns: the per-server
  # roots configuration.
  defmodule Rooted do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def list_roots(ctx), do: {:ok, %{"roots" => ctx.assigns.roots}}
  end

  setup do
    {:ok, hub: {__MODULE__, make_ref()}}
  end

  defp tool(name), do: %{"name" => name, "inputSchema" => %{"type" => "object"}}

  # Starts the hub and completes each server's handshake (modern unless
  # `ready:` says otherwise); returns `%{server_id => connection pid}`.
  # `server_opts:` maps a server id to client options merged over the
  # defaults.
  defp start_hub(hub, ids, opts \\ []) do
    {server_opts, opts} = Keyword.pop(opts, :server_opts, %{})
    {ready, opts} = Keyword.pop(opts, :ready, &ready_modern/2)

    servers =
      for id <- ids do
        defaults = [
          transport: {FakeTransport, test_pid: self(), tag: id},
          backoff: fn _attempt -> 0 end,
          handler: Sampler
        ]

        {id, Keyword.merge(defaults, Map.get(server_opts, id, []))}
      end

    start_supervised!({Hub, [name: hub, policy: :allow_all, servers: servers] ++ opts})

    conns =
      Map.new(ids, fn _id ->
        assert_receive {:fake_transport, conn, {:init, init}}
        {Keyword.fetch!(init, :tag), conn}
      end)

    for {id, conn} <- conns do
      assert_receive {:fake_transport, ^conn, :connect}
      ready.(Hub.client(hub, id), conn)
    end

    await_hub_ready(hub, ids)
    conns
  end

  defp serve_tools(conn, tools) do
    {id, _message, _opts} = expect_request(conn, "tools/list")
    reply(conn, id, %{"tools" => tools})
  end

  defp list(hub, conns_and_tools, opts \\ []) do
    task = Task.async(fn -> Hub.list_tools(hub, opts) end)
    for {conn, tools} <- conns_and_tools, do: serve_tools(conn, tools)
    {:ok, toolset} = Task.await(task)
    toolset
  end

  test "a multi-round-trip retry goes to the same server (MR-3)", %{hub: hub} do
    %{"a" => a, "b" => b} = start_hub(hub, ["a", "b"])
    toolset = list(hub, [{a, [tool("t")]}, {b, [tool("t")]}])
    assert ToolSet.names(toolset) == ["a__t", "b__t"]

    task = Task.async(fn -> Hub.call_tool(hub, "b__t", %{}, toolset: toolset) end)
    {id, first, _opts} = expect_request(b, "tools/call")
    assert first["params"]["name"] == "t"

    reply(b, id, %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "s" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 10}
        }
      },
      "requestState" => "state-b"
    })

    {retry_id, retry, _opts} = expect_request(b, "tools/call")
    assert retry_id != id
    assert retry["params"]["requestState"] == "state-b"
    assert %{"s" => %{"role" => "assistant"}} = retry["params"]["inputResponses"]
    reply(b, retry_id, %{"content" => [%{"type" => "text", "text" => "done"}]})

    assert {:ok, %ToolResult{content: [%{"text" => "done"}]}} = Task.await(task)
    # Server "a" opens its own `subscriptions/listen` once its tools are
    # cached; what must never reach it is any part of "b"'s call.
    refute_received {:fake_transport, ^a, {:request, %{"method" => "tools/call"}, _}}
  end

  test "a list_changed flood costs a few fetches, not one per notification (HB-4)", %{hub: hub} do
    %{"a" => a} = start_hub(hub, ["a"])
    list(hub, [{a, [tool("t")]}])

    lister =
      Task.async(fn ->
        for _ <- 1..50, do: {:ok, _} = Hub.list_tools(hub, timeout: 2_000)
      end)

    for _ <- 1..1_000, do: FakeTransport.push(a, {:notification, @tools_changed, %{}})

    fetches = answer_lists(a, [tool("t"), tool("u")], 0)
    Task.await(lister, 5_000)

    assert fetches in 1..5
    assert {:ok, toolset} = Hub.list_tools(hub)
    assert ToolSet.names(toolset) == ["a__t", "a__u"]
  end

  # Answers every `tools/list` until none comes for 600 ms; returns how many.
  defp answer_lists(conn, tools, count) do
    receive do
      {:fake_transport, ^conn, {:request, %{"method" => "tools/list", "id" => id}, _opts}} ->
        reply(conn, id, %{"tools" => tools})
        answer_lists(conn, tools, count + 1)
    after
      600 -> count
    end
  end

  test "repeated failed fetches open the breaker until one succeeds (HB-4)", %{hub: hub} do
    %{"a" => a, "b" => b} =
      start_hub(hub, ["a", "b"], refetch_interval: 0, breaker_threshold: 2)

    list(hub, [{a, [tool("t")]}, {b, [tool("t")]}])

    # `a` changes its list but never answers the refresh.
    FakeTransport.push(a, {:notification, @tools_changed, %{}})
    {pending, _message, _opts} = expect_request(a, "tools/list")

    # First failure: the last good list is still offered.
    assert {:ok, toolset} = Hub.list_tools(hub, timeout: 20)
    assert ToolSet.names(toolset) == ["a__t", "b__t"]

    # Second failure: the breaker opens and `a` is left out.
    assert {:ok, toolset} = Hub.list_tools(hub, timeout: 20)
    assert ToolSet.names(toolset) == ["b__t"]

    reply(a, pending, %{"tools" => [tool("t"), tool("new")]})

    eventually(fn ->
      match?({:ok, [_, _]}, ConduitMcp.Client.cached_tools(Hub.client(hub, "a")))
    end)

    # The next attempt probes (the list has no TTL, so it is fetched) and
    # closes the breaker.
    task = Task.async(fn -> Hub.list_tools(hub, timeout: 1_000) end)
    serve_tools(a, [tool("t"), tool("new")])
    assert {:ok, toolset} = Task.await(task)
    assert ToolSet.names(toolset) == ["a__t", "a__new", "b__t"]
  end

  describe "roots per server (SC-5)" do
    @roots %{
      "a" => [%{"uri" => "file:///srv/a", "name" => "a"}],
      "b" => [%{"uri" => "file:///srv/b", "name" => "b"}]
    }

    defp rooted(ids) do
      Map.new(ids, &{&1, [handler: Rooted, assigns: %{roots: Map.get(@roots, &1)}]})
    end

    test "modern: a multi-round-trip roots/list is answered with the asking server's roots",
         %{hub: hub} do
      %{"a" => a, "b" => b, "c" => c} =
        start_hub(hub, ["a", "b", "c"], server_opts: rooted(["a", "b"]))

      toolset = list(hub, [{a, [tool("t")]}, {b, [tool("t")]}, {c, [tool("t")]}])
      call = fn name -> Task.async(fn -> Hub.call_tool(hub, name, %{}, toolset: toolset) end) end
      calls = %{"a" => call.("a__t"), "b" => call.("b__t"), "c" => call.("c__t")}

      ask = %{
        "resultType" => "input_required",
        "inputRequests" => %{"r" => %{"method" => "roots/list"}}
      }

      firsts =
        for {id, conn} <- [{"a", a}, {"b", b}, {"c", c}], into: %{} do
          {call_id, first, _opts} = expect_request(conn, "tools/call")
          {id, {call_id, first}}
        end

      # Only the servers configured with roots are told the client has them.
      for {id, {_call_id, first}} <- firsts do
        caps = first["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
        assert Map.has_key?(caps, "roots") == (id != "c"), id
      end

      # Asked in reverse order, so no answer follows request order.
      for {id, conn} <- [{"c", c}, {"b", b}, {"a", a}] do
        {call_id, _first} = firsts[id]
        reply(conn, call_id, ask)
      end

      for {id, conn} <- [{"a", a}, {"b", b}] do
        {retry_id, retry, _opts} = expect_request(conn, "tools/call")
        expected = @roots[id]
        assert %{"r" => %{"roots" => ^expected}} = retry["params"]["inputResponses"]
        reply(conn, retry_id, %{"content" => [%{"type" => "text", "text" => id}]})
      end

      assert {:ok, %ToolResult{content: [%{"text" => "a"}]}} = Task.await(calls["a"])
      assert {:ok, %ToolResult{content: [%{"text" => "b"}]}} = Task.await(calls["b"])

      # The server without roots configured gets no roots at all, nor anyone
      # else's: its call fails without a retry.
      assert {:error, %Error{reason: {:undeclared_input_request, _}}} = Task.await(calls["c"])
      refute_received {:fake_transport, ^c, {:request, %{"method" => "tools/call"}, _}}
    end

    test "legacy: a server's roots/list request is answered with its own roots", %{hub: hub} do
      server_opts =
        Map.new(rooted(["a", "b"]), fn {id, opts} -> {id, [protocol: :legacy] ++ opts} end)

      %{"a" => a, "b" => b} =
        start_hub(hub, ["a", "b"], server_opts: server_opts, ready: &ready_legacy/2)

      request = %{"jsonrpc" => "2.0", "id" => 7, "method" => "roots/list", "params" => %{}}
      FakeTransport.push(b, {:server_request, 7, request, nil})
      FakeTransport.push(a, {:server_request, 7, request, nil})

      for {id, conn} <- [{"a", a}, {"b", b}] do
        assert_receive {:fake_transport, ^conn, {:respond, %{"id" => 7} = response}}, 1_000
        expected = @roots[id]
        assert %{"result" => %{"roots" => ^expected}} = response
      end
    end
  end
end

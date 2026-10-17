defmodule ConduitMcp.Client.HubWireTest do
  # The hub where the test plays each server
  # (`ConduitMcp.Test.Client.FakeTransport`): multi-round-trip retries stay
  # on their server (MR-3), and a misbehaving server's tool list (HB-4).
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client.{Hub, ToolResult, ToolSet}
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

  setup do
    {:ok, hub: {__MODULE__, make_ref()}}
  end

  defp tool(name), do: %{"name" => name, "inputSchema" => %{"type" => "object"}}

  # Starts the hub and completes each server's modern handshake; returns
  # `%{server_id => connection pid}`.
  defp start_hub(hub, ids, opts \\ []) do
    servers =
      for id <- ids do
        {id,
         [
           transport: {FakeTransport, test_pid: self(), tag: id},
           backoff: fn _attempt -> 0 end,
           handler: Sampler
         ]}
      end

    start_supervised!({Hub, [name: hub, policy: :allow_all, servers: servers] ++ opts})

    conns =
      Map.new(ids, fn _id ->
        assert_receive {:fake_transport, conn, {:init, init}}
        {Keyword.fetch!(init, :tag), conn}
      end)

    for {id, conn} <- conns do
      assert_receive {:fake_transport, ^conn, :connect}
      ready_modern(Hub.client(hub, id), conn)
    end

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
    refute_received {:fake_transport, ^a, {:request, _, _}}
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
end

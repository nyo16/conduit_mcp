defmodule ConduitMcp.Client.CacheTest do
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Connection.Inbound
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Test.Client.FakeTransport

  @tools_changed "notifications/tools/list_changed"

  setup do
    {:ok, name: {__MODULE__, make_ref()}}
  end

  defp tool(name, description \\ "d"),
    do: %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object"}}

  defp cache(name) do
    {:ok, _pid, view} = Request.lookup(name)
    view.cache
  end

  # Serves one `tools/list` page.
  defp serve_page(conn, tools, extra \\ %{}) do
    {id, message, _opts} = expect_request(conn, "tools/list")
    reply(conn, id, Map.merge(%{"tools" => tools}, extra))
    message["params"]
  end

  describe "the table" do
    test "a list write replaces the point rows of the previous version" do
      tid = Cache.new()
      {:ok, a} = Tool.from_wire("s", tool("a"))
      {:ok, b} = Tool.from_wire("s", tool("b"))

      v1 = Cache.put_list(tid, :tools, [a, b], 1_000, 0)
      assert {:ok, ^b} = Cache.lookup(tid, :tools, "b")

      v2 = Cache.put_list(tid, :tools, [a], 1_000, 10)
      assert v2 > v1

      assert {:ok, %{items: [^a], version: ^v2, fetched_at: 10, expires_at: 1_010}} =
               Cache.list(tid, :tools)

      assert :miss = Cache.lookup(tid, :tools, "b")
      assert {:ok, ^a} = Cache.lookup(tid, :tools, "a")
    end

    test "freshness: stale or expired lists are not fresh" do
      tid = Cache.new()
      Cache.put_list(tid, :prompts, [], 100, 0)
      {:ok, entry} = Cache.list(tid, :prompts)
      assert Cache.fresh?(entry, 99)
      refute Cache.fresh?(entry, 100)

      assert Cache.mark_stale(tid, :prompts)
      {:ok, entry} = Cache.list(tid, :prompts)
      refute Cache.fresh?(entry, 0)
      refute Cache.mark_stale(tid, :resources)
    end

    test "only the owner writes; any process reads" do
      tid = Cache.new()
      Cache.put_list(tid, :tools, [], 0, 0)

      reader =
        Task.async(fn ->
          read = Cache.list(tid, :tools)
          write = catch_error(:ets.insert(tid, {:tools, 0, [], 0, 0, false}))
          {read, write}
        end)

      assert {{:ok, %{items: []}}, :badarg} = Task.await(reader)
    end

    test "a dead table reads as :unavailable" do
      parent = self()

      owner =
        spawn(fn ->
          send(parent, {:table, Cache.new()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:table, tid}
      ref = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}

      assert {:error, %Error{kind: :unavailable, reason: :cache_gone}} = Cache.list(tid, :tools)
      assert {:error, %Error{kind: :unavailable}} = Cache.lookup(tid, :tools, "a")
      assert {:error, %Error{kind: :unavailable}} = Cache.status(tid)
    end
  end

  describe "list_all_tools/2" do
    test "follows cursors and serves a fresh list from the cache", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      params = serve_page(conn, [tool("a")], %{"nextCursor" => "c1", "ttlMs" => 60_000})
      refute Map.has_key?(params, "cursor")

      assert %{"cursor" => "c1"} =
               serve_page(conn, [tool("b")], %{"ttlMs" => 120_000})

      assert {:ok, [%Tool{name: "a", fingerprint: fp}, %Tool{name: "b"}]} = Task.await(task)
      assert is_binary(fp)

      # Fresh for the smaller of the two hints: no request.
      assert {:ok, [%Tool{name: "a"}, %Tool{name: "b"}]} = Client.list_all_tools(name)
      _ = state(conn)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "tools/list"}, _}}

      assert {:ok, %{expires_at: expires_at, fetched_at: fetched_at}} =
               Cache.list(cache(name), :tools)

      assert expires_at - fetched_at == 60_000

      assert {:ok, %Tool{name: "b"}} = Client.tool(name, "b")
      assert {:error, %Error{kind: :not_found}} = Client.tool(name, "zzz")
      assert {:ok, [_, _]} = Client.cached_tools(name)

      # `refresh: true` asks again.
      task = Task.async(fn -> Client.list_all_tools(name, refresh: true) end)
      serve_page(conn, [tool("a")])
      assert {:ok, [%Tool{name: "a"}]} = Task.await(task)
      assert {:error, %Error{kind: :not_found}} = Client.tool(name, "b")

      assert_no_leaks(name, conn)
    end

    test "no ttlMs means no freshness, and the hint is clamped", %{name: name} do
      conn = start_client(name, max_cache_ttl: 50)
      ready_modern(name, conn)
      assert {:error, %Error{kind: :not_found, reason: :not_cached}} = Client.cached_tools(name)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a")])
      assert {:ok, [_]} = Task.await(task)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a")], %{"ttlMs" => 10_000_000})
      assert {:ok, [_]} = Task.await(task)

      assert {:ok, %{expires_at: expires_at, fetched_at: fetched_at}} =
               Cache.list(cache(name), :tools)

      assert expires_at - fetched_at == 50
      assert_no_leaks(name, conn)
    end

    test "concurrent callers share one refresh", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      tasks = for _ <- 1..5, do: Task.async(fn -> Client.list_all_tools(name) end)
      eventually(fn -> match?(%{tools: %{waiters: [_, _, _, _, _]}}, state(conn).refreshes) end)

      serve_page(conn, [tool("a")])
      assert Enum.all?(Task.await_many(tasks), &match?({:ok, [%Tool{name: "a"}]}, &1))
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "tools/list"}, _}}
      assert_no_leaks(name, conn)
    end

    test "a repeated cursor is a :pagination_cycle and nothing is cached", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a")], %{"nextCursor" => "c1"})
      serve_page(conn, [tool("b")], %{"nextCursor" => "c1"})

      assert {:error, %Error{kind: :pagination_cycle, reason: :repeated_cursor}} =
               Task.await(task)

      assert :miss = Cache.list(cache(name), :tools)
      assert_no_leaks(name, conn)
    end

    test "a cursor over 1 KiB is refused", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [], %{"nextCursor" => String.duplicate("x", 1_025)})

      assert {:error, %Error{kind: :pagination_cycle, reason: :cursor_too_large}} =
               Task.await(task)

      assert_no_leaks(name, conn)
    end

    test "more than 100 pages is refused after the 100th", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      for page <- 1..100, do: serve_page(conn, [], %{"nextCursor" => "c#{page}"})

      assert {:error, %Error{kind: :pagination_cycle, reason: :max_pages}} = Task.await(task)
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "tools/list"}, _}}
      assert_no_leaks(name, conn)
    end

    test "more than 10 000 items is refused", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, for(i <- 1..10_001, do: tool("t#{i}")), %{"nextCursor" => "more"})

      assert {:error, %Error{kind: :pagination_cycle, reason: :max_items}} = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "prompts, resources and templates are listed and cached too", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_prompts(name) end)
      {id, _, _} = expect_request(conn, "prompts/list")
      reply(conn, id, %{"prompts" => [%{"name" => "p"}], "ttlMs" => 60_000})
      assert {:ok, [%{name: "p"}]} = Task.await(task)

      task = Task.async(fn -> Client.list_all_resources(name) end)
      {id, _, _} = expect_request(conn, "resources/list")
      reply(conn, id, %{"resources" => [%{"uri" => "x://1", "name" => "one"}]})
      assert {:ok, [%{uri: "x://1"}]} = Task.await(task)

      task = Task.async(fn -> Client.list_all_resource_templates(name) end)
      {id, _, _} = expect_request(conn, "resources/templates/list")
      reply(conn, id, %{"resourceTemplates" => [%{"uriTemplate" => "x://{id}", "name" => "t"}]})
      assert {:ok, [%{"uriTemplate" => "x://{id}"}]} = Task.await(task)

      assert {:ok, %{"uriTemplate" => "x://{id}"}} =
               Cache.lookup(cache(name), :resource_templates, "x://{id}")

      assert {:ok, [%{name: "p"}]} = Client.list_all_prompts(name)
      assert_no_leaks(name, conn)
    end
  end

  describe "invalidation" do
    test "100 list_changed notifications cause at most two refreshes", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a")], %{"ttlMs" => 60_000})
      assert {:ok, _} = Task.await(task)

      ref =
        attach(name, [
          [:conduit_mcp, :client, :cache, :refresh, :start],
          [:conduit_mcp, :client, :cache, :refresh, :stop]
        ])

      for _ <- 1..100, do: FakeTransport.push(conn, {:notification, @tools_changed, %{}})

      refreshes = serve_refreshes(conn, 0)
      assert refreshes in 1..2

      assert_receive {[:conduit_mcp, :client, :cache, :refresh, :start], ^ref, _,
                      %{kind: :tools, trigger: :list_changed}}

      assert_receive {[:conduit_mcp, :client, :cache, :refresh, :stop], ^ref,
                      %{count: 1, pages: 1, rejected: 0}, %{kind: :tools, status: :ok}}

      assert_no_leaks(name, conn)
    end

    test "a changed definition of a known tool is reported", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)
      ref = attach(name, [[:conduit_mcp, :client, :tool, :definition_changed]])

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a", "old"), tool("b")])
      {:ok, [%Tool{fingerprint: before} | _]} = Task.await(task)

      FakeTransport.push(conn, {:notification, @tools_changed, %{}})
      serve_page(conn, [tool("a", "new"), tool("b"), tool("c")])

      assert_receive {[:conduit_mcp, :client, :tool, :definition_changed], ^ref, %{count: 1},
                      %{tool_name: "a", server_id: _}}

      refute_received {[:conduit_mcp, :client, :tool, :definition_changed], ^ref, _, _}
      eventually(fn -> state(conn).refreshes == %{} end)
      assert {:ok, %Tool{fingerprint: now}} = Client.tool(name, "a")
      assert now != before
      assert {:ok, %Tool{name: "c"}} = Client.tool(name, "c")
      assert_no_leaks(name, conn)
    end

    test "list_changed before any listing fetches nothing", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      FakeTransport.push(conn, {:notification, @tools_changed, %{}})
      _ = state(conn)
      refute_receive {:fake_transport, ^conn, {:request, %{"method" => "tools/list"}, _}}
      assert_no_leaks(name, conn)
    end

    test "resources/list_changed refreshes resources and templates", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_resource_templates(name) end)
      {id, _, _} = expect_request(conn, "resources/templates/list")
      reply(conn, id, %{"resourceTemplates" => []})
      assert {:ok, []} = Task.await(task)

      FakeTransport.push(conn, {:notification, "notifications/resources/list_changed", %{}})
      {id, _, _} = expect_request(conn, "resources/templates/list")
      reply(conn, id, %{"resourceTemplates" => []})
      refute_receive {:fake_transport, ^conn, {:request, %{"method" => "resources/list"}, _}}
      eventually(fn -> state(conn).refreshes == %{} end)
      assert_no_leaks(name, conn)
    end

    test "a lost connection marks cached lists stale", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a")], %{"ttlMs" => 60_000})
      assert {:ok, _} = Task.await(task)
      assert {:ok, %{stale?: false}} = Cache.list(cache(name), :tools)

      FakeTransport.push(conn, {:closed, :boom})
      assert_receive {:fake_transport, ^conn, :connect}
      ready_modern(name, conn)

      assert {:ok, %{stale?: true}} = Cache.list(cache(name), :tools)
      task = Task.async(fn -> Client.list_all_tools(name) end)
      serve_page(conn, [tool("a")])
      assert {:ok, _} = Task.await(task)
      assert_no_leaks(name, conn)
    end
  end

  # Answers `tools/list` refreshes until none comes for a full coalescing
  # window; returns how many there were.
  defp serve_refreshes(conn, count) do
    receive do
      {:fake_transport, ^conn, {:request, %{"method" => "tools/list", "id" => id}, _}} ->
        reply(conn, id, %{"tools" => [tool("a")]})
        serve_refreshes(conn, count + 1)
    after
      Inbound.window_ms() + 200 -> count
    end
  end
end

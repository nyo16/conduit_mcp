defmodule ConduitMcp.HandlerTasksTest do
  # async: false — deliberately.
  #
  # These tests wipe the global `:conduit_mcp_tasks` table wholesale. That
  # table is owned by the supervised `ConduitMcp.Tasks.EtsStore.Owner` and is
  # shared by four modules (this one, ConduitMcp.TasksTest,
  # ConduitMcp.Tasks.JanitorTest and ConduitMcp.PrincipalTest). They used to be
  # kept apart only by ExUnit's async/sync phase split, with nothing encoding
  # it: these tests lived in the `async: true` ConduitMcp.HandlerTest under a
  # comment claiming sole ownership, and flipping any sibling to async would
  # have raced `:ets.delete_all_objects/1`.
  #
  # Every module that *writes* `:conduit_mcp_tasks` — creates, deletes, or
  # wipes rows — MUST be `async: false`. Reads are safe from anywhere:
  # ConduitMcp.SecurityTest is `async: true` and reaches this table through
  # Handler.handle_request/2 for a `tasks/get` on an id that cannot exist,
  # which is why the stricter "touches" wording was already false when written.
  use ExUnit.Case, async: false

  alias ConduitMcp.Handler
  alias ConduitMcp.Protocol
  alias ConduitMcp.TestServer

  defp owner_conn(user), do: Plug.Conn.assign(%Plug.Conn{}, :current_user, user)

  defp task_req(method, task_id) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => %{"taskId" => task_id}}
  end

  describe "tasks/* methods" do
    setup do
      if :ets.whereis(:conduit_mcp_tasks) != :undefined do
        :ets.delete_all_objects(:conduit_mcp_tasks)
      end

      :ok
    end

    test "tasks/get returns task metadata for an existing task" do
      {:ok, _} = ConduitMcp.Tasks.create("t1", %{"tool" => "echo"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/get",
        "params" => %{"taskId" => "t1"}
      }

      response = Handler.handle_request(request, TestServer)

      assert response["result"]["task"]["task_id"] == "t1"
      assert response["result"]["task"]["status"] == "working"
    end

    test "tasks/get returns -32002 for missing task" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/get",
        "params" => %{"taskId" => "missing"}
      }

      response = Handler.handle_request(request, TestServer)

      assert response["error"]["code"] == ConduitMcp.Errors.resource_not_found()
    end

    test "tasks/get returns invalid_params when taskId missing" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/get",
        "params" => %{}
      }

      response = Handler.handle_request(request, TestServer)
      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
    end

    test "tasks/cancel transitions a working task to cancelled" do
      {:ok, _} = ConduitMcp.Tasks.create("t2", %{"tool" => "echo"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/cancel",
        "params" => %{"taskId" => "t2"}
      }

      response = Handler.handle_request(request, TestServer)
      assert response["result"]["task"]["status"] == "cancelled"
    end

    test "tasks/result returns the result for a completed task" do
      {:ok, _} = ConduitMcp.Tasks.create("t3", %{"tool" => "echo"})

      ConduitMcp.Tasks.update("t3", %{
        "status" => "completed",
        "result" => %{"content" => [%{"type" => "text", "text" => "done"}]}
      })

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/result",
        "params" => %{"taskId" => "t3"}
      }

      response = Handler.handle_request(request, TestServer)

      assert response["result"]["content"] == [%{"type" => "text", "text" => "done"}]
    end

    test "tasks/result errors when task is still working" do
      {:ok, _} = ConduitMcp.Tasks.create("t4", %{"tool" => "echo"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/result",
        "params" => %{"taskId" => "t4"}
      }

      response = Handler.handle_request(request, TestServer)
      assert response["error"]["code"] == -32004
      assert response["error"]["message"] =~ "Task not finished"
    end

    test "tasks/list returns all tasks" do
      {:ok, _} = ConduitMcp.Tasks.create("t5")
      {:ok, _} = ConduitMcp.Tasks.create("t6")

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/list",
        "params" => %{}
      }

      response = Handler.handle_request(request, TestServer)
      task_ids = Enum.map(response["result"]["tasks"], & &1["task_id"])
      assert "t5" in task_ids
      assert "t6" in task_ids
    end

    test "tasks/list filters by status" do
      {:ok, _} = ConduitMcp.Tasks.create("working_one")
      {:ok, _} = ConduitMcp.Tasks.create("done_one")
      ConduitMcp.Tasks.update("done_one", %{"status" => "completed"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/list",
        "params" => %{"status" => "completed"}
      }

      response = Handler.handle_request(request, TestServer)
      task_ids = Enum.map(response["result"]["tasks"], & &1["task_id"])
      assert task_ids == ["done_one"]
    end

    test "tasks/cancel without a taskId returns invalid_params" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/cancel", "params" => %{}}

      response = Handler.handle_request(request, TestServer)

      assert response["error"]["code"] == Protocol.invalid_params()
      assert response["error"]["message"] == "Missing taskId"
    end

    test "tasks/result without a taskId returns invalid_params" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/result", "params" => %{}}

      response = Handler.handle_request(request, TestServer)

      assert response["error"]["code"] == Protocol.invalid_params()
      assert response["error"]["message"] == "Missing taskId"
    end

    test "tasks/result returns the error payload of a failed task" do
      {:ok, _} = ConduitMcp.Tasks.create("failed_one", %{})

      {:ok, _} =
        ConduitMcp.Tasks.update("failed_one", %{
          "status" => "failed",
          "error" => %{"code" => -32_000, "message" => "boom"}
        })

      response = Handler.handle_request(task_req("tasks/result", "failed_one"), TestServer)

      assert response["result"]["error"] == %{"code" => -32_000, "message" => "boom"}
    end

    test "tasks/result on an unfinished task reports task_not_ready" do
      {:ok, _} = ConduitMcp.Tasks.create("still_working", %{})

      response = Handler.handle_request(task_req("tasks/result", "still_working"), TestServer)

      assert response["error"]["code"] == ConduitMcp.Errors.task_not_ready()
      assert response["error"]["message"] =~ "working"
    end
  end

  # T-L4: the library's entire contract is "callbacks return {:ok, map()} |
  # {:error, map()}". Its enforcement had no test.
  describe "callback contract enforcement" do
    defmodule BadReturnServer do
      @moduledoc false
      use ConduitMcp.Server, dsl: false

      @impl true
      def handle_list_tools(_conn), do: {:ok, %{"tools" => []}}

      @impl true
      def handle_call_tool(_conn, "naked_map", _params), do: %{"content" => []}
      def handle_call_tool(_conn, "bare_atom", _params), do: :ok
      def handle_call_tool(_conn, "wrong_tuple", _params), do: {:ok, "not a map"}
      def handle_call_tool(_conn, _name, _params), do: {:error, %{}}
    end

    setup do
      ConduitMcp.ServerMeta.clear(BadReturnServer)
      :ok
    end

    for tool <- ~w(naked_map bare_atom wrong_tuple) do
      test "a callback returning #{tool} is reported as an internal error" do
        request = %{
          "jsonrpc" => "2.0",
          "id" => 42,
          "method" => "tools/call",
          "params" => %{"name" => unquote(tool), "arguments" => %{}}
        }

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(self(), {:response, Handler.handle_request(request, BadReturnServer)})
          end)

        assert_received {:response, response}

        assert response["id"] == 42
        assert response["error"]["code"] == Protocol.internal_error()
        assert response["error"]["message"] == "Internal server error"
        assert log =~ "Unexpected result from handle_call_tool"
      end
    end
  end

  # W2 (BOLA/IDOR): tasks/* must be scoped to the caller's principal so one user
  # can't read or cancel another's task, while staying back-compatible for the
  # no-principal path. Lives in this module (the only consumer of the global
  # :conduit_mcp_tasks table) so the table is never touched concurrently.
  describe "tasks/* owner scoping (W2)" do
    setup do
      if :ets.whereis(:conduit_mcp_tasks) != :undefined do
        :ets.delete_all_objects(:conduit_mcp_tasks)
      end

      :ok
    end

    test "owner/1 extracts current_user and is nil without a principal" do
      assert ConduitMcp.Tasks.owner(owner_conn("alice")) == "alice"
      assert ConduitMcp.Tasks.owner(%Plug.Conn{}) == nil
      assert ConduitMcp.Tasks.owner(nil) == nil
    end

    test "facade get/2 hides another principal's task and no longer defaults open" do
      {:ok, _} = ConduitMcp.Tasks.create("os1", %{"tool" => "echo"}, "alice")
      assert {:ok, %{"owner" => "alice"}} = ConduitMcp.Tasks.get("os1", "alice")
      assert {:error, :not_found} = ConduitMcp.Tasks.get("os1", "bob")

      # A caller with no principal used to see *everything*. It now sees only
      # what nobody owns.
      assert {:error, :not_found} = ConduitMcp.Tasks.get("os1", nil)

      {:ok, _} = ConduitMcp.Tasks.create("os1u", %{"tool" => "echo"})
      assert {:ok, _} = ConduitMcp.Tasks.get("os1u", "bob")
      assert {:ok, _} = ConduitMcp.Tasks.get("os1u", nil)
    end

    test "facade cancel/2 refuses a non-owner and leaves the task working" do
      {:ok, _} = ConduitMcp.Tasks.create("os2", %{"tool" => "echo"}, "alice")
      assert {:error, :not_found} = ConduitMcp.Tasks.cancel("os2", "bob")
      assert {:ok, %{"status" => "working"}} = ConduitMcp.Tasks.get("os2", "alice")
      assert {:ok, %{"status" => "cancelled"}} = ConduitMcp.Tasks.cancel("os2", "alice")
    end

    test "facade list/2 returns own + unowned and excludes others, including for nil" do
      {:ok, _} = ConduitMcp.Tasks.create("os3a", %{}, "alice")
      {:ok, _} = ConduitMcp.Tasks.create("os3b", %{}, "bob")
      {:ok, _} = ConduitMcp.Tasks.create("os3u", %{})

      bob_ids = ConduitMcp.Tasks.list([], "bob") |> Enum.map(& &1["task_id"])
      assert "os3b" in bob_ids
      assert "os3u" in bob_ids
      refute "os3a" in bob_ids

      nil_ids = ConduitMcp.Tasks.list([], nil) |> Enum.map(& &1["task_id"])
      assert nil_ids == ["os3u"]

      # The unscoped arity is still available for server-side callers.
      all_ids = ConduitMcp.Tasks.list() |> Enum.map(& &1["task_id"])
      assert Enum.all?(~w(os3a os3b os3u), &(&1 in all_ids))
    end

    test "the store applies the owner filter itself, not the facade" do
      {:ok, _} = ConduitMcp.Tasks.create("sf1", %{}, "alice")
      {:ok, _} = ConduitMcp.Tasks.create("sf2", %{}, "bob")

      rows = ConduitMcp.Tasks.EtsStore.list(owner: "alice")
      assert Enum.map(rows, & &1["task_id"]) == ["sf1"]
    end

    test "a status filter matching nothing returns nothing" do
      # Named for what it asserts. The *no-copy* property — that a non-matching
      # row is never copied into the caller's heap — is delivered by folding
      # status, owner and limit into one `:ets.select/3` match spec
      # (tasks/ets_store.ex:159) and is not cheaply observable from Elixir; the
      # assertions below hold against the old fold-then-filter too.
      for i <- 1..20, do: {:ok, _} = ConduitMcp.Tasks.create("bulk-#{i}", %{}, "alice")

      assert ConduitMcp.Tasks.EtsStore.list(status: "completed") == []
      assert ConduitMcp.Tasks.list([status: "completed"], "alice") == []
      assert length(ConduitMcp.Tasks.list([status: "working"], "alice")) == 20
    end

    test ":limit bounds the number of rows returned" do
      for i <- 1..10, do: {:ok, _} = ConduitMcp.Tasks.create("lim-#{i}", %{}, "alice")

      assert length(ConduitMcp.Tasks.list([limit: 3], "alice")) == 3
      assert ConduitMcp.Tasks.list([limit: 0], "alice") == []
    end

    # NB: the `:task_owner_fun` config-override test lives in
    # ConduitMcp.Tasks.OwnerExtractorTest because it mutates the global
    # application env, which would leak into every other module in the run.
    # (This module is itself async: false — see the note at the top.)

    test "handler tasks/get: non-owner gets not-found, owner succeeds" do
      {:ok, _} = ConduitMcp.Tasks.create("oh1", %{"tool" => "echo"}, "alice")

      bob = Handler.handle_request(task_req("tasks/get", "oh1"), TestServer, owner_conn("bob"))
      assert bob["error"]["code"] == ConduitMcp.Errors.resource_not_found()

      alice =
        Handler.handle_request(task_req("tasks/get", "oh1"), TestServer, owner_conn("alice"))

      assert alice["result"]["task"]["task_id"] == "oh1"
    end

    test "handler tasks/result: non-owner gets not-found, owner gets the result" do
      {:ok, _} = ConduitMcp.Tasks.create("oh2", %{}, "alice")
      ConduitMcp.Tasks.update("oh2", %{"status" => "completed", "result" => %{"ok" => true}})

      bob = Handler.handle_request(task_req("tasks/result", "oh2"), TestServer, owner_conn("bob"))
      assert bob["error"]["code"] == ConduitMcp.Errors.resource_not_found()

      alice =
        Handler.handle_request(task_req("tasks/result", "oh2"), TestServer, owner_conn("alice"))

      assert alice["result"] == %{"ok" => true}
    end

    test "handler tasks/cancel: non-owner cannot cancel" do
      {:ok, _} = ConduitMcp.Tasks.create("oh3", %{}, "alice")

      bob = Handler.handle_request(task_req("tasks/cancel", "oh3"), TestServer, owner_conn("bob"))
      assert bob["error"]["code"] == ConduitMcp.Errors.resource_not_found()
      assert {:ok, %{"status" => "working"}} = ConduitMcp.Tasks.get("oh3", "alice")
    end

    test "handler tasks/list: excludes another principal's tasks" do
      {:ok, _} = ConduitMcp.Tasks.create("oh4a", %{}, "alice")
      {:ok, _} = ConduitMcp.Tasks.create("oh4b", %{}, "bob")

      list_req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/list", "params" => %{}}
      resp = Handler.handle_request(list_req, TestServer, owner_conn("bob"))
      ids = Enum.map(resp["result"]["tasks"], & &1["task_id"])
      assert "oh4b" in ids
      refute "oh4a" in ids
    end

    test "an unauthenticated caller can no longer read an owned task" do
      {:ok, _} = ConduitMcp.Tasks.create("oh5", %{}, "alice")
      # No conn → empty %Plug.Conn{} → owner nil. This used to succeed.
      resp = Handler.handle_request(task_req("tasks/get", "oh5"), TestServer)
      assert resp["error"]["code"] == ConduitMcp.Errors.resource_not_found()
    end

    test "an unauthenticated caller can still read an unowned task" do
      {:ok, _} = ConduitMcp.Tasks.create("oh6", %{})
      resp = Handler.handle_request(task_req("tasks/get", "oh6"), TestServer)
      assert resp["result"]["task"]["task_id"] == "oh6"
    end

    test "tasks/list clamps the response to the server maximum" do
      # The previous version created 10 tasks and asked for 10_000, asserting
      # 10 came back — which `min(10_000, 100)` and an unclamped 10_000 both
      # satisfy, so the clamp could be deleted with the suite green. The clamp
      # only becomes observable when the table holds more rows than the
      # maximum, so lower the maximum instead of raising the fixture.
      previous = Application.get_env(:conduit_mcp, :tasks_list_max_limit)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:conduit_mcp, :tasks_list_max_limit)
          value -> Application.put_env(:conduit_mcp, :tasks_list_max_limit, value)
        end
      end)

      Application.put_env(:conduit_mcp, :tasks_list_max_limit, 3)

      for i <- 1..10, do: {:ok, _} = ConduitMcp.Tasks.create("cl-#{i}", %{}, "bob")

      req = fn params ->
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/list", "params" => params}
      end

      # A client asking for more than the server maximum gets the maximum,
      # not what it asked for and not everything in the table.
      resp = Handler.handle_request(req.(%{"limit" => 10_000}), TestServer, owner_conn("bob"))
      assert length(resp["result"]["tasks"]) == 3

      # Omitting :limit is also clamped — the fallback is the maximum, not
      # unbounded.
      resp = Handler.handle_request(req.(%{}), TestServer, owner_conn("bob"))
      assert length(resp["result"]["tasks"]) == 3

      # A client under the maximum still gets exactly what it asked for.
      resp = Handler.handle_request(req.(%{"limit" => 2}), TestServer, owner_conn("bob"))
      assert length(resp["result"]["tasks"]) == 2
    end

    test "tasks/list rejects a non-string status" do
      req = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/list",
        "params" => %{"status" => %{}}
      }

      resp = Handler.handle_request(req, TestServer, owner_conn("bob"))
      assert resp["error"]["code"] == Protocol.invalid_params()
    end
  end
end

defmodule ConduitMcp.TasksTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Tasks

  setup do
    if :ets.whereis(:conduit_mcp_tasks) != :undefined do
      :ets.delete_all_objects(:conduit_mcp_tasks)
    end

    :ok
  end

  describe "generate_id/0" do
    test "generates unique IDs" do
      id1 = Tasks.generate_id()
      id2 = Tasks.generate_id()
      assert id1 != id2
      assert is_binary(id1)
    end
  end

  describe "create/2" do
    test "creates a task with working status" do
      {:ok, task} = Tasks.create("task-1", %{"method" => "tools/call"})
      assert task["task_id"] == "task-1"
      assert task["status"] == "working"
      assert task["method"] == "tools/call"
      assert is_integer(task["created_at"])
    end
  end

  describe "get/1" do
    test "retrieves existing task" do
      Tasks.create("task-2")
      assert {:ok, task} = Tasks.get("task-2")
      assert task["task_id"] == "task-2"
    end

    test "returns error for missing task" do
      assert {:error, :not_found} = Tasks.get("nonexistent")
    end
  end

  describe "update/2" do
    test "updates task metadata" do
      Tasks.create("task-3")
      {:ok, updated} = Tasks.update("task-3", %{"status" => "completed", "result" => "done"})
      assert updated["status"] == "completed"
      assert updated["result"] == "done"
    end

    test "propagates :not_found from the store for an unknown id" do
      assert {:error, :not_found} = Tasks.update("missing", %{"status" => "completed"})
    end
  end

  describe "cancel/1" do
    test "cancels a task" do
      Tasks.create("task-4")
      {:ok, cancelled} = Tasks.cancel("task-4")
      assert cancelled["status"] == "cancelled"
    end

    test "propagates :not_found from the store for an unknown id" do
      assert {:error, :not_found} = Tasks.cancel("missing")
    end
  end

  describe "list/1" do
    test "lists all tasks" do
      Tasks.create("task-a")
      Tasks.create("task-b")
      tasks = Tasks.list()
      assert length(tasks) == 2
    end

    test "filters by status" do
      Tasks.create("task-c")
      Tasks.create("task-d")
      Tasks.update("task-d", %{"status" => "completed"})

      working = Tasks.list(status: :working)
      assert length(working) == 1
      assert hd(working)["task_id"] == "task-c"
    end

    test ":limit bounds the result, and :infinity means unbounded" do
      for i <- 1..5, do: Tasks.create("limit-#{i}")

      assert length(Tasks.list(limit: 2)) == 2
      assert length(Tasks.list(limit: 5)) == 5
      # More than exists: not an error, just everything.
      assert length(Tasks.list(limit: 50)) == 5

      # `:infinity` is this store's own convention for unbounded
      # (`:tasks_max_rows`), and it used to fall into the non-positive branch
      # and return [] for a caller asking for everything.
      assert length(Tasks.list(limit: :infinity)) == 5
      assert length(Tasks.list([])) == 5

      # Zero and negative genuinely mean nothing, without touching the table.
      assert Tasks.list(limit: 0) == []
      assert Tasks.list(limit: -1) == []
    end
  end

  describe "valid_transition?/2" do
    test "allows valid transitions" do
      assert Tasks.valid_transition?("working", "completed")
      assert Tasks.valid_transition?("working", "failed")
      assert Tasks.valid_transition?("working", "cancelled")
      assert Tasks.valid_transition?("working", "input_required")
      assert Tasks.valid_transition?("input_required", "working")
    end

    test "rejects invalid transitions" do
      refute Tasks.valid_transition?("completed", "working")
      refute Tasks.valid_transition?("failed", "working")
      refute Tasks.valid_transition?("cancelled", "working")
    end

    test "rejects unknown status strings without raising" do
      refute Tasks.valid_transition?("bogus", "working")
      refute Tasks.valid_transition?("working", "bogus")
      refute Tasks.valid_transition?("", "")
    end
  end

  # Relies on `async: false` (module-level): mutates the global
  # `:tasks_max_rows` app env and the shared ETS table. Keep this suite
  # synchronous or this test will flake.
  describe "create/2 row cap (W1)" do
    setup do
      prev = Application.get_env(:conduit_mcp, :tasks_max_rows)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:conduit_mcp, :tasks_max_rows),
          else: Application.put_env(:conduit_mcp, :tasks_max_rows, prev)
      end)

      :ok
    end

    test "returns {:error, :task_limit_reached} once the configured cap is hit" do
      Application.put_env(:conduit_mcp, :tasks_max_rows, 2)

      assert {:ok, _} = Tasks.create("cap-1")
      assert {:ok, _} = Tasks.create("cap-2")
      assert {:error, :task_limit_reached} = Tasks.create("cap-3")
    end
  end

  describe "delete/1" do
    test "removes an existing task" do
      Tasks.create("doomed")
      assert :ok = Tasks.delete("doomed")
      assert {:error, :not_found} = Tasks.get("doomed")
    end

    test "is a no-op for unknown ids" do
      assert :ok = Tasks.delete("never-existed")
    end
  end

  describe "cleanup/1" do
    test "prunes only terminal-state tasks older than ttl" do
      # Ensure the table exists before raw :ets.insert
      Tasks.create("__bootstrap__")
      Tasks.delete("__bootstrap__")

      old = System.system_time(:millisecond) - 60_000

      :ets.insert(
        :conduit_mcp_tasks,
        {"old-completed",
         %{"task_id" => "old-completed", "status" => "completed", "created_at" => old}}
      )

      :ets.insert(
        :conduit_mcp_tasks,
        {"old-failed", %{"task_id" => "old-failed", "status" => "failed", "created_at" => old}}
      )

      :ets.insert(
        :conduit_mcp_tasks,
        {"old-cancelled",
         %{"task_id" => "old-cancelled", "status" => "cancelled", "created_at" => old}}
      )

      :ets.insert(
        :conduit_mcp_tasks,
        {"old-working", %{"task_id" => "old-working", "status" => "working", "created_at" => old}}
      )

      Tasks.create("fresh-completed")
      Tasks.update("fresh-completed", %{"status" => "completed"})

      removed = Tasks.cleanup(30_000)

      assert removed == 3
      assert {:error, :not_found} = Tasks.get("old-completed")
      assert {:error, :not_found} = Tasks.get("old-failed")
      assert {:error, :not_found} = Tasks.get("old-cancelled")
      # working state is preserved regardless of age
      assert {:ok, _} = Tasks.get("old-working")
      # young terminal state is preserved
      assert {:ok, _} = Tasks.get("fresh-completed")
    end

    test "returns 0 when nothing to clean" do
      Tasks.create("just-made")
      assert Tasks.cleanup(60_000) == 0
    end
  end

  describe ":tasks_require_owner" do
    setup do
      previous = Application.get_env(:conduit_mcp, :tasks_require_owner)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:conduit_mcp, :tasks_require_owner)
          value -> Application.put_env(:conduit_mcp, :tasks_require_owner, value)
        end
      end)

      :ok
    end

    test "unowned rows become inaccessible through the scoped API" do
      {:ok, _} = Tasks.create("req-owned", %{}, "alice")
      {:ok, _} = Tasks.create("req-unowned", %{})

      # Default: unowned rows are readable by anyone.
      assert {:ok, _} = Tasks.get("req-unowned", "alice")
      assert {:ok, _} = Tasks.get("req-unowned", nil)

      Application.put_env(:conduit_mcp, :tasks_require_owner, true)

      assert {:error, :not_found} = Tasks.get("req-unowned", "alice")
      assert {:error, :not_found} = Tasks.get("req-unowned", nil)
      # The owner's own task is unaffected.
      assert {:ok, _} = Tasks.get("req-owned", "alice")
    end

    test "list/2 excludes unowned rows and returns nothing for a nil principal" do
      {:ok, _} = Tasks.create("req-l-owned", %{}, "alice")
      {:ok, _} = Tasks.create("req-l-unowned", %{})

      Application.put_env(:conduit_mcp, :tasks_require_owner, true)

      assert Tasks.list([], "alice") |> Enum.map(& &1["task_id"]) == ["req-l-owned"]
      assert Tasks.list([], nil) == []
    end

    test "cancel/2 refuses an unowned row" do
      {:ok, _} = Tasks.create("req-c", %{})
      Application.put_env(:conduit_mcp, :tasks_require_owner, true)

      assert {:error, :not_found} = Tasks.cancel("req-c", "alice")
      assert {:ok, %{"status" => "working"}} = Tasks.get("req-c")
    end
  end
end

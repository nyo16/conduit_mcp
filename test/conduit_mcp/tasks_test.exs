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
  end

  describe "cancel/1" do
    test "cancels a task" do
      Tasks.create("task-4")
      {:ok, cancelled} = Tasks.cancel("task-4")
      assert cancelled["status"] == "cancelled"
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
  end
end

defmodule ConduitMcp.Tasks.JanitorTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Tasks
  alias ConduitMcp.Tasks.Janitor

  setup do
    if :ets.whereis(:conduit_mcp_tasks) != :undefined do
      :ets.delete_all_objects(:conduit_mcp_tasks)
    end

    :ok
  end

  test "periodically removes terminal-state tasks beyond ttl and emits telemetry" do
    # Touch the API so the named table is created
    Tasks.create("__bootstrap__")
    Tasks.delete("__bootstrap__")

    old = System.system_time(:millisecond) - 60_000

    :ets.insert(
      :conduit_mcp_tasks,
      {"stale", %{"task_id" => "stale", "status" => "completed", "created_at" => old}}
    )

    Tasks.create("alive")

    :telemetry.attach(
      "tasks-janitor-#{System.unique_integer([:positive])}",
      [:conduit_mcp, :tasks, :cleanup],
      fn _e, m, _md, parent -> send(parent, {:tick, m}) end,
      self()
    )

    {:ok, pid} =
      Janitor.start_link(
        ttl: 1_000,
        interval: 50,
        name: :"tasks_janitor_#{System.unique_integer([:positive])}"
      )

    assert_receive {:tick, %{removed: 1}}, 500
    assert {:error, :not_found} = Tasks.get("stale")
    assert {:ok, _} = Tasks.get("alive")

    GenServer.stop(pid)
  end
end

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

  test "removes terminal-state tasks beyond ttl and emits telemetry" do
    # Touch the API so the named table is created
    Tasks.create("__bootstrap__")
    Tasks.delete("__bootstrap__")

    old = System.system_time(:millisecond) - 60_000

    :ets.insert(
      :conduit_mcp_tasks,
      {"stale", %{"task_id" => "stale", "status" => "completed", "created_at" => old}}
    )

    Tasks.create("alive")

    handler_id = "tasks-janitor-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      [:conduit_mcp, :tasks, :cleanup],
      fn _e, m, _md, parent -> send(parent, {:tick, m}) end,
      self()
    )

    # interval: 60_000 so the timer never fires on its own — the tick below is
    # the only one, and `:sys.get_state/1` blocks until it has been processed.
    # The previous version raced a 50 ms timer against a 500 ms assert_receive
    # and assumed the *first* observed tick was the one that removed the row.
    {:ok, pid} =
      Janitor.start_link(
        ttl: 1_000,
        interval: 60_000,
        name: :"tasks_janitor_#{System.unique_integer([:positive])}"
      )

    send(pid, :cleanup)
    _ = :sys.get_state(pid)

    assert_received {:tick, %{removed: 1}}
    assert {:error, :not_found} = Tasks.get("stale")
    assert {:ok, _} = Tasks.get("alive")

    GenServer.stop(pid)
  end
end

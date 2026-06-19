defmodule ConduitMcp.Tasks.StoreDispatchTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Tasks

  defmodule MockStore do
    @behaviour ConduitMcp.Tasks.Store

    # start_link so the agent is linked to the (per-test) test process and is
    # torn down automatically when the test ends — no stale state can leak
    # into the next test's `calls()` assertions.
    def start_link, do: Agent.start_link(fn -> %{calls: [], tasks: %{}} end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

    defp record(call),
      do: Agent.update(__MODULE__, fn s -> %{s | calls: [call | s.calls]} end)

    @impl true
    def create(task_id, metadata) do
      record({:create, task_id, metadata})
      task = Map.merge(metadata, %{"task_id" => task_id, "status" => "working"})
      Agent.update(__MODULE__, fn s -> %{s | tasks: Map.put(s.tasks, task_id, task)} end)
      {:ok, task}
    end

    @impl true
    def get(task_id) do
      record({:get, task_id})

      case Agent.get(__MODULE__, & &1.tasks[task_id]) do
        nil -> {:error, :not_found}
        task -> {:ok, task}
      end
    end

    @impl true
    def update(task_id, updates) do
      record({:update, task_id, updates})

      Agent.get_and_update(__MODULE__, fn s ->
        case s.tasks[task_id] do
          nil ->
            {{:error, :not_found}, s}

          existing ->
            new = Map.merge(existing, updates)
            {{:ok, new}, %{s | tasks: Map.put(s.tasks, task_id, new)}}
        end
      end)
    end

    @impl true
    def cancel(task_id) do
      record({:cancel, task_id})
      update(task_id, %{"status" => "cancelled", "cancelled_by_store" => true})
    end

    @impl true
    def delete(task_id) do
      record({:delete, task_id})
      Agent.update(__MODULE__, fn s -> %{s | tasks: Map.delete(s.tasks, task_id)} end)
      :ok
    end

    @impl true
    def list(opts) do
      record({:list, opts})
      Agent.get(__MODULE__, & &1.tasks) |> Map.values()
    end

    @impl true
    def cleanup(ttl_ms) do
      record({:cleanup, ttl_ms})
      0
    end
  end

  defmodule MinimalStore do
    # Implements only the required callbacks; relies on optional fallbacks
    # for cancel/1 and cleanup/1.
    @behaviour ConduitMcp.Tasks.Store

    @impl true
    def create(_, _), do: {:ok, %{"task_id" => "x", "status" => "working"}}
    @impl true
    def get(_), do: {:error, :not_found}
    @impl true
    def update(task_id, updates) do
      {:ok, Map.merge(updates, %{"task_id" => task_id, "from" => :minimal})}
    end

    @impl true
    def delete(_), do: :ok
    @impl true
    def list(_), do: []
  end

  setup do
    prev = Application.get_env(:conduit_mcp, :tasks_store)

    on_exit(fn ->
      if is_nil(prev) do
        Application.delete_env(:conduit_mcp, :tasks_store)
      else
        Application.put_env(:conduit_mcp, :tasks_store, prev)
      end
    end)

    :ok
  end

  describe "default store" do
    test "falls back to EtsStore when nothing configured" do
      Application.delete_env(:conduit_mcp, :tasks_store)
      assert Tasks.store() == ConduitMcp.Tasks.EtsStore
    end
  end

  describe "dispatch to configured store" do
    setup do
      start_supervised!(%{id: MockStore, start: {MockStore, :start_link, []}})
      Application.put_env(:conduit_mcp, :tasks_store, MockStore)
      :ok
    end

    test "create/2 dispatches" do
      assert {:ok, task} = Tasks.create("t1", %{"tool" => "x"})
      assert task["task_id"] == "t1"
      assert {:create, "t1", %{"tool" => "x"}} in MockStore.calls()
    end

    test "get/1 dispatches" do
      Tasks.create("t2")
      Tasks.get("t2")
      assert {:get, "t2"} in MockStore.calls()
    end

    test "update/2 dispatches" do
      Tasks.create("t3")
      {:ok, updated} = Tasks.update("t3", %{"status" => "completed"})
      assert updated["status"] == "completed"
      assert {:update, "t3", %{"status" => "completed"}} in MockStore.calls()
    end

    test "cancel/1 dispatches to store cancel callback when implemented" do
      Tasks.create("t4")
      {:ok, cancelled} = Tasks.cancel("t4")
      assert cancelled["status"] == "cancelled"
      assert cancelled["cancelled_by_store"] == true
      assert {:cancel, "t4"} in MockStore.calls()
    end

    test "delete/1 dispatches" do
      Tasks.delete("t5")
      assert {:delete, "t5"} in MockStore.calls()
    end

    test "list/1 dispatches" do
      Tasks.list(status: :working)
      assert {:list, [status: :working]} in MockStore.calls()
    end

    test "cleanup/1 dispatches" do
      Tasks.cleanup(60_000)
      assert {:cleanup, 60_000} in MockStore.calls()
    end
  end

  describe "optional-callback fallbacks" do
    setup do
      # No on_exit here: the module-level setup already snapshots and restores
      # :tasks_store after every test. A second restore here was redundant (and
      # misleading — it captured whatever the outer setup left, not the original).
      Application.put_env(:conduit_mcp, :tasks_store, MinimalStore)
      :ok
    end

    test "cancel/1 falls back to update/2 when not implemented" do
      {:ok, result} = Tasks.cancel("any-id")
      assert result["status"] == "cancelled"
      assert result["from"] == :minimal
    end

    test "cleanup/1 returns 0 when not implemented" do
      assert Tasks.cleanup(60_000) == 0
    end
  end
end

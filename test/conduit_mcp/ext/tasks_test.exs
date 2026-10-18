defmodule ConduitMcp.Ext.TasksTest do
  # async: false — toggles the global :ext_tasks application env and shares
  # the named ETS table.
  use ExUnit.Case, async: false

  alias ConduitMcp.Ext.Tasks
  alias ConduitMcp.Ext.Tasks.EtsStore
  alias ConduitMcp.Subscriptions

  defmodule Notifier do
    @behaviour ConduitMcp.Ext.Tasks.Notifier

    @impl true
    def task_changed(task), do: send(Process.whereis(:ext_tasks_notifier_test), {:changed, task})
  end

  setup do
    previous = Application.fetch_env(:conduit_mcp, :ext_tasks)
    Application.put_env(:conduit_mcp, :ext_tasks, true)
    start_supervised!(EtsStore.Owner)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:conduit_mcp, :ext_tasks, value)
        :error -> Application.delete_env(:conduit_mcp, :ext_tasks)
      end
    end)
  end

  describe "config" do
    test "validate_config!/1 normalizes and rejects bad values naming the key" do
      assert Tasks.validate_config!(false) == false
      assert Tasks.validate_config!(nil) == false
      assert Tasks.validate_config!(true) == []
      opts = [store: EtsStore, janitor: [interval: 10], max_rows: 5, notifier: Notifier]
      assert Tasks.validate_config!(opts) == opts

      for bad <- [:yes, [store: "x"], [max_rows: 0], [janitor: :sometimes], [bogus: 1], [:a]] do
        assert_raise ArgumentError, ~r/:ext_tasks/, fn -> Tasks.validate_config!(bad) end
      end
    end

    test "the application starts the owner and janitor only when enabled" do
      Application.put_env(:conduit_mcp, :ext_tasks, false)
      assert ConduitMcp.Application.ext_tasks_children() == []

      Application.put_env(:conduit_mcp, :ext_tasks, true)

      assert [EtsStore.Owner, %{id: Tasks.Janitor, start: {_, _, [janitor_opts]}}] =
               ConduitMcp.Application.ext_tasks_children()

      assert janitor_opts[:store] == EtsStore
      assert janitor_opts[:telemetry_event] == [:conduit_mcp, :ext_tasks, :cleanup]

      Application.put_env(:conduit_mcp, :ext_tasks, store: __MODULE__, janitor: false)
      assert ConduitMcp.Application.ext_tasks_children() == []

      Application.put_env(:conduit_mcp, :ext_tasks, janitor: [ttl: 5])
      assert [_owner, %{start: {_, _, [opts]}}] = ConduitMcp.Application.ext_tasks_children()
      assert opts[:ttl] == 5

      Application.put_env(:conduit_mcp, :ext_tasks, :on)
      assert_raise ArgumentError, fn -> ConduitMcp.Application.ext_tasks_children() end
    end
  end

  describe "EtsStore" do
    test "owner scoping on every client-facing op" do
      {:ok, task} = Tasks.create("alice", [])

      assert {:ok, _} = EtsStore.get(task.task_id, "alice")
      assert {:error, :not_found} = EtsStore.get(task.task_id, "bob")
      assert {:error, :not_found} = EtsStore.get(task.task_id, nil)
      assert {:error, :not_found} = EtsStore.cancel(task.task_id, "bob")
      assert {:error, :not_found} = EtsStore.update(task.task_id, "bob", &{:ok, &1})
      assert {:ok, %{status: "working"}} = Tasks.status(task.task_id)
    end

    test "the row cap rejects new tasks" do
      Application.put_env(:conduit_mcp, :ext_tasks, max_rows: 1)
      :ets.delete_all_objects(:conduit_mcp_ext_tasks)

      assert {:ok, _} = Tasks.create(nil, [])
      assert {:error, :task_limit_reached} = Tasks.create(nil, [])
    end

    test "update/3 is a compare-and-swap: a concurrent writer is not overwritten" do
      {:ok, task} = Tasks.create(nil, [])
      parent = self()

      # The update function completes the task underneath itself the first
      # time it runs, so its own write must lose the swap and retry against
      # the completed record.
      {:ok, _} =
        EtsStore.update(task.task_id, nil, fn record ->
          if record.status == "working" do
            :ok = Tasks.complete(task.task_id, %{"content" => []})
            send(parent, :raced)
          end

          {:ok, %{record | status_message: "seen #{record.status}"}}
        end)

      assert_received :raced

      assert {:ok, %{status: "completed", status_message: "seen completed"}} =
               Tasks.status(task.task_id)
    end

    test "cleanup/2 expires by ttl_ms from creation, and terminal untimed tasks by the default" do
      :ets.delete_all_objects(:conduit_mcp_ext_tasks)
      {:ok, short} = Tasks.create(nil, ttl_ms: 1_000)
      {:ok, long} = Tasks.create(nil, ttl_ms: 10_000)
      {:ok, untimed} = Tasks.create(nil, ttl_ms: nil)
      {:ok, untimed_done} = Tasks.create(nil, ttl_ms: nil)
      :ok = Tasks.complete(untimed_done.task_id, %{"content" => []})

      # The four tasks need not share a `created_at`: the clock can tick
      # between creates. `t0` is the first's, `t1` the last's; the bounds hold
      # for any gap under a second.
      t0 = short.created_at
      t1 = untimed_done.created_at

      assert EtsStore.cleanup(5_000, t0 + 999) == 0
      # short: ttl 1 000 elapsed; untimed_done: terminal, 5 000 default elapsed.
      assert EtsStore.cleanup(5_000, t1 + 5_000) == 2
      assert {:error, :not_found} = Tasks.status(short.task_id)
      assert {:error, :not_found} = Tasks.status(untimed_done.task_id)
      assert {:ok, _} = Tasks.status(long.task_id)
      assert {:ok, _} = Tasks.status(untimed.task_id)

      assert EtsStore.cleanup(5_000, t1 + 1_000_000) == 1
      assert {:ok, _} = Tasks.status(untimed.task_id)
    end

    test "the janitor sweeps the store and emits [:conduit_mcp, :ext_tasks, :cleanup]" do
      :ets.delete_all_objects(:conduit_mcp_ext_tasks)
      {:ok, task} = Tasks.create(nil, ttl_ms: 0)

      # Emitted from the janitor process, so not via TelemetryTestHelper
      # (which forwards only the attaching process's own emissions).
      test_pid = self()
      handler = "ext-tasks-janitor-test"

      :ok =
        :telemetry.attach(
          handler,
          [:conduit_mcp, :ext_tasks, :cleanup],
          fn event, measurements, metadata, _ ->
            send(test_pid, {event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      pid =
        start_supervised!(
          {ConduitMcp.Session.Janitor,
           store: EtsStore,
           name: :ext_tasks_janitor_test,
           telemetry_event: [:conduit_mcp, :ext_tasks, :cleanup],
           interval: :timer.hours(1)}
        )

      send(pid, :cleanup)

      assert_receive {[:conduit_mcp, :ext_tasks, :cleanup], %{removed: 1}, %{store: EtsStore}}

      assert {:error, :not_found} = Tasks.status(task.task_id)
    end
  end

  describe "worker API" do
    test "ids are 32 random url-safe bytes" do
      id = Tasks.new_id()
      refute id =~ "="
      assert {:ok, bytes} = Base.url_decode64(id, padding: false)
      assert byte_size(bytes) == 32
      refute Tasks.new_id() == id
    end

    test "progress keeps the status; terminal tasks refuse every change" do
      {:ok, task} = Tasks.create(nil, [])
      assert :ok = Tasks.progress(task.task_id, "Half way")
      assert {:ok, %{status: "working", status_message: "Half way"}} = Tasks.status(task.task_id)

      :ok =
        Tasks.fail(task.task_id, %{"code" => -32_000, "message" => "x", "data" => %{"n" => 1}})

      assert {:error, :terminal} = Tasks.progress(task.task_id, "again")
      assert {:error, :terminal} = Tasks.fail(task.task_id, {-1, "y"})

      assert {:error, :terminal} =
               Tasks.require_input(task.task_id, %{"k" => %{"method" => "roots/list"}})

      assert {:ok, %{error: %{"code" => -32_000, "data" => %{"n" => 1}}}} =
               Tasks.status(task.task_id)

      assert {:error, :not_found} = Tasks.complete(Tasks.new_id(), %{})
    end

    test "require_input/3 rejects malformed input requests" do
      {:ok, task} = Tasks.create(nil, [])
      assert {:error, :invalid_input_requests} = Tasks.require_input(task.task_id, %{})

      assert {:error, :invalid_input_requests} =
               Tasks.require_input(task.task_id, %{"k" => %{"method" => "ping"}})
    end

    test "the configured notifier sees every change, and a raising one is contained" do
      Process.register(self(), :ext_tasks_notifier_test)
      Application.put_env(:conduit_mcp, :ext_tasks, notifier: Notifier)

      {:ok, task} = Tasks.create("alice", [])
      assert_received {:changed, %{status: "working", owner: "alice"}}

      :ok = Tasks.complete(task.task_id, %{"content" => []})
      assert_received {:changed, %{status: "completed"}}

      Process.unregister(:ext_tasks_notifier_test)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Tasks.create(nil, [])
        end)

      assert log =~ "notifier raised"
    end
  end

  # Subscribes this process as a listen stream of `principal` to `task_id`.
  defp listen_as(principal, task_id) do
    ref = make_ref()
    :ok = Subscriptions.subscribe([Subscriptions.task_topic(principal, task_id)], ref)
    ref
  end

  describe "ListenNotifier (the default notifier)" do
    test "publishes notifications/tasks, the full task state, to the owner's streams only" do
      {:ok, task} = Tasks.create("alice", [])
      alice = listen_as("alice", task.task_id)
      bob = listen_as("bob", task.task_id)
      anonymous = listen_as(nil, task.task_id)

      :ok = Tasks.progress(task.task_id, "Halfway")
      {:ok, record} = Tasks.status(task.task_id)

      assert_receive {Subscriptions, ^alice, notification}

      assert notification == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/tasks",
               "params" => Tasks.to_wire(record)
             }

      refute_receive {Subscriptions, ^bob, _}, 50
      refute_receive {Subscriptions, ^anonymous, _}, 0
    end

    test "a task owned by nil reaches only unauthenticated streams" do
      {:ok, task} = Tasks.create(nil, [])
      anonymous = listen_as(nil, task.task_id)
      alice = listen_as("alice", task.task_id)

      :ok = Tasks.complete(task.task_id, %{"content" => []})

      assert_receive {Subscriptions, ^anonymous, %{"params" => %{"status" => "completed"}}}
      refute_receive {Subscriptions, ^alice, _}, 50
    end

    test "notifier: nil turns notifications off" do
      Application.put_env(:conduit_mcp, :ext_tasks, notifier: nil)
      {:ok, task} = Tasks.create(nil, [])
      ref = listen_as(nil, task.task_id)

      :ok = Tasks.progress(task.task_id, "Halfway")
      refute_receive {Subscriptions, ^ref, _}, 50
    end
  end
end

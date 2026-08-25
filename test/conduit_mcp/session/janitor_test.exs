defmodule ConduitMcp.Session.JanitorTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Session.{EtsStore, Janitor}

  setup do
    if :ets.whereis(:conduit_mcp_sessions) != :undefined do
      :ets.delete_all_objects(:conduit_mcp_sessions)
    end

    :ok
  end

  describe "start_link/1" do
    test "starts under a supervisor with required :store option" do
      assert {:ok, pid} =
               Janitor.start_link(
                 store: EtsStore,
                 ttl: 60_000,
                 interval: 60_000,
                 name: :"janitor_test_#{System.unique_integer([:positive])}"
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "raises when :store is missing" do
      assert_raise KeyError, fn -> Janitor.init([]) end
    end
  end

  describe "cleanup loop" do
    test "evicts sessions older than ttl on tick" do
      EtsStore.create("fresh", %{"protocol_version" => "2025-11-25"})

      # Backdate one session beyond the ttl threshold
      stale_created_at = System.system_time(:millisecond) - 60_000
      :ets.insert(:conduit_mcp_sessions, {"stale", %{"created_at" => stale_created_at}})

      handler_id = "janitor-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :session, :cleanup],
        fn _event, measurements, metadata, parent ->
          send(parent, {:cleanup_ran, measurements, metadata})
        end,
        self()
      )

      # interval: 60_000 so the periodic timer never fires; the tick below is
      # the only one, and `:sys.get_state/1` is the barrier that guarantees it
      # has been processed. Uses the same idiom as the test 60 lines down —
      # this one used to race a 50 ms timer against a 500 ms assert_receive.
      {:ok, pid} =
        Janitor.start_link(
          store: EtsStore,
          ttl: 1_000,
          interval: 60_000,
          name: :"janitor_test_#{System.unique_integer([:positive])}"
        )

      send(pid, :cleanup)
      _ = :sys.get_state(pid)

      assert_received {:cleanup_ran, %{removed: 1}, %{store: EtsStore}}
      assert :ets.lookup(:conduit_mcp_sessions, "stale") == []
      assert match?([{"fresh", _}], :ets.lookup(:conduit_mcp_sessions, "fresh"))

      GenServer.stop(pid)
    end
  end

  describe "store without cleanup/1" do
    defmodule NoCleanupStore do
      @behaviour ConduitMcp.Session.Store
      def create(_, _), do: :ok
      def get(_), do: {:error, :not_found}
      def delete(_), do: :ok
      def update(_, _), do: :ok
    end

    test "does not crash and emits no cleanup telemetry" do
      handler_id = "janitor-noop-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :session, :cleanup],
        fn _event, _m, _md, parent -> send(parent, :unexpected_cleanup) end,
        self()
      )

      # Large interval so the auto-scheduled tick can't fire during the test —
      # we drive exactly one cleanup ourselves for a deterministic assertion
      # (no reliance on a refute_receive timing window vs. the tick interval).
      {:ok, pid} =
        Janitor.start_link(
          store: NoCleanupStore,
          ttl: 1_000,
          interval: 60_000,
          name: :"janitor_test_#{System.unique_integer([:positive])}"
        )

      # Force one cleanup pass, then :sys.get_state blocks until the GenServer
      # has processed it — so any cleanup telemetry would already be in our
      # mailbox before the (non-blocking) refute_received check.
      send(pid, :cleanup)
      _ = :sys.get_state(pid)

      refute_received :unexpected_cleanup
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe ":telemetry_event and :noun" do
    test "the configured event is emitted instead of the session default" do
      # ConduitMcp.Application reuses this janitor for the cancellation table.
      # Without these options a consumer's [:conduit_mcp, :session, :cleanup]
      # handler would receive cancellation evictions as session evictions once a
      # minute, and Cancellation.cleanup/1's own
      # [:conduit_mcp, :cancellation, :cleanup] would publish the same count
      # under a second name.
      event = [:conduit_mcp, :janitor_test, :"e#{System.unique_integer([:positive])}"]
      handler_id = "janitor-event-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, _ ->
          send(parent, {:event, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A row already past its TTL, so the sweep has something to report and
      # the measurement is non-zero. Rows are `{session_id, metadata}` with the
      # timestamp inside the map, so backdate the map.
      :ets.delete_all_objects(:conduit_mcp_sessions)
      EtsStore.create("stale", %{})
      [{"stale", metadata}] = :ets.lookup(:conduit_mcp_sessions, "stale")

      :ets.insert(
        :conduit_mcp_sessions,
        {"stale", Map.put(metadata, "created_at", System.system_time(:millisecond) - 60_000)}
      )

      {:ok, pid} =
        Janitor.start_link(
          store: EtsStore,
          ttl: 1_000,
          # Never fires on its own; the tick below is the only one.
          interval: 60_000,
          telemetry_event: event,
          noun: "expired widgets",
          name: :"janitor_event_#{System.unique_integer([:positive])}"
        )

      send(pid, :cleanup)
      :sys.get_state(pid)

      assert_receive {:event, ^event, %{removed: 1}, %{store: EtsStore}}

      GenServer.stop(pid)
    end

    test "an unloaded store module still gets swept" do
      # `function_exported?/3` is false for a module that is merely not loaded,
      # which under interactive code loading (dev, test, `mix run`, any release
      # not built with `:embedded`) is the normal state at boot. Without
      # `Code.ensure_loaded?/1` the janitor warns once and then skips the sweep
      # on every tick for the life of the node, leaving the table it was added
      # to bound growing unbounded — discovered as an OOM, not as a failure.
      #
      # Asserting the row is actually gone, not just that no warning appeared:
      # the absence of a log line does not prove a sweep happened.
      ConduitMcp.Cancellation.cancel("stale-unloaded", nil, "s")
      assert ConduitMcp.Cancellation.cancelled?("stale-unloaded", "s")

      :ets.insert(
        :conduit_mcp_cancellations,
        {{"s", "stale-unloaded"},
         %{"reason" => nil, "cancelled_at" => System.system_time(:millisecond) - 60_000}}
      )

      :code.purge(ConduitMcp.Cancellation)
      :code.delete(ConduitMcp.Cancellation)
      refute :erlang.function_exported(ConduitMcp.Cancellation, :cleanup, 1)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} =
            Janitor.start_link(
              store: ConduitMcp.Cancellation,
              ttl: 1_000,
              interval: 60_000,
              name: :"janitor_load_#{System.unique_integer([:positive])}"
            )

          send(pid, :cleanup)
          :sys.get_state(pid)
          GenServer.stop(pid)
        end)

      refute log =~ "does not implement"
      refute ConduitMcp.Cancellation.cancelled?("stale-unloaded", "s")
    end
  end
end

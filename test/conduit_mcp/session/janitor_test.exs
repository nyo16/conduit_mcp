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

      :telemetry.attach(
        "janitor-test-#{System.unique_integer([:positive])}",
        [:conduit_mcp, :session, :cleanup],
        fn _event, measurements, metadata, parent ->
          send(parent, {:cleanup_ran, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        Janitor.start_link(
          store: EtsStore,
          ttl: 1_000,
          interval: 50,
          name: :"janitor_test_#{System.unique_integer([:positive])}"
        )

      assert_receive {:cleanup_ran, %{removed: removed}, %{store: EtsStore}}, 500

      assert removed == 1
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
      :telemetry.attach(
        "janitor-noop-#{System.unique_integer([:positive])}",
        [:conduit_mcp, :session, :cleanup],
        fn _event, _m, _md, parent -> send(parent, :unexpected_cleanup) end,
        self()
      )

      {:ok, pid} =
        Janitor.start_link(
          store: NoCleanupStore,
          ttl: 1_000,
          interval: 50,
          name: :"janitor_test_#{System.unique_integer([:positive])}"
        )

      refute_receive :unexpected_cleanup, 200
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end

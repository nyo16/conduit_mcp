defmodule ConduitMcp.CancellationTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Cancellation

  setup do
    if :ets.whereis(:conduit_mcp_cancellations) != :undefined do
      :ets.delete_all_objects(:conduit_mcp_cancellations)
    end

    :ok
  end

  describe "cancel/2 + cancelled?/1" do
    test "records cancellation by id (string or integer)" do
      Cancellation.cancel(42, "user pressed stop")
      assert Cancellation.cancelled?(42)
      assert Cancellation.cancelled?("42")
    end

    test "stores reason and exposes it via reason/1" do
      Cancellation.cancel("req-1", "timeout")
      assert Cancellation.reason("req-1") == "timeout"
    end

    test "no-ops on nil id" do
      assert :ok = Cancellation.cancel(nil)
      refute Cancellation.cancelled?(nil)
    end
  end

  describe "cancelled?/1 with Plug.Conn" do
    test "uses :mcp_request_id from assigns" do
      Cancellation.cancel("conn-1")
      conn = %Plug.Conn{assigns: %{mcp_request_id: "conn-1"}}
      assert Cancellation.cancelled?(conn)
    end

    test "returns false when conn has no request id" do
      refute Cancellation.cancelled?(%Plug.Conn{})
    end
  end

  describe "clear/1" do
    test "removes a cancellation entry" do
      Cancellation.cancel("req-2")
      assert Cancellation.cancelled?("req-2")
      Cancellation.clear("req-2")
      refute Cancellation.cancelled?("req-2")
    end

    test "no-ops on nil" do
      assert :ok = Cancellation.clear(nil)
    end
  end

  describe "cleanup/1" do
    test "removes entries older than ttl_ms" do
      Cancellation.cancel("fresh")

      stale_at = System.system_time(:millisecond) - 60_000

      :ets.insert(
        :conduit_mcp_cancellations,
        {"stale", %{"reason" => nil, "cancelled_at" => stale_at}}
      )

      removed = Cancellation.cleanup(30_000)

      assert removed == 1
      assert Cancellation.cancelled?("fresh")
      refute Cancellation.cancelled?("stale")
    end
  end

  describe "telemetry" do
    test "emits [:conduit_mcp, :request, :cancelled] on cancel" do
      handler_id = "cancel-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :request, :cancelled],
        fn _event, m, md, parent -> send(parent, {:cancelled, m, md}) end,
        self()
      )

      Cancellation.cancel("evt-1", "client abort")
      assert_receive {:cancelled, %{count: 1}, %{request_id: "evt-1", reason: "client abort"}}
    end

    test "emits [:conduit_mcp, :cancellation, :cleanup] with the removed count" do
      handler_id = "cleanup-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :cancellation, :cleanup],
        fn _event, m, _md, parent -> send(parent, {:cleanup, m}) end,
        self()
      )

      stale_at = System.system_time(:millisecond) - 60_000

      :ets.insert(
        :conduit_mcp_cancellations,
        {"stale-evt", %{"reason" => nil, "cancelled_at" => stale_at}}
      )

      assert Cancellation.cleanup(30_000) == 1
      assert_receive {:cleanup, %{removed: 1}}
    end
  end
end

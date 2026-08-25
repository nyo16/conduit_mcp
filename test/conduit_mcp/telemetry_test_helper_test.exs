defmodule ConduitMcp.TelemetryTestHelperTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.TelemetryTestHelper

  @event [:conduit_mcp, :test_helper_probe, :stop]

  describe "attach_event_handlers/2 emitter scoping" do
    test "forwards events emitted by the attaching process" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@event])

      :telemetry.execute(@event, %{duration: 1}, %{source: :self})

      assert_receive {@event, ^ref, %{duration: 1}, %{source: :self}}
    end

    test "does not forward events emitted by another process" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@event])

      task =
        Task.async(fn ->
          :telemetry.execute(@event, %{duration: 2}, %{source: :task})
        end)

      Task.await(task)

      refute_receive {@event, ^ref, _measurements, %{source: :task}}
    end

    test "a concurrent emitter does not satisfy another handler's assertion" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@event])

      task =
        Task.async(fn ->
          # Same event name, different process, while the handler above is attached.
          :telemetry.execute(@event, %{duration: 3}, %{source: :other_test})
          :telemetry.execute(@event, %{duration: 4}, %{source: :other_test})
        end)

      Task.await(task)

      refute_receive {@event, ^ref, _measurements, _metadata}

      # The attaching process's own emission still arrives.
      :telemetry.execute(@event, %{duration: 5}, %{source: :self})
      assert_receive {@event, ^ref, %{duration: 5}, %{source: :self}}
    end
  end

  describe "detach/1" do
    test "stops forwarding" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [@event])
      assert :ok = TelemetryTestHelper.detach(ref)

      :telemetry.execute(@event, %{duration: 6}, %{source: :self})

      refute_receive {@event, ^ref, _measurements, _metadata}
    end
  end
end

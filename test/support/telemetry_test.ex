defmodule ConduitMcp.TelemetryTestHelper do
  @moduledoc """
  Helper module for testing telemetry events.
  """

  def attach_event_handlers(pid, events) do
    ref = make_ref()

    for event <- events do
      handler_id = "test-handler-#{:erlang.phash2(ref)}-#{Enum.join(event, "-")}"

      :telemetry.attach(
        handler_id,
        event,
        fn event_name, measurements, metadata, _config ->
          send(pid, {event_name, ref, measurements, metadata})
        end,
        nil
      )
    end

    ref
  end

  def detach(_ref) do
    # We don't need to detach since each test is isolated
    :ok
  end
end

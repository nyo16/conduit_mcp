defmodule ConduitMcp.TelemetryTestHelper do
  @moduledoc """
  Helper module for testing telemetry events.

  `attach_event_handlers/2` attaches handlers to the global `:telemetry`
  table for the given events and automatically registers an
  `ExUnit.Callbacks.on_exit/1` callback so the handlers are detached
  when the test finishes.

  Without detach, every attached handler fires for every subsequent
  matching event in the suite (and tries to `send/2` into a now-dead
  pid), accumulating wasted work and noise across the run.

  `detach/1` remains as an explicit cleanup hook for tests that don't
  want to rely on `on_exit` ordering.
  """

  @pdict_key {__MODULE__, :handler_ids}

  def attach_event_handlers(pid, events) do
    ref = make_ref()

    handler_ids =
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

        handler_id
      end

    existing = Process.get(@pdict_key, %{})
    Process.put(@pdict_key, Map.put(existing, ref, handler_ids))

    if function_exported?(ExUnit.Callbacks, :on_exit, 1) do
      try do
        ExUnit.Callbacks.on_exit(fn -> Enum.each(handler_ids, &:telemetry.detach/1) end)
      rescue
        # Outside a test process — caller is responsible for detach.
        _ -> :ok
      end
    end

    ref
  end

  def detach(ref) do
    existing = Process.get(@pdict_key, %{})
    {ids, remaining} = Map.pop(existing, ref, [])
    Enum.each(ids, &:telemetry.detach/1)
    Process.put(@pdict_key, remaining)
    :ok
  end
end

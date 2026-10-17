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

  ## Emitter scoping

  `:telemetry` handlers are global: while attached, a handler runs for
  *every* emission of that event name anywhere in the VM, including
  concurrent `async: true` tests. Handlers execute inline in the
  emitting process, so the attaching process is captured at attach time
  and an event is forwarded only when it was emitted by that process.
  Without this filter a concurrent test's emission satisfies another
  test's `assert_receive`, and every telemetry assertion in the suite is
  unsound.

  This means events emitted from a process other than the caller of
  `attach_event_handlers/2` are *not* forwarded. Tests asserting on
  events emitted from a spawned process must attach from that process,
  or filter on a correlation value in the metadata instead.

  `detach/1` remains as an explicit cleanup hook for tests that don't
  want to rely on `on_exit` ordering.
  """

  @pdict_key {__MODULE__, :handler_ids}

  @doc """
  Attaches forwarding handlers for `events`, sending matches to `pid`.

  Only emissions originating in the calling process are forwarded.
  Returns a `ref` that tags every forwarded message and identifies the
  handler set for `detach/1`.
  """
  def attach_event_handlers(pid, events) do
    ref = make_ref()
    emitter = self()

    # `System.unique_integer/1`, not `:erlang.phash2(ref)`: phash2 is a 27-bit
    # hash, and a collision between two live handler sets makes
    # `:telemetry.attach/4` return `{:error, :already_exists}`, which the `:ok
    # =` below turns into a MatchError reported against whichever test lost the
    # race - an order-dependent failure in the module whose whole job is making
    # telemetry assertions trustworthy.
    id = System.unique_integer([:positive])

    handler_ids =
      for event <- events do
        handler_id = "test-handler-#{id}-#{Enum.join(event, "-")}"

        :ok =
          :telemetry.attach(
            handler_id,
            event,
            fn event_name, measurements, metadata, _config ->
              # Runs inline in the emitting process.
              if self() == emitter do
                send(pid, {event_name, ref, measurements, metadata})
              end

              :ok
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

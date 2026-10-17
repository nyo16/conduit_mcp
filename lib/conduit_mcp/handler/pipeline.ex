defmodule ConduitMcp.Handler.Pipeline do
  @moduledoc false

  # The request wrapper shared by every protocol era. Each step is a small
  # function taking a continuation, so an era-specific handler composes them
  # around its own routing:
  #
  #     instrument(request, server_module, ctx, fn ->
  #       in_flight(conn, id, fn conn ->
  #         guard(method, id, fn -> route(...) end)
  #       end)
  #     end)

  require Logger

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Errors

  @doc """
  Runs `fun` and emits `[:conduit_mcp, :request, :stop]` for it.

  Wraps everything, notifications included. `fun` returns the transport-level
  reply: a response map, or `:ok` for a notification; any map with an
  `"error"` member counts as `status: :error`.

  The metadata copies individual, already-validated fields of `ctx` (`era`,
  `protocol_version` and the trace-context keys) — never the `Ctx` itself,
  which carries the conn and the principal.
  """
  @spec instrument(map(), module(), ConduitMcp.Ctx.t(), (-> reply)) :: reply
        when reply: map() | :ok
  def instrument(request, server_module, ctx, fun) do
    start_time = System.monotonic_time()

    result = fun.()

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :request, :stop],
      %{duration: duration},
      %{
        method: telemetry_text(Map.get(request, "method")),
        server_module: server_module,
        status: if(match?(%{"error" => _}, result), do: :error, else: :ok),
        era: ctx.era,
        protocol_version: ctx.version,
        traceparent: ctx.traceparent,
        tracestate: ctx.tracestate,
        baggage: ctx.baggage
      }
    )

    result
  end

  @doc """
  Runs `fun` with the request marked in flight.

  Stashes `id` into `conn.assigns[:mcp_request_id]` (so tools can poll
  `ConduitMcp.Cancellation.cancelled?/1`), tracks the request with
  `ConduitMcp.Cancellation.track/2`, and untracks it and clears any
  cancellation flag once `fun` returns or raises.
  """
  @spec in_flight(Plug.Conn.t() | map(), term(), (Plug.Conn.t() -> result)) :: result
        when result: term()
  def in_flight(conn, id, fun) do
    conn = Plug.Conn.assign(conn, :mcp_request_id, id)
    scope = Cancellation.scope(conn)

    Cancellation.track(id, scope)

    try do
      fun.(conn)
    after
      Cancellation.untrack(id, scope)
      Cancellation.clear(id, scope)
    end
  end

  @doc """
  Runs `fun`, turning any exception into a logged internal error.

  Wraps routing *and* method execution: a raising callback yields `-32603`,
  and the per-method telemetry event for that call is not emitted.
  """
  @spec guard(term(), term(), (-> ConduitMcp.Handler.result())) :: ConduitMcp.Handler.result()
  def guard(method, id, fun) do
    fun.()
  rescue
    error ->
      Logger.error("Error handling method",
        error: Exception.message(error),
        method: ConduitMcp.Reflect.text(method),
        request_id: id
      )

      {:error, Errors.internal_error(), "Internal server error", nil}
  end

  # Telemetry metadata documents these fields as `String.t() | nil`. They come
  # from the client's JSON body, so a map, list or number is possible once the
  # request is past the checks that used to raise on it (resources/read with
  # `"uri": {}` now returns -32602 and still emits). Passing it through would
  # break every handler written against the documented type - including
  # `ConduitMcp.Telemetry`'s default logger, which `:telemetry` then detaches.
  @doc """
  Returns `value` when it is a binary, otherwise `nil`.
  """
  @spec telemetry_text(term()) :: String.t() | nil
  def telemetry_text(value) when is_binary(value), do: value
  def telemetry_text(_value), do: nil
end

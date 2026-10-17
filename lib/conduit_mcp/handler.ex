defmodule ConduitMcp.Handler do
  @moduledoc """
  Routes JSON-RPC 2.0 MCP requests to a server module's behaviour callbacks.

  `handle_request/3` is the single entry point: transports decode the
  request body, hand the resulting map to this module, and serialize the
  returned map back out. The handler itself is stateless — it does not own
  the server module, the connection, or any process state. Each request
  is independent and can run concurrently in its own Bandit process.

  ## Routed methods

  - `initialize` — version negotiation and capability advertisement
  - `ping` — round-trip liveness check
  - `tools/list`, `tools/call`
  - `resources/list`, `resources/templates/list`, `resources/read`
  - `resources/subscribe`, `resources/unsubscribe`
  - `prompts/list`, `prompts/get`
  - `completion/complete`
  - `logging/setLevel`
  - `tasks/get`, `tasks/cancel`, `tasks/result`, `tasks/list`
  - `notifications/initialized`, `notifications/cancelled`

  Unknown methods return `-32601 Method not found`. Unknown notifications are
  logged and dropped (per JSON-RPC notification semantics) — but a *known*
  notification that is malformed is answered with an error whose `id` is
  `null`, rather than dropped. See `handle_request/3`.

  ## Capability detection

  When the server module defines `__capabilities__/0` (typically generated
  by `ConduitMcp.Endpoint`), it is consulted for the `initialize` reply.
  Otherwise the base `tools`/`resources`/`prompts` set is used.
  Capability flags for optional features (`completions`, `logging`,
  `resources.subscribe`) are overlaid at runtime based on which callbacks
  the server exports. See `ConduitMcp.Capabilities.build/1`.

  ## Telemetry

  Emits these events:

  - `[:conduit_mcp, :request, :stop]` — every request, with
    `%{duration: <native>}` and metadata `%{method, server_module, status}`.
  - `[:conduit_mcp, :tool, :execute]` — per `tools/call`.
  - `[:conduit_mcp, :resource, :read]` — per `resources/read`.
  - `[:conduit_mcp, :prompt, :get]` — per `prompts/get`.
  - `[:conduit_mcp, :request, :cancelled]` — when a
    `notifications/cancelled` for a request in flight is recorded.

  ## Cancellation

  The handler stashes the request id into `conn.assigns[:mcp_request_id]`
  before dispatch, marks the request in flight with
  `ConduitMcp.Cancellation.track/2`, and uses `try/after` to untrack it and
  clear any cancellation flag after the response is produced. Tools poll
  `ConduitMcp.Cancellation.cancelled?(conn)` for cooperative aborts.
  `notifications/cancelled` is recorded only for a request in flight in the
  caller's scope; one naming an unknown or completed request is ignored.
  ## Layout

  This module is the public entry point only. The work is split into
  internal (undocumented) modules:

  - `Handler.Legacy` — request validation, notifications, the
    routing table, and the lifecycle, logging and subscription methods.
  - `Handler.Pipeline` — the per-request wrapper: `request.stop`
    telemetry, in-flight tracking, and the rescue that turns a raise into
    `-32603`.
  - Method modules (`Handler.Tools`, `.Resources`, `.Prompts`,
    `.Completion`, `.LegacyTasks`, with shared helpers in `.Common`) return
    an era-neutral `t:result/0` and never build JSON-RPC maps.
  - `ConduitMcp.Protocol.Legacy` shapes a `t:result/0` into the JSON-RPC
    response.
  """

  @typedoc """
  The era-neutral outcome of a method: a result map, or an error code,
  message and optional `data` member. Shaped into a protocol response by the
  era's response shaper (`ConduitMcp.Protocol.Legacy`).
  """
  @type result :: {:ok, map()} | {:error, integer(), String.t(), map() | nil}

  @doc """
  Handles an MCP request and returns a JSON-RPC response.
  Emits telemetry events for monitoring and metrics.

  Returns a response map for a request, and `:ok` for a notification that was
  handled or ignored.

  A notification has no id to correlate, so JSON-RPC says a failed one is
  dropped. `notifications/cancelled` is the exception: in these cases it
  returns an **error map with `"id" => nil`** instead of `:ok`, because
  reporting the client's own mistake back to it is a lesser deviation than a
  silent drop:

    * `params` is present but not an object → `-32602` invalid params.
    * `requestId` is present and neither an integer nor a string of at most
      256 bytes → `-32602` invalid params (a missing or `null` `requestId` is
      ignored: `:ok`). This is checked whether or not the request is in
      flight.
    * the request is in flight and the caller's scope is at its cancellation
      quota (`{:error, :cancellation_limit_reached}` from
      `ConduitMcp.Cancellation.cancel/3`) → `-32000` server error.

  A `notifications/cancelled` for a request that is not in flight in the
  caller's scope returns `:ok` and records nothing.

  A transport that pattern-matches `:ok` for every notification must handle
  the map too; both of ours do, via
  `ConduitMcp.Transport.Shared.dispatch_post/2`, which sends it with status
  200.
  """
  # `Plug.Conn.t() | map()`, not `Plug.Conn.t()`: the default is a bare
  # `%Plug.Conn{}`, whose `:owner` is `nil` where `t()` declares `pid()`. Real
  # callers pass an adapter-built conn; the default exists for direct calls.
  @spec handle_request(map(), module(), Plug.Conn.t() | map()) :: map() | :ok
  def handle_request(request, server_module, conn \\ %Plug.Conn{}),
    do: ConduitMcp.Handler.Legacy.handle_request(request, server_module, conn)

  @doc """
  Every method this handler routes, mapped to its internal name.

  Published as `ConduitMcp.Protocol.methods/0`.
  """
  @spec methods() :: %{optional(String.t()) => atom()}
  defdelegate methods, to: ConduitMcp.Handler.Legacy
end

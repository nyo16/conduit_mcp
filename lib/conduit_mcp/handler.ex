defmodule ConduitMcp.Handler do
  @moduledoc """
  Routes JSON-RPC 2.0 MCP requests to a server module's behaviour callbacks.

  Transports decode the request body, hand the resulting map to this module,
  and serialize what comes back. The handler itself is stateless — it does
  not own the server module, the connection, or any process state. Each
  request is independent and can run concurrently in its own Bandit process.

  Two entry points:

    * `dispatch/3` — the transport contract: classifies the request's
      protocol era (unless given a `ConduitMcp.Ctx`) and returns
      `{:reply, response}`, `{:stream, spec}` or `:noreply`.
    * `handle_request/3` — the map-returning wrapper over `dispatch/3`, kept
      for manual-mode callers.

  ## Protocol eras

  Every request is classified by `ConduitMcp.Era.classify/2`:

    * **Modern** (`2026-07-28`) — the request's `params._meta` carries
      `io.modelcontextprotocol/protocolVersion` and
      `io.modelcontextprotocol/clientCapabilities`, or the method is
      `server/discover`. Routed methods: `server/discover`, `tools/list`,
      `tools/call`, `resources/list`, `resources/templates/list`,
      `resources/read`, `prompts/list`, `prompts/get`, `completion/complete`.
      Results carry `resultType`, `serverInfo` `_meta` and (on cacheable
      results) `ttlMs`/`cacheScope`; see `ConduitMcp.Protocol.Modern`.
    * **Legacy** (`2025-11-25`, `2025-06-18`) — everything else. Routed
      methods: `initialize`, `ping`, `tools/list`, `tools/call`,
      `resources/list`, `resources/templates/list`, `resources/read`,
      `resources/subscribe`, `resources/unsubscribe`, `prompts/list`,
      `prompts/get`, `completion/complete`, `logging/setLevel`, `tasks/get`,
      `tasks/cancel`, `tasks/result`, `tasks/list`, and the notifications
      `notifications/initialized` and `notifications/cancelled`.

  Unknown methods return `-32601 Method not found` in both eras — on the
  modern path that includes every legacy-only method (`initialize`, `ping`,
  …), answered with HTTP 404 (`ConduitMcp.Protocol.Modern.http_status/1`).
  Unknown notifications are logged and dropped (per JSON-RPC notification
  semantics) — but a *known* legacy notification that is malformed is
  answered with an error whose `id` is `null`, rather than dropped. See
  `handle_request/3`. The modern era defines no client notifications over
  HTTP, so every modern notification is dropped.

  The callbacks receive a `Plug.Conn` in both eras; the request's
  `ConduitMcp.Ctx` is in it (`ConduitMcp.Ctx.from_conn/1`).

  ## Capability detection

  When the server module defines `__capabilities__/0` (typically generated
  by `ConduitMcp.Endpoint`), it is consulted for the `initialize` reply and
  the `server/discover` result. Otherwise the base
  `tools`/`resources`/`prompts` set is used. Capability flags for optional
  features (`completions`, `logging`, `resources.subscribe`) are overlaid at
  runtime based on which callbacks the server exports. See
  `ConduitMcp.Capabilities.build/2`.

  ## Telemetry

  Emits these events:

  - `[:conduit_mcp, :request, :stop]` — every request, with
    `%{duration: <native>}` and metadata `%{method, server_module, status,
    era, protocol_version, traceparent, tracestate, baggage}`.
  - `[:conduit_mcp, :tool, :execute]` — per `tools/call`.
  - `[:conduit_mcp, :resource, :read]` — per `resources/read`.
  - `[:conduit_mcp, :prompt, :get]` — per `prompts/get`.
  - `[:conduit_mcp, :mrtr, :input_required]` — per modern
    `InputRequiredResult` sent.
  - `[:conduit_mcp, :request, :cancelled]` — when a
    `notifications/cancelled` for a request in flight is recorded.

  ## Multi round-trip requests

  On the modern path `tools/call`, `resources/read` and `prompts/get`
  callbacks may return `{:input_required, input_requests, state}`; a retry's
  `requestState` is verified before the callback runs, and the restored state
  arrives in `conn.assigns[:mcp_input]`. See `ConduitMcp.Server` and
  `ConduitMcp.MRTR`. On the legacy path that return is answered with
  `-32603` ("MRTR input requests require protocol 2026-07-28").

  ## Cancellation

  The handler stashes the request id into `conn.assigns[:mcp_request_id]`
  before dispatch, marks the request in flight with
  `ConduitMcp.Cancellation.track/2`, and uses `try/after` to untrack it and
  clear any cancellation flag after the response is produced. Tools poll
  `ConduitMcp.Cancellation.cancelled?(conn)` for cooperative aborts.
  `notifications/cancelled` is recorded only for a request in flight in the
  caller's scope; one naming an unknown or completed request is ignored. A
  modern request never has a session, so its scope is its principal, else
  its client IP.

  ## Layout

  This module is the public entry point only. The work is split into
  internal (undocumented) modules:

  - `Handler.Legacy` / `Handler.Modern` — each era's request validation and
    routing table; `Handler.Legacy` also has the lifecycle, logging and
    subscription methods only that era has.
  - `Handler.Pipeline` — the per-request wrapper: `request.stop`
    telemetry, in-flight tracking, and the rescue that turns a raise into
    `-32603`.
  - Method modules (`Handler.Tools`, `.Resources`, `.Prompts`,
    `.Completion`, `.LegacyTasks`, with shared helpers in `.Common`) return
    an era-neutral `t:result/0` and never build JSON-RPC maps. The three
    MRTR methods run their callback through `Handler.MRTR`, which opens
    `requestState`, gates and seals `{:input_required, ...}`, and refuses it
    on the legacy era.
  - `ConduitMcp.Protocol.Legacy` / `ConduitMcp.Protocol.Modern` shape a
    `t:result/0` into the JSON-RPC response of their era.
  """

  alias ConduitMcp.Ctx
  alias ConduitMcp.Era
  alias ConduitMcp.Handler.Legacy
  alias ConduitMcp.Handler.Modern
  alias ConduitMcp.Protocol

  @typedoc """
  The era-neutral outcome of a method: a result map, an input-required
  round, or an error code, message and optional `data` member. Shaped into a
  protocol response by the era's response shaper
  (`ConduitMcp.Protocol.Legacy` or `ConduitMcp.Protocol.Modern`).

  `{:input_required, input_requests, state}` is what an MRTR callback
  returned; by the time it reaches `ConduitMcp.Protocol.Modern` its `state`
  has been sealed into the `requestState` token. Only the modern era shapes
  it: the legacy era answers it with `-32603` before shaping.
  """
  @type result ::
          {:ok, map()}
          | {:input_required, %{optional(String.t()) => map()}, term()}
          | {:error, integer(), String.t(), map() | nil}

  @typedoc """
  What a transport does with a message:

    * `{:reply, response}` — send the JSON-RPC `response` map. For a modern
      request the HTTP status is
      `ConduitMcp.Protocol.Modern.http_status/1` of it.
    * `{:stream, spec}` — a `ConduitMcp.StreamSpec`: a response the
      transport may send as a Server-Sent Events stream, relaying the
      notifications the work emits ahead of it. Returned for a modern
      `tools/call` whose `_meta` carries a `progressToken` or a `logLevel`.
    * `:noreply` — a notification: nothing to send.
  """
  @type reply :: {:reply, map()} | {:stream, ConduitMcp.StreamSpec.t()} | :noreply

  @doc """
  Classifies and handles a decoded JSON-RPC message.

  The third argument is either the request's `ConduitMcp.Ctx` — what a
  transport passes once it has run `ConduitMcp.Era.classify/2` itself (and,
  for a modern request, `ConduitMcp.Plugs.HeaderValidation`) — or the
  request's `Plug.Conn`, in which case the request is classified here. A
  context already stored on that conn is ignored: the conn may belong to an
  outer request.

  A classification failure (invalid modern `_meta`, or a mixed request whose
  session is bound to another principal) is answered with a modern error
  response; on HTTP such a rejection is a 400, whatever its code (see
  `ConduitMcp.Era`).
  """
  @spec dispatch(map(), module(), Ctx.t() | Plug.Conn.t() | map()) :: reply()
  def dispatch(request, server_module, %Ctx{} = ctx),
    do: dispatch_era(request, server_module, ctx)

  def dispatch(request, server_module, conn) do
    case Era.classify(request, conn) do
      {:ok, ctx} -> dispatch_era(request, server_module, ctx)
      {:error, code, message, data} -> reject(request, server_module, conn, {code, message, data})
    end
  end

  defp dispatch_era(request, server_module, %Ctx{era: :modern} = ctx),
    do: Modern.dispatch(request, server_module, ctx)

  defp dispatch_era(request, server_module, %Ctx{era: :legacy} = ctx) do
    case Legacy.handle_request(request, server_module, ctx) do
      :ok -> :noreply
      response -> {:reply, response}
    end
  end

  # Only modern `_meta` can fail classification, so the rejection is shaped
  # and instrumented as modern.
  defp reject(request, server_module, conn, {code, message, data}) do
    ctx = %Ctx{era: :modern, conn: conn}

    response =
      ConduitMcp.Handler.Pipeline.instrument(request, server_module, ctx, fn ->
        Protocol.Modern.to_response(
          Map.get(request, "id"),
          Map.get(request, "method"),
          {:error, code, message, data}
        )
      end)

    {:reply, response}
  end

  @doc """
  Handles an MCP request and returns a JSON-RPC response.
  Emits telemetry events for monitoring and metrics.

  A wrapper over `dispatch/3` that classifies the request's era itself.
  Returns a response map for a request, and `:ok` for a notification that was
  handled or ignored, or for a JSON-RPC response: the server sends no
  requests of its own, so a response answers nothing and is dropped.
  `ConduitMcp.Transport.Shared.dispatch_post/2` answers `:ok` with
  `202 Accepted` and no body. A `{:stream, spec}` dispatch is run to
  completion in the calling process (`ConduitMcp.StreamSpec.run/1`): its
  notifications are dropped and its final response is returned.

  A notification has no id to correlate, so JSON-RPC says a failed one is
  dropped. Legacy `notifications/cancelled` is the exception: in these cases
  it returns an **error map with `"id" => nil`** instead of `:ok`, because
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
  def handle_request(request, server_module, conn \\ %Plug.Conn{}) do
    request
    |> dispatch(server_module, conn)
    |> to_map(request)
  end

  @doc false
  @spec to_map(reply(), map()) :: map() | :ok
  def to_map({:reply, response}, _request), do: response
  def to_map(:noreply, _request), do: :ok
  def to_map({:stream, spec}, _request), do: ConduitMcp.StreamSpec.run(spec)

  @doc """
  Every method this handler routes, in either era, mapped to its internal
  name.

  Published as `ConduitMcp.Protocol.methods/0`.
  """
  @spec methods() :: %{optional(String.t()) => atom()}
  def methods, do: Map.merge(Legacy.methods(), Modern.methods())

  @doc """
  The methods one era routes (`:legacy` includes its notifications).
  """
  @spec methods(Ctx.era()) :: %{optional(String.t()) => atom()}
  def methods(:legacy), do: Legacy.methods()
  def methods(:modern), do: Modern.methods()
end

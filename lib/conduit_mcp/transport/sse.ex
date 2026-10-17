defmodule ConduitMcp.Transport.SSE do
  @moduledoc """
  Server-Sent Events (SSE) transport layer for MCP.

  > #### Legacy transport {: .warning}
  >
  > SSE is the pre-2025-03-26 MCP transport. New servers should use
  > `ConduitMcp.Transport.StreamableHTTP`, which carries the same features
  > over a single endpoint and is the one the specification develops. This
  > transport is maintained for existing clients.

  Provides two endpoints:
  - GET /sse - Server-Sent Events stream for server-to-client messages
  - POST /message - HTTP endpoint for client-to-server messages

  Everything this transport shares with `ConduitMcp.Transport.StreamableHTTP`
  — the plug pipeline, CORS headers, auth (including `strategy: :oauth`), rate
  limiting, the JSON-RPC POST dispatch, `GET /health`, the RFC 9728 metadata
  endpoint and the catch-alls — lives in `ConduitMcp.Transport.Shared`.

  ## Differences from `ConduitMcp.Transport.StreamableHTTP`

  - **No sessions.** `Mcp-Session-Id` is defined by the Streamable HTTP
    transport in the MCP specification; SSE predates it and has no session
    concept, so `:session` is not an option here, and there is no
    `DELETE /` to end one (`DELETE` falls through to the 404 catch-all).
  - **A long-lived GET stream.** `GET /sse` holds one process, socket and
    `Plug.Conn` for the life of the connection, bounded by
    `:max_connections` and `:max_connection_lifetime`. It carries the
    `endpoint` event and then only `:\\r\\n` keep-alive comments.
  - **The modern era is served, but not designed for.** `POST /message` runs
    the shared pipeline, so a `2026-07-28` request is classified, its
    headers validated, and answered exactly as by StreamableHTTP's `POST /`
    (including a streamed `tools/call` response). The `2026-07-28`
    specification defines no HTTP+SSE transport, though, so modern clients
    should use `ConduitMcp.Transport.StreamableHTTP`; `GET /sse` is legacy
    only. A legacy request whose `MCP-Protocol-Version` header names an
    unsupported version is answered 400 here too.

  ## Options

  - `:server_module` (required) - The MCP server module to route requests to
  - `:cors_origin` — value for `access-control-allow-origin`. **Unset means no
    CORS headers are emitted at all**, so a page on another origin cannot read
    the response. Set it (e.g. `"https://myapp.example"`, or `"*"`) to opt in.
  - `:cors_methods` - CORS allow-methods header (default: "GET, POST, OPTIONS";
    only emitted when `:cors_origin` is set). Unlike
    `ConduitMcp.Transport.StreamableHTTP`, no `DELETE`: there is no session
    to end.
  - `:cors_headers` - CORS allow-headers header (default:
    "content-type, authorization, mcp-session-id, mcp-protocol-version, mcp-method, mcp-name";
    only emitted when `:cors_origin` is set). `Mcp-Param-*` names must be
    listed here explicitly: `access-control-allow-headers` has no wildcard
    that holds for credentialed requests. Whenever `:cors_origin` is set,
    `access-control-expose-headers: mcp-session-id, mcp-protocol-version` is
    emitted too.
  - `:auth` - Authentication plug configuration (optional). Supports every
    strategy `ConduitMcp.Plugs.Auth` does, plus `:oauth`.
  - `:instructions` - instructions returned by `initialize` and
    `server/discover`; overrides the server module's own (`use
    ConduitMcp.Server, instructions:` or the Endpoint's `:instructions`)
  - `:base_url` - Public base URL advertised in the SSE `endpoint` event
    (e.g. `"https://mcp.example.com"`). Defaults to deriving it from the
    request's `Host` header (sanitized). Set this when running behind a proxy.
  - `:allowed_origins` - allowlist for the `Origin` header. Accepts a list of
    strings, a bare string, a `Regex`, or `"*"`; any other value raises
    `ArgumentError` at `init/1`. A `Regex` is matched unanchored, so anchor it:
    `~r/\\Ahttps:\\/\\/example\\.com\\z/`. **Unset fails closed**: any request
    carrying an `Origin` is rejected with 403. Requests without an `Origin`
    always pass. See `ConduitMcp.Plugs.OriginValidation`.
  - `:keep_alive_interval` - milliseconds between `:\\r\\n` keep-alive
    comments, on `GET /sse` and on streamed POST responses (default: 15 000).
  - `:max_streams`, `:max_stream_lifetime`, `:stream_cancel_timeout` - the
    bounds on streamed modern POST responses; see
    `ConduitMcp.Transport.StreamableHTTP`.
  - `:max_connection_lifetime` - milliseconds after which an SSE stream is
    closed (default: 1 hour). A stream pins a process, a socket and a
    `Plug.Conn`; without a lifetime a client that opens connections and never
    reads accumulates both indefinitely.
  - `:max_connections` - maximum concurrent SSE streams, a positive integer;
    any other value raises `ArgumentError` at `init/1`. Further connections
    get HTTP 503 (default: 1 000).

  ## Example

      {Bandit,
       plug: {ConduitMcp.Transport.SSE,
              server_module: MyApp.MCPServer,
              cors_origin: "https://myapp.com"},
       port: 4001}

  ## With Authentication

      {Bandit,
       plug: {ConduitMcp.Transport.SSE,
              server_module: MyApp.MCPServer,
              auth: [
                strategy: :bearer_token,
                token: "my-secret-token"
              ]},
       port: 4001}
  """

  use ConduitMcp.Transport.Shared

  alias ConduitMcp.Transport.SSEStream

  @default_max_connection_lifetime :timer.hours(1)
  @default_max_connections 1_000

  @connections_table :conduit_mcp_sse_connections

  # Overrides the default from `use ConduitMcp.Transport.Shared`.
  def __transport_private__(opts) do
    %{
      sse_base_url: Keyword.get(opts, :base_url),
      max_connection_lifetime:
        Keyword.get(opts, :max_connection_lifetime, @default_max_connection_lifetime),
      max_connections:
        validate_max_connections!(Keyword.get(opts, :max_connections, @default_max_connections))
    }
  end

  # Checked at boot: a non-integer compares greater than every count, so it
  # would silently disable the cap.
  defp validate_max_connections!(max) when is_integer(max) and max > 0, do: max

  defp validate_max_connections!(max) do
    raise ArgumentError,
          ":max_connections must be a positive integer; got #{inspect(max)}"
  end

  # --- routes -----------------------------------------------------------

  # SSE endpoint for server-to-client streaming
  get "/sse" do
    accept_header = get_req_header(conn, "accept") |> List.first()

    cond do
      is_nil(accept_header) or not String.contains?(accept_header, "text/event-stream") ->
        Logger.warning("SSE connection rejected: invalid Accept header")

        Shared.send_json(conn, 406, %{
          error: "Not Acceptable",
          message: "Accept header must include 'text/event-stream'"
        })

      not acquire_connection_slot(conn) ->
        Logger.warning("SSE connection rejected: at :max_connections")

        Shared.send_json(conn, 503, %{
          error: "Service Unavailable",
          message: "Too many concurrent SSE connections"
        })

      true ->
        Logger.info("New SSE connection established")

        try do
          conn
          |> SSEStream.open()
          |> send_sse_endpoint_info()
        after
          SSEStream.release_slot(@connections_table)
        end
    end
  end

  # Message endpoint for client-to-server requests
  post "/message" do
    Shared.dispatch_post(conn)
  end

  Shared.shared_routes()

  # --- SSE stream -------------------------------------------------------

  defp send_sse_endpoint_info(conn) do
    endpoint_url = "#{message_base_url(conn)}/message"

    case SSEStream.send_frame(conn, "event: endpoint\ndata: #{endpoint_url}\n\n") do
      {:ok, conn} ->
        hold_open(conn)

      {:error, reason} ->
        Logger.error("Failed to send SSE chunk: #{inspect(reason)}")
        conn
    end
  end

  # Prefer the configured :base_url; otherwise fall back to the client Host
  # header, sanitized so a hostile value can't smuggle CR/LF or whitespace
  # into the SSE stream we emit it on.
  @doc false
  def message_base_url(conn) do
    case conn.private[:sse_base_url] do
      base_url when is_binary(base_url) ->
        String.trim_trailing(base_url, "/")

      _ ->
        host =
          get_req_header(conn, "host")
          |> List.first()
          |> sanitize_host()

        scheme = if conn.scheme == :https, do: "https", else: "http"
        "#{scheme}://#{host}"
    end
  end

  defp sanitize_host(nil), do: "localhost:4001"
  defp sanitize_host(host), do: String.replace(host, ~r/[\r\n\s\/]/, "")

  # Nothing is ever pushed on this stream after the `endpoint` event: replies
  # travel in the `POST /message` response bodies. The stream only stays open,
  # with keep-alives, until the client leaves or `:max_connection_lifetime`
  # passes. `SSEStream.loop/3` drains every other message, so the mailbox
  # cannot grow over a multi-day connection.
  defp hold_open(conn) do
    deadline = System.monotonic_time(:millisecond) + conn.private[:max_connection_lifetime]

    case SSEStream.loop(conn, nil,
           interval: conn.private[:keep_alive_interval],
           deadline: deadline
         ) do
      {:deadline, conn, _state} ->
        Logger.info("SSE connection closed: reached :max_connection_lifetime")
        conn

      {_closed, conn, _state} ->
        conn
    end
  end

  # --- connection accounting --------------------------------------------

  # One row per live `GET /sse` stream in `:conduit_mcp_sse_connections`; see
  # the slot-accounting section of `ConduitMcp.Transport.SSEStream`.
  defp acquire_connection_slot(conn) do
    SSEStream.ensure_slot_table(@connections_table)
    SSEStream.acquire_slot(@connections_table, conn.private[:max_connections])
  end

  # The number of live `GET /sse` streams. Read-only; see
  # `ConduitMcp.Transport.SSEStream.active_slots/1`.
  @doc false
  def active_connections, do: SSEStream.active_slots(@connections_table)

  defmodule Owner do
    @moduledoc """
    Long-lived process that owns the `:conduit_mcp_sse_connections` ETS table,
    the slot table behind `ConduitMcp.Transport.SSE`'s `:max_connections`:
    one row per SSE stream, keyed by the pid serving it.

    Started under `ConduitMcp.Supervisor` by `ConduitMcp.Application`, so the
    table outlives every individual stream. If a stream owned it, closing that
    one connection would destroy the slots of every other live stream and let
    a client walk straight past `:max_connections`.
    """

    # Not a GenServer itself: the process is a `ConduitMcp.EtsOwner`
    # registered under this module's name. This module is the child spec.
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts) do
      ConduitMcp.EtsOwner.start_link(
        __MODULE__,
        :conduit_mcp_sse_connections,
        ConduitMcp.Transport.SSEStream.slot_table_opts()
      )
    end
  end
end

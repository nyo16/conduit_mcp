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
    concept, so `:session` is not an option here.
  - **A long-lived GET stream.** `GET /sse` holds one process, socket and
    `Plug.Conn` for the life of the connection, bounded by
    `:max_connections` and `:max_connection_lifetime`.

  ## Options

  - `:server_module` (required) - The MCP server module to route requests to
  - `:cors_origin` — value for `access-control-allow-origin`. **Unset means no
    CORS headers are emitted at all**, so a page on another origin cannot read
    the response. Set it (e.g. `"https://myapp.example"`, or `"*"`) to opt in.
  - `:cors_methods` - CORS allow-methods header (default: "GET, POST, OPTIONS";
    only emitted when `:cors_origin` is set)
  - `:cors_headers` - CORS allow-headers header (default:
    "content-type, authorization"; only emitted when `:cors_origin` is set)
  - `:auth` - Authentication plug configuration (optional). Supports every
    strategy `ConduitMcp.Plugs.Auth` does, plus `:oauth`.
  - `:base_url` - Public base URL advertised in the SSE `endpoint` event
    (e.g. `"https://mcp.example.com"`). Defaults to deriving it from the
    request's `Host` header (sanitized). Set this when running behind a proxy.
  - `:allowed_origins` - allowlist for the `Origin` header. Accepts a list of
    strings, a bare string, a `Regex`, or `"*"`. **Unset fails closed**: any
    request carrying an `Origin` is rejected with 403. Requests without an
    `Origin` always pass. See `ConduitMcp.Plugs.OriginValidation`.
  - `:keep_alive_interval` - milliseconds between SSE keepalive comments
    (default: 15 000).
  - `:max_connection_lifetime` - milliseconds after which an SSE stream is
    closed (default: 1 hour). A stream pins a process, a socket and a
    `Plug.Conn`; without a lifetime a client that opens connections and never
    reads accumulates both indefinitely.
  - `:max_connections` - maximum concurrent SSE streams. Further connections
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

  @default_keep_alive_interval 15_000
  @default_max_connection_lifetime :timer.hours(1)
  @default_max_connections 1_000

  @connections_table :conduit_mcp_sse_connections

  # Overrides the default from `use ConduitMcp.Transport.Shared`.
  def __transport_private__(opts) do
    %{
      sse_base_url: Keyword.get(opts, :base_url),
      keep_alive_interval: Keyword.get(opts, :keep_alive_interval, @default_keep_alive_interval),
      max_connection_lifetime:
        Keyword.get(opts, :max_connection_lifetime, @default_max_connection_lifetime),
      max_connections: Keyword.get(opts, :max_connections, @default_max_connections)
    }
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
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)
          |> send_sse_endpoint_info()
        after
          release_connection_slot()
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

    # Send as SSE message
    sse_message = "event: endpoint\ndata: #{endpoint_url}\n\n"

    case chunk(conn, sse_message) do
      {:ok, conn} ->
        # Keep connection alive
        keep_alive_loop(conn)

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

  # The old loop matched only `{:plug_conn, :sent}` with an `after` timeout.
  # Every other message — monitor `:DOWN`s, `:system` messages, a stray
  # `send/2` — was never matched and never removed, and because the clause has
  # a non-matching pattern *plus* an `after`, every tick rescanned the whole
  # accumulated mailbox: a monotonic leak with O(n) per-tick rescan over a
  # multi-day connection. The catch-all below is what drains it.
  defp keep_alive_loop(conn) do
    interval = conn.private[:keep_alive_interval] || @default_keep_alive_interval

    deadline =
      System.monotonic_time(:millisecond) +
        (conn.private[:max_connection_lifetime] || @default_max_connection_lifetime)

    keep_alive_loop(conn, interval, deadline)
  end

  defp keep_alive_loop(conn, interval, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.info("SSE connection closed: reached :max_connection_lifetime")
      conn
    else
      # The deadline is checked here, at the top, not inside the `after`.
      # Every clause below recurses into a fresh `receive`, which restarts the
      # `after` timer — so a message arriving more often than `interval` used to
      # starve both the keepalive *and* the lifetime check, pinning the process
      # past its configured ceiling forever.
      await_keepalive(conn, interval, deadline, min(interval, remaining))
    end
  end

  defp await_keepalive(conn, interval, deadline, timeout) do
    # receive/after rather than :timer.sleep so the process stays responsive
    # to messages (e.g. adapter bookkeeping) between keepalives.
    receive do
      {:plug_conn, :sent} ->
        keep_alive_loop(conn, interval, deadline)

      # `{:bandit, _}` is NOT drained. Under HTTP/2 the Plug runs inside
      # `Bandit.HTTP2.StreamProcess`, and the connection process delivers
      # `{:send_window_update, delta}` and `{:rst_stream, code}` to *this*
      # mailbox for `chunk/2` to read back with a selective receive. Draining
      # them would silently discard flow-control credit (eventually a
      # FLOW_CONTROL_ERROR) and ignore h2 stream cancellation - an
      # `EventSource.close()` sends RST_STREAM, not a TCP close, so the slot
      # would be held for the whole `:max_connection_lifetime`.
      msg when not (is_tuple(msg) and tuple_size(msg) > 0 and elem(msg, 0) == :bandit) ->
        # Drain anything else so the mailbox cannot grow without bound.
        keep_alive_loop(conn, interval, deadline)
    after
      timeout ->
        send_keepalive(conn, interval, deadline)
    end
  end

  defp send_keepalive(conn, interval, deadline) do
    case chunk(conn, ": keepalive\n\n") do
      {:ok, conn} ->
        keep_alive_loop(conn, interval, deadline)

      {:error, _reason} ->
        # Client disconnected
        conn
    end
  end

  # --- connection accounting --------------------------------------------

  # Each SSE stream pins a process, a socket and a Plug.Conn for its whole
  # life, so the count has to be bounded somewhere. `:ets.update_counter/4`
  # makes the check-and-increment atomic, which a read-then-write pair would
  # not be under concurrency.
  #
  # The table is owned by the supervised `Owner` below, not by whichever stream
  # first touched it. Without that, closing the *creating* connection destroyed
  # the table and reset `:active` to 0 while every other stream was still live,
  # so `:max_connections` could be walked past indefinitely — the same defect
  # RC2 fixed for the session table.
  defp acquire_connection_slot(conn) do
    max = conn.private[:max_connections] || @default_max_connections
    ensure_connections_table()

    case update_active(1) do
      # Counter unreadable. A resource cap must read that as "no" - returning a
      # number here meant `0 > max` was false and the slot was granted, so
      # every failure mode of the counter silently disabled the cap. That is
      # reachable whenever the Owner has degraded and the table belongs to a
      # stream process that has since exited.
      :unavailable ->
        false

      active when active > max ->
        update_active(-1)
        false

      _active ->
        true
    end
  end

  defp release_connection_slot do
    ensure_connections_table()
    # `{2, -1, 0, 0}` clamps at zero: a slot leaked by an untrappable exit
    # (`Process.exit(pid, :kill)`) must not drive the counter negative.
    :ets.update_counter(@connections_table, :active, {2, -1, 0, 0}, {:active, 0})
    :ok
  rescue
    # The table vanished between the check and the update. Nothing to release.
    ArgumentError -> :ok
  end

  defp update_active(delta) do
    :ets.update_counter(@connections_table, :active, {2, delta}, {:active, 0})
  rescue
    # A racing `:ets.new` in ensure_connections_table/0, or the table being
    # recreated underneath us. Distinguishable from a real count so the caller
    # can fail closed rather than read it as "no slots taken".
    ArgumentError -> :unavailable
  end

  @doc false
  def active_connections do
    ensure_connections_table()

    case :ets.lookup(@connections_table, :active) do
      [{:active, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc false
  def connections_table_opts do
    [:named_table, :public, :set, write_concurrency: :auto]
  end

  # Fallback for embedding contexts where the `:conduit_mcp` application is not
  # started. Normally a no-op: `Owner` creates the table at boot.
  defp ensure_connections_table do
    if :ets.whereis(@connections_table) == :undefined do
      :ets.new(@connections_table, connections_table_opts())
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defmodule Owner do
    @moduledoc """
    Long-lived process that owns the `:conduit_mcp_sse_connections` ETS table,
    which holds the concurrent-stream counter behind
    `ConduitMcp.Transport.SSE`'s `:max_connections`.

    Started under `ConduitMcp.Supervisor` by `ConduitMcp.Application`. Without a
    supervised owner the table belonged to whichever SSE stream created it, and
    closing that one connection destroyed the counter for every other live
    stream — letting a client walk straight past `:max_connections`.
    """

    # Not a GenServer itself: the process is a `ConduitMcp.EtsOwner`
    # registered under this module's name. This module is the child spec.
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    alias ConduitMcp.Transport.SSE

    def start_link(_opts) do
      ConduitMcp.EtsOwner.start_link(
        __MODULE__,
        :conduit_mcp_sse_connections,
        SSE.connections_table_opts()
      )
    end
  end
end

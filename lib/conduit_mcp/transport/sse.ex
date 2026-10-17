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
    strings, a bare string, a `Regex`, or `"*"`; any other value raises
    `ArgumentError` at `init/1`. A `Regex` is matched unanchored, so anchor it:
    `~r/\\Ahttps:\\/\\/example\\.com\\z/`. **Unset fails closed**: any request
    carrying an `Origin` is rejected with 403. Requests without an `Origin`
    always pass. See `ConduitMcp.Plugs.OriginValidation`.
  - `:keep_alive_interval` - milliseconds between SSE keepalive comments
    (default: 15 000).
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

        # No `connection: keep-alive`: HTTP/1.1 is persistent by default and
        # proxies strip hop-by-hop headers anyway, while RFC 9113 §8.2.2
        # forbids connection-specific headers in HTTP/2 and strict clients
        # (curl, nghttp2) reject a response carrying one as malformed.
        try do
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
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
  # life, so the count has to be bounded somewhere. Every stream holds one row,
  # `{{:slot, pid}, monotonic_time}`, keyed by the pid of the process serving
  # it.
  #
  # Keying by pid is what makes a slot reclaimable when its cleanup never runs.
  # Under HTTP/2, Bandit's `Bandit.HTTP2.StreamProcess` is linked to the
  # connection process and does not trap exits, so a peer close kills the
  # stream before the `after` in the `GET /sse` route can call
  # release_connection_slot/0. A bare counter leaked one slot per such
  # disconnect for the life of the node; a row whose pid is dead is
  # recognisably stale and __acquire_slot__/3 sweeps it.
  #
  # Insert-then-count keeps the cap exact under concurrency: each acquirer's
  # own row is part of the count it reads, so two racers at the boundary can
  # both reject (under-admit) but no interleaving admits more than `max`.
  # Dead rows are only swept once the count exceeds `max`; below the cap they
  # are never counted against anyone.
  #
  # The count is `:ets.info(table, :size)`, O(1): every row is a slot row
  # except one `:last_sweep` marker, which is subtracted. The marker is
  # overwritten but never deleted, so a concurrent count can only see it
  # appear - an overcount by one, which rejects rather than over-admits.
  #
  # A sweep is O(rows), so the reject path rate-limits it. A sweep that freed
  # nothing writes `{:last_sweep, now_ms}`; for `@sweep_window_ms` after that,
  # an over-cap acquirer rejects without sweeping again. At the cap with every
  # stream alive, a flood of rejected connects therefore costs one sweep per
  # window instead of one per connect. A release, or a sweep that did free a
  # row, resets the marker to `{:last_sweep, nil}`: the table has changed, so
  # "nothing here is dead" no longer describes it. A dead row cannot be
  # starved by this: the skip only applies within one window of a fruitless
  # sweep, so a stream killed without releasing is reclaimed by the first
  # over-cap connect after that window - at most `@sweep_window_ms` later
  # than with no skip at all.
  #
  # One row per pid holds because an HTTP/2 stream is its own process and
  # HTTP/1.1 keep-alive runs requests sequentially in one process, where the
  # `after` runs before the next request. `Process.alive?/1` is local-only,
  # which is fine: Bandit handlers run on this node.
  #
  # The table is owned by the supervised `Owner` below, not by whichever stream
  # first touched it. Otherwise closing the *creating* connection would destroy
  # the table, and every other live stream's slot with it, so
  # `:max_connections` could be walked past indefinitely.
  @slot_pids_spec [{{{:slot, :"$1"}, :_}, [], [:"$1"]}]
  @sweep_window_ms 1_000

  defp acquire_connection_slot(conn) do
    ensure_connections_table()
    __acquire_slot__(@connections_table, conn.private[:max_connections])
  end

  # Takes the table name so the fail-closed path can be exercised against a
  # table that does not exist, without touching the global one, and the sweep
  # window so its expiry can be exercised without waiting it out.
  @doc false
  def __acquire_slot__(table, max, sweep_window_ms \\ @sweep_window_ms) do
    :ets.insert(table, {{:slot, self()}, System.monotonic_time()})

    if admit?(table, max, sweep_window_ms) do
      true
    else
      :ets.delete(table, {:slot, self()})
      false
    end
  rescue
    # The table is missing or unusable. A resource cap must read that as "no":
    # granting the slot would let every failure mode of the table silently
    # disable the cap. The route recreates a missing table in
    # ensure_connections_table/0 first, so this is reachable only if the table
    # vanishes after that check - between it and the insert, or mid-count.
    ArgumentError -> false
  end

  defp admit?(table, max, sweep_window_ms) do
    count = count_slots(table)

    cond do
      not is_integer(count) -> false
      count <= max -> true
      recently_swept_in_vain?(table, sweep_window_ms) -> false
      true -> within_cap?(sweep_dead_slots(table), max)
    end
  end

  defp within_cap?(count, max), do: is_integer(count) and count <= max

  # `:undefined` (not an integer) when the table has vanished; callers treat
  # that as over the cap.
  defp count_slots(table) do
    marker = if :ets.member(table, :last_sweep), do: 1, else: 0

    case :ets.info(table, :size) do
      size when is_integer(size) -> size - marker
      :undefined -> :undefined
    end
  end

  defp recently_swept_in_vain?(table, sweep_window_ms) do
    case :ets.lookup(table, :last_sweep) do
      [{:last_sweep, at}] when is_integer(at) ->
        System.monotonic_time(:millisecond) - at < sweep_window_ms

      _ ->
        false
    end
  end

  # Deletes the rows of streams that died without releasing, records whether
  # that freed anything, then recounts.
  defp sweep_dead_slots(table) do
    dead = for pid <- :ets.select(table, @slot_pids_spec), not Process.alive?(pid), do: pid
    Enum.each(dead, &:ets.delete(table, {:slot, &1}))

    swept_at = if dead == [], do: System.monotonic_time(:millisecond)
    :ets.insert(table, {:last_sweep, swept_at})

    count_slots(table)
  end

  defp release_connection_slot, do: __release_slot__(@connections_table)

  @doc false
  def __release_slot__(table) do
    :ets.delete(table, {:slot, self()})
    # A freed slot ends any skip window: see the section comment.
    :ets.insert(table, {:last_sweep, nil})
    :ok
  rescue
    # The table is gone, and this stream's row with it. Nothing to release.
    ArgumentError -> :ok
  end

  # The number of slot rows whose process is alive. Read-only: a getter that
  # swept dead rows would hide leaks from the tests that should see them.
  @doc false
  def active_connections do
    @connections_table
    |> :ets.select(@slot_pids_spec)
    |> Enum.count(&Process.alive?/1)
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

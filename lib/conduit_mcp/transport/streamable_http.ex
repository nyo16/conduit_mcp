defmodule ConduitMcp.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport for MCP (recommended).

  Provides a single POST endpoint for bidirectional communication.
  This is the modern replacement for SSE transport.

  Everything this transport shares with `ConduitMcp.Transport.SSE` — the plug
  pipeline, CORS headers, auth, rate limiting, the JSON-RPC POST dispatch,
  `GET /health`, the RFC 9728 metadata endpoint and the catch-alls — lives in
  `ConduitMcp.Transport.Shared`.

  ## Endpoint

  - `POST /` — JSON-RPC messages. A request is answered with its JSON-RPC
    response; a notification or a JSON-RPC response with `202 Accepted` and
    no body. The `mcp-protocol-version` response header carries the version
    the connection negotiated (see
    `ConduitMcp.Transport.Shared.put_protocol_version_header/2`).
  - `GET /` — with `Accept: text/event-stream`, **405** with an `allow`
    header: this server offers no server-to-client SSE stream. Any other GET
    gets a JSON info document.
  - `DELETE /` — ends the session named by `Mcp-Session-Id` (200). It is
    validated exactly like a POST: an unknown session id is 404, a missing
    one 400. With sessions off it is **405**.

  ## Protocol eras

  `POST /` serves both eras; the request body decides
  (`ConduitMcp.Era.classify/2`), after authentication and before the
  message rate limit:

  - **Modern** (`2026-07-28`, `_meta` carries the protocol version and
    client capabilities): `ConduitMcp.Plugs.HeaderValidation` checks
    `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*`
    against the body; every rejection is HTTP 400 and is not counted by
    `:message_rate_limit`. No session is ever minted or required, and
    `Mcp-Session-Id` and `Last-Event-ID` are ignored — except that a session
    id naming a live session bound to another principal is rejected (400).
    The response echoes the request's version in `mcp-protocol-version` and
    is sent at `ConduitMcp.Protocol.Modern.http_status/1`. A `tools/call`
    whose `_meta` carries a `progressToken` or a `logLevel`, from a client
    whose `Accept` includes `text/event-stream`, may be answered as a
    Server-Sent Events stream: `notifications/progress` and
    `notifications/message` (`ConduitMcp.Progress`, `ConduitMcp.Log`), `:\\r\\n`
    keep-alive comments, then the response. Closing that stream cancels
    the request (`ConduitMcp.Cancellation`). A `subscriptions/listen` is
    answered with a long-lived stream of the change notifications it opted
    in to (`ConduitMcp.Subscriptions`); it needs `text/event-stream` in
    `Accept` (else 406).
  - **Legacy** (`2025-11-25`, `2025-06-18`): sessions, `initialize`, and
    JSON responses as before. A request whose `MCP-Protocol-Version` header
    names a version this server does not support is answered **400**
    (`initialize` excepted); a request without the header is served.

  GET and DELETE carry no `_meta` and keep legacy semantics.

  ## Differences from `ConduitMcp.Transport.SSE`

  - **Sessions are Streamable-HTTP-only, by design.** `Mcp-Session-Id` is
    defined by the Streamable HTTP transport in the MCP specification; the
    legacy SSE transport has no session concept, so `:session` is accepted
    here and nowhere else. For the same reason `DELETE /` exists only here,
    and so does `DELETE` in the default `:cors_methods`.

  ## Options

  - `:server_module` (required) — the MCP server module to route requests to
  - `:server_name` — advertised server name in the `initialize` response (falls
    back to the module's `__endpoint_config__/0` if defined)
  - `:server_version` — advertised server version (same fallback behavior)
  - `:instructions` — instructions returned by `initialize` and
    `server/discover`; overrides the server module's own (`use
    ConduitMcp.Server, instructions:` or the Endpoint's `:instructions`)
  - `:auth` — authentication plug configuration. See `ConduitMcp.Plugs.Auth`
    and `ConduitMcp.Plugs.OAuth`. Resolved once, in `init/1`.
  - `:rate_limit` — HTTP-level rate limit configuration. See `ConduitMcp.Plugs.RateLimit`.
  - `:message_rate_limit` — per-message rate limit configuration. See
    `ConduitMcp.Plugs.MessageRateLimit`.
  - `:keep_alive_interval` — milliseconds between `:\\r\\n` keep-alive
    comments on a streamed response (default: 15 000).
  - `:max_streams` — maximum concurrent streamed responses (default:
    1 000), `subscriptions/listen` streams included. A `tools/call` response
    that would open a stream past the cap is sent as plain JSON instead,
    without its notifications; a `subscriptions/listen` past the cap is
    refused with HTTP 503.
  - `:max_stream_lifetime` — milliseconds after which a streamed request is
    cancelled (default: 1 hour); its response is then `-32603` unless the
    tool returns within `:stream_cancel_timeout`. A `subscriptions/listen`
    stream is ended gracefully at this age, or earlier at its OAuth bearer
    token's `exp`.
  - `:stream_cancel_timeout` — milliseconds a cancelled streamed request's
    tool (client disconnect or `:max_stream_lifetime`) gets to notice
    `ConduitMcp.Cancellation.cancelled?/1` and return before it is killed
    (default: 5 000).
  - `:max_listens_per_principal` — maximum concurrent `subscriptions/listen`
    streams per principal (`ConduitMcp.Principal.rate_limit_key/1`: the
    authenticated id, else the client's address) (default: 4). The next is
    admitted and the principal's oldest stream is ended gracefully (see
    `ConduitMcp.Subscriptions`); it is never refused with HTTP 429.
  - `:listen_idle_timeout` — milliseconds a `subscriptions/listen` stream
    may go without delivering a notification before the server ends it
    gracefully (default: 30 minutes). Keep-alives do not count. Checked on
    each keep-alive tick, so it fires up to `:keep_alive_interval` late.

    These six must be positive integers; anything else raises
    `ArgumentError` at `init/1`.
  - `:session` — session-store configuration, a keyword list. **Sessions are
    off unless configured**: omitting `:session` (or passing `session: false`)
    means no `Mcp-Session-Id` is issued or checked. Pass `session: []` to
    enable them with `ConduitMcp.Session.EtsStore`, or `session: [store: MyStore]`
    for another store. See `ConduitMcp.Session`. Add `require_session: true` to
    reject non-`initialize` POSTs that omit the `Mcp-Session-Id` header (HTTP
    400), per the MCP specification's session requirements. A `:session` that
    is not a keyword list, `false` or `nil` (`true`, a map) raises
    `ArgumentError` at `init/1`.
  - `:allowed_origins` — allowlist for the `Origin` header. Accepts a list of
    strings, a bare string, a `Regex`, or `"*"`; any other value raises
    `ArgumentError` at `init/1`. A `Regex` is matched unanchored, so anchor it:
    `~r/\\Ahttps:\\/\\/example\\.com\\z/`.
    **Unset fails closed**: any request carrying an `Origin` is rejected with
    403, because a warning does not stop a browser from reaching a loopback
    server. Requests *without* an `Origin` always pass — native MCP clients
    are not browsers and don't send one. Pass `allowed_origins: "*"` to allow
    all origins explicitly. See `ConduitMcp.Plugs.OriginValidation`.
  - `:cors_origin` — value for `access-control-allow-origin`. **Unset means no
    CORS headers are emitted at all**, so a page on another origin cannot read
    the response. Set it (e.g. `"https://myapp.example"`, or `"*"`) to opt in.
  - `:cors_methods` — CORS allow-methods header (default:
    `"GET, POST, DELETE, OPTIONS"`; only emitted when `:cors_origin` is set)
  - `:cors_headers` — CORS allow-headers header (default:
    `"content-type, authorization, mcp-session-id, mcp-protocol-version, mcp-method, mcp-name"`;
    only emitted when `:cors_origin` is set). A server whose tools take
    `Mcp-Param-*` headers must list those names here itself:
    `access-control-allow-headers` has no wildcard that holds for
    credentialed requests. Whenever `:cors_origin` is set,
    `access-control-expose-headers: mcp-session-id, mcp-protocol-version` is
    emitted too, so a browser client can read its session id.

  When used via `ConduitMcp.Endpoint`, the `:auth`, `:rate_limit`, and
  `:message_rate_limit` options are auto-extracted from the endpoint config
  unless overridden here.

  ## Example

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP,
              server_module: MyApp.MCPServer,
              cors_origin: "https://myapp.com",
              cors_methods: "POST, OPTIONS",
              cors_headers: "content-type"},
       port: 4001}

  ## With Authentication

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP,
              server_module: MyApp.MCPServer,
              auth: [
                enabled: true,
                strategy: :bearer_token,
                token: "my-secret-token"
              ]},
       port: 4001}

  Or with custom verification:

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP,
              server_module: MyApp.MCPServer,
              auth: [
                strategy: :function,
                verify: &MyApp.Auth.verify_token/1
              ]},
       port: 4001}
  """

  use ConduitMcp.Transport.Shared, extra_plugs: [:validate_session]

  alias ConduitMcp.Session

  # Overrides the default from `use ConduitMcp.Transport.Shared`. `DELETE` is
  # in this transport's default `:cors_methods` because `DELETE /` ends a
  # session; the SSE transport has no such route.
  def __transport_private__(opts) do
    %{
      session_config: validate_session_config!(Keyword.get(opts, :session)),
      cors_methods: Keyword.get(opts, :cors_methods, "GET, POST, DELETE, OPTIONS")
    }
  end

  # Only a keyword list turns sessions on, so accepting any other value would
  # silently mean "no sessions" - and no `require_session`.
  defp validate_session_config!(config) when config in [nil, false], do: config

  defp validate_session_config!(config) when is_list(config) do
    if Keyword.keyword?(config), do: config, else: raise_session_config!(config)
  end

  defp validate_session_config!(config), do: raise_session_config!(config)

  defp raise_session_config!(config) do
    raise ArgumentError,
          ":session must be a keyword list (session: [] enables sessions with " <>
            "ConduitMcp.Session.EtsStore), false, or nil; got #{inspect(config)}"
  end

  # --- transport-specific plugs ----------------------------------------

  # Sessions are on exactly when `:session` is a keyword list; `init/1` has
  # already rejected anything but that, `nil` or `false`. Matches
  # `create_session_for_initialize/2`. `DELETE` is validated exactly like a
  # POST, so a session can only be ended by a request that could have used it.
  #
  # A modern (`2026-07-28`) request has no session: `Mcp-Session-Id` is
  # ignored - neither required nor looked up, so an unknown id is not a 404 -
  # except that `ConduitMcp.Era.classify/2` has already checked a live
  # session's principal binding (R12).
  defp validate_session(conn, _opts) do
    session_config = conn.private[:session_config]

    if is_list(session_config) and conn.method in ["POST", "DELETE"] and
         not Shared.modern?(conn) do
      validate_session_header(conn, session_config)
    else
      conn
    end
  end

  defp validate_session_header(conn, session_config) do
    session_id = get_req_header(conn, "mcp-session-id") |> List.first()
    store = Keyword.get(session_config, :store, Session.EtsStore)

    if is_nil(session_id) do
      # No session header — fine unless the server requires sessions, in
      # which case only `initialize` may go without one (per MCP spec).
      if Keyword.get(session_config, :require_session, false) and
           not initialize_request?(conn) do
        conn
        |> Shared.send_json(
          400,
          ConduitMcp.Protocol.error_response(
            nil,
            ConduitMcp.Protocol.invalid_request(),
            "Mcp-Session-Id header required. Send an initialize request to obtain one."
          )
        )
        |> halt()
      else
        conn
      end
    else
      # Has session header — validate it exists in store
      case Session.get(session_id, store) do
        {:ok, session_data} ->
          conn
          |> Plug.Conn.put_private(:mcp_session_id, session_id)
          |> Plug.Conn.put_private(:mcp_session_data, session_data)

        {:error, :not_found} ->
          conn
          |> Shared.send_json(
            404,
            ConduitMcp.Protocol.error_response(
              nil,
              ConduitMcp.Protocol.invalid_request(),
              "Session not found. Send an initialize request to create a new session."
            )
          )
          |> halt()
      end
    end
  end

  # --- routes -----------------------------------------------------------

  # A GET asking for an event stream is a client opening the optional
  # server-to-client SSE stream. This server offers none, and the
  # specification's answer for that is 405; any other GET gets the info JSON.
  get "/" do
    if event_stream_requested?(conn) do
      method_not_allowed(conn, "This server does not offer an SSE stream at this endpoint.")
    else
      Shared.send_json(conn, 200, %{
        "transport" => "streamable-http",
        "version" => ConduitMcp.Protocol.protocol_version(),
        "status" => "ready"
      })
    end
  end

  # Ends the session named by `Mcp-Session-Id`. `validate_session/2` has
  # already answered an unknown id 404 (and, with `require_session`, a missing
  # one 400), exactly as for a POST.
  delete "/" do
    terminate_session(conn)
  end

  # Main endpoint for bidirectional streaming
  post "/" do
    Shared.dispatch_post(conn, &create_session_for_initialize/2)
  end

  # --- GET / DELETE helpers ---------------------------------------------

  defp event_stream_requested?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp sessions_enabled?(conn), do: is_list(conn.private[:session_config])

  # Without sessions there is nothing for DELETE to end, so the transport
  # does not allow it: the specification's 405.
  defp terminate_session(conn) do
    if sessions_enabled?(conn) do
      end_session(conn, conn.private[:mcp_session_id])
    else
      method_not_allowed(conn, "Sessions are not enabled on this server.")
    end
  end

  defp end_session(conn, nil) do
    Shared.send_json(
      conn,
      400,
      ConduitMcp.Protocol.error_response(
        nil,
        ConduitMcp.Protocol.invalid_request(),
        "Mcp-Session-Id header required to terminate a session."
      )
    )
  end

  defp end_session(conn, session_id) do
    store = Keyword.get(conn.private[:session_config], :store, Session.EtsStore)
    Session.delete(session_id, store)
    send_resp(conn, 200, "")
  end

  defp method_not_allowed(conn, message) do
    allow =
      if sessions_enabled?(conn), do: "GET, POST, DELETE, OPTIONS", else: "GET, POST, OPTIONS"

    conn
    |> put_resp_header("allow", allow)
    |> Shared.send_json(
      405,
      ConduitMcp.Protocol.error_response(nil, ConduitMcp.Protocol.invalid_request(), message)
    )
  end

  Shared.shared_routes()

  # --- session creation on initialize -----------------------------------

  defp initialize_request?(%Plug.Conn{body_params: %{"method" => "initialize"}}), do: true
  defp initialize_request?(_conn), do: false

  defp initialize_response?(%{"result" => %{"protocolVersion" => _, "serverInfo" => _}}),
    do: true

  defp initialize_response?(_response_map), do: false

  # An unconfigured `:session` means no sessions. Issuing them by default gave
  # every unauthenticated client a way to fill the session table with one
  # `initialize` per row.
  defp create_session_for_initialize(conn, response_map) do
    session_config = conn.private[:session_config]

    if is_list(session_config) and initialize_response?(response_map) do
      create_session(conn, response_map, session_config)
    else
      {:ok, conn}
    end
  end

  defp create_session(conn, response_map, session_config) do
    store = Keyword.get(session_config, :store, Session.EtsStore)

    session_id = Session.generate_id()
    protocol_version = get_in(response_map, ["result", "protocolVersion"])

    # The principal is recorded so a modern request that also presents this
    # session id (a "mixed" request) can be checked against it: see
    # `ConduitMcp.Era`. `nil` when the transport has no auth.
    metadata = %{
      "protocol_version" => protocol_version,
      "principal" => ConduitMcp.Principal.id(conn)
    }

    case Session.create(session_id, metadata, store) do
      :ok ->
        {:ok, put_resp_header(conn, "mcp-session-id", session_id)}

      {:error, reason} ->
        # Fail closed. Returning a session-less initialize response would hand
        # the client a half-working connection: the negotiated session simply
        # would not exist on any follow-up request.
        Logger.error("session creation rejected by #{inspect(store)}: #{inspect(reason)}")

        {:error,
         Shared.send_json(
           conn,
           503,
           ConduitMcp.Protocol.error_response(
             conn.body_params["id"],
             ConduitMcp.Protocol.internal_error(),
             "Session store unavailable; the server cannot accept new sessions right now."
           )
         )}
    end
  end
end

defmodule ConduitMcp.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport for MCP (recommended).

  Provides a single POST endpoint for bidirectional communication.
  This is the modern replacement for SSE transport.

  Everything this transport shares with `ConduitMcp.Transport.SSE` — the plug
  pipeline, CORS headers, auth, rate limiting, the JSON-RPC POST dispatch,
  `GET /health`, the RFC 9728 metadata endpoint and the catch-alls — lives in
  `ConduitMcp.Transport.Shared`.

  ## Differences from `ConduitMcp.Transport.SSE`

  - **Sessions are Streamable-HTTP-only, by design.** `Mcp-Session-Id` is
    defined by the Streamable HTTP transport in the MCP specification; the
    legacy SSE transport has no session concept, so `:session` is accepted
    here and nowhere else.

  ## Options

  - `:server_module` (required) — the MCP server module to route requests to
  - `:server_name` — advertised server name in the `initialize` response (falls
    back to the module's `__endpoint_config__/0` if defined)
  - `:server_version` — advertised server version (same fallback behavior)
  - `:auth` — authentication plug configuration. See `ConduitMcp.Plugs.Auth`
    and `ConduitMcp.Plugs.OAuth`. Resolved once, in `init/1`.
  - `:rate_limit` — HTTP-level rate limit configuration. See `ConduitMcp.Plugs.RateLimit`.
  - `:message_rate_limit` — per-message rate limit configuration. See
    `ConduitMcp.Plugs.MessageRateLimit`.
  - `:session` — session-store configuration. Enables `Mcp-Session-Id`
    handling. See `ConduitMcp.Session`. Add `require_session: true` to reject
    non-`initialize` POSTs that omit the `Mcp-Session-Id` header (HTTP 400),
    per the MCP specification's session requirements.
  - `:allowed_origins` — allowlist for the `Origin` header. Accepts a list of
    strings, a bare string, a `Regex`, or `"*"`.
    **Unset fails closed**: any request carrying an `Origin` is rejected with
    403, because a warning does not stop a browser from reaching a loopback
    server. Requests *without* an `Origin` always pass — native MCP clients
    are not browsers and don't send one. Pass `allowed_origins: "*"` to allow
    all origins explicitly. See `ConduitMcp.Plugs.OriginValidation`.
  - `:cors_origin` — value for `access-control-allow-origin`. **Unset means no
    CORS headers are emitted at all**, so a page on another origin cannot read
    the response. Set it (e.g. `"https://myapp.example"`, or `"*"`) to opt in.
  - `:cors_methods` — CORS allow-methods header (default: `"GET, POST, OPTIONS"`;
    only emitted when `:cors_origin` is set)
  - `:cors_headers` — CORS allow-headers header (default:
    `"content-type, authorization"`; only emitted when `:cors_origin` is set)

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

  # Overrides the default from `use ConduitMcp.Transport.Shared`.
  def __transport_private__(opts) do
    %{session_config: Keyword.get(opts, :session)}
  end

  # --- transport-specific plugs ----------------------------------------

  defp validate_session(conn, _opts) do
    session_config = conn.private[:session_config]

    cond do
      # Sessions disabled
      session_config == false ->
        conn

      # No session config (default: sessions optional, don't enforce)
      is_nil(session_config) ->
        conn

      # POST requests need session validation (except initialize)
      conn.method == "POST" ->
        validate_session_header(conn, session_config)

      true ->
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

  # GET endpoint for health check / info
  get "/" do
    Shared.send_json(conn, 200, %{
      "transport" => "streamable-http",
      "version" => ConduitMcp.Protocol.protocol_version(),
      "status" => "ready"
    })
  end

  # Main endpoint for bidirectional streaming
  post "/" do
    Shared.dispatch_post(conn, &create_session_for_initialize/2)
  end

  Shared.shared_routes()

  # --- session creation on initialize -----------------------------------

  defp initialize_request?(%Plug.Conn{body_params: %{"method" => "initialize"}}), do: true
  defp initialize_request?(_conn), do: false

  defp initialize_response?(%{"result" => %{"protocolVersion" => _, "serverInfo" => _}}),
    do: true

  defp initialize_response?(_response_map), do: false

  defp create_session_for_initialize(conn, response_map) do
    session_config = conn.private[:session_config]

    if initialize_response?(response_map) and session_config != false do
      create_session(conn, response_map, session_config)
    else
      {:ok, conn}
    end
  end

  defp create_session(conn, response_map, session_config) do
    store =
      case session_config do
        config when is_list(config) -> Keyword.get(config, :store, Session.EtsStore)
        _ -> Session.EtsStore
      end

    session_id = Session.generate_id()
    protocol_version = get_in(response_map, ["result", "protocolVersion"])

    case Session.create(session_id, %{"protocol_version" => protocol_version}, store) do
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

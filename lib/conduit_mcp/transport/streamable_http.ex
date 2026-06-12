defmodule ConduitMcp.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport for MCP (recommended).

  Provides a single POST endpoint for bidirectional communication.
  This is the modern replacement for SSE transport.

  ## Options

  - `:server_module` (required) — the MCP server module to route requests to
  - `:server_name` — advertised server name in the `initialize` response (falls
    back to the module's `__endpoint_config__/0` if defined)
  - `:server_version` — advertised server version (same fallback behavior)
  - `:auth` — authentication plug configuration. See `ConduitMcp.Plugs.Auth`.
  - `:rate_limit` — HTTP-level rate limit configuration. See `ConduitMcp.Plugs.RateLimit`.
  - `:message_rate_limit` — per-message rate limit configuration. See
    `ConduitMcp.Plugs.MessageRateLimit`.
  - `:session` — session-store configuration. Enables `Mcp-Session-Id`
    handling. See `ConduitMcp.Session`. Add `require_session: true` to reject
    non-`initialize` POSTs that omit the `Mcp-Session-Id` header (HTTP 400),
    per the MCP specification's session requirements.
  - `:allowed_origins` — list of allowed `Origin` header values (also accepts
    `"*"` and regex). See `ConduitMcp.Plugs.OriginValidation`. Unset means no
    Origin validation (a startup warning is logged): requests without an
    `Origin` header always pass because non-browser MCP clients don't send
    one, but browser-originated requests can then reach loopback servers via
    DNS rebinding — set an allowlist for any server a browser could reach.
  - `:cors_origin` — CORS allow-origin header (default: `"*"`)
  - `:cors_methods` — CORS allow-methods header (default: `"GET, POST, OPTIONS"`)
  - `:cors_headers` — CORS allow-headers header (default: `"content-type, authorization"`)

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

  use Plug.Router
  require Logger

  alias ConduitMcp.Handler
  alias ConduitMcp.Session

  plug(Plug.Logger)
  plug(ConduitMcp.Plugs.SecurityHeaders)
  plug(ConduitMcp.Plugs.OriginValidation)
  plug(:add_cors_headers)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, length: 1_000_000)
  plug(:maybe_authenticate)
  plug(:maybe_rate_limit)
  plug(:maybe_message_rate_limit)
  plug(:validate_session)
  plug(:dispatch)

  defp add_cors_headers(conn, _opts) do
    # Get CORS settings from private (set in call/2)
    cors_origin = conn.private[:cors_origin] || "*"
    cors_methods = conn.private[:cors_methods] || "GET, POST, OPTIONS"
    cors_headers = conn.private[:cors_headers] || "content-type, authorization"

    conn
    |> put_resp_header("access-control-allow-origin", cors_origin)
    |> put_resp_header("access-control-allow-methods", cors_methods)
    |> put_resp_header("access-control-allow-headers", cors_headers)
  end

  defp maybe_authenticate(conn, _opts) do
    case conn.private[:auth_config] do
      nil ->
        conn

      auth_opts ->
        strategy = Keyword.get(auth_opts, :strategy)

        if strategy == :oauth and Code.ensure_loaded?(ConduitMcp.Plugs.OAuth) do
          # apply/3 keeps the optional OAuth plug (compiled only when Joken is
          # present) from producing undefined-module compile warnings
          # credo:disable-for-lines:4 Credo.Check.Refactor.Apply
          apply(ConduitMcp.Plugs.OAuth, :call, [
            conn,
            apply(ConduitMcp.Plugs.OAuth, :init, [auth_opts])
          ])
        else
          ConduitMcp.Plugs.Auth.call(conn, ConduitMcp.Plugs.Auth.init(auth_opts))
        end
    end
  end

  defp maybe_rate_limit(conn, _opts) do
    case conn.private[:rate_limit_config] do
      nil ->
        conn

      rate_limit_opts ->
        ConduitMcp.Plugs.RateLimit.call(conn, ConduitMcp.Plugs.RateLimit.init(rate_limit_opts))
    end
  end

  defp maybe_message_rate_limit(conn, _opts) do
    case conn.private[:message_rate_limit_config] do
      nil ->
        conn

      message_rate_limit_opts ->
        ConduitMcp.Plugs.MessageRateLimit.call(
          conn,
          ConduitMcp.Plugs.MessageRateLimit.init(message_rate_limit_opts)
        )
    end
  end

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
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          JSON.encode!(
            ConduitMcp.Protocol.error_response(
              nil,
              ConduitMcp.Protocol.invalid_request(),
              "Mcp-Session-Id header required. Send an initialize request to obtain one."
            )
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
          |> put_resp_content_type("application/json")
          |> send_resp(
            404,
            JSON.encode!(
              ConduitMcp.Protocol.error_response(
                nil,
                ConduitMcp.Protocol.invalid_request(),
                "Session not found. Send an initialize request to create a new session."
              )
            )
          )
          |> halt()
      end
    end
  end

  def init(opts) do
    server_module = Keyword.get(opts, :server_module)

    if is_nil(server_module) do
      raise ArgumentError, "server_module is required"
    end

    warn_if_origins_unset(opts, __MODULE__)

    opts
  end

  @doc false
  # Shared by both transports. Warns once per boot (init/1) when no Origin
  # policy was chosen at all; pass `allowed_origins: "*"` to opt out explicitly.
  def warn_if_origins_unset(opts, transport) do
    unless Keyword.has_key?(opts, :allowed_origins) do
      Logger.warning(
        "#{inspect(transport)}: no :allowed_origins configured — Origin headers are " <>
          "not validated, which leaves browser-reachable servers open to DNS-rebinding " <>
          "attacks. Set allowed_origins: [\"https://yourapp.example\"] per the MCP " <>
          "specification, or allowed_origins: \"*\" to opt out explicitly."
      )
    end

    :ok
  end

  def call(conn, opts) do
    server_module = Keyword.get(opts, :server_module)

    # Extract endpoint config as defaults (explicit transport opts always win)
    endpoint_config =
      if server_module && function_exported?(server_module, :__endpoint_config__, 0),
        do: server_module.__endpoint_config__(),
        else: []

    cors_origin = Keyword.get(opts, :cors_origin, "*")
    cors_methods = Keyword.get(opts, :cors_methods, "GET, POST, OPTIONS")
    cors_headers = Keyword.get(opts, :cors_headers, "content-type, authorization")
    auth_config = Keyword.get(opts, :auth) || Keyword.get(endpoint_config, :auth)

    rate_limit_config =
      Keyword.get(opts, :rate_limit) || Keyword.get(endpoint_config, :rate_limit)

    message_rate_limit_config =
      Keyword.get(opts, :message_rate_limit) ||
        Keyword.get(endpoint_config, :message_rate_limit)

    server_name = Keyword.get(opts, :server_name) || Keyword.get(endpoint_config, :name)
    server_version = Keyword.get(opts, :server_version) || Keyword.get(endpoint_config, :version)
    session_config = Keyword.get(opts, :session)
    allowed_origins = Keyword.get(opts, :allowed_origins)

    private = %{
      server_module: server_module,
      allowed_origins: allowed_origins,
      cors_origin: cors_origin,
      cors_methods: cors_methods,
      cors_headers: cors_headers,
      auth_config: auth_config,
      rate_limit_config: rate_limit_config,
      message_rate_limit_config: message_rate_limit_config,
      server_name: server_name,
      server_version: server_version,
      session_config: session_config
    }

    %{conn | private: Map.merge(conn.private, private)}
    |> super(opts)
  end

  # CORS preflight
  options _ do
    send_resp(conn, 200, "")
  end

  # GET endpoint for health check / info
  get "/" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      JSON.encode!(%{
        "transport" => "streamable-http",
        "version" => ConduitMcp.Protocol.protocol_version(),
        "status" => "ready"
      })
    )
  end

  # Main endpoint for bidirectional streaming
  post "/" do
    server_module = conn.private[:server_module]
    session_config = conn.private[:session_config]

    case conn.body_params do
      params when is_map(params) ->
        Logger.debug("Received request", method: params["method"], id: params["id"])

        response = Handler.handle_request(params, server_module, conn)

        case response do
          :ok ->
            # It was a notification, no response needed
            send_resp(conn, 204, "")

          response_map when is_map(response_map) ->
            conn = add_mcp_protocol_version_header(conn)

            conn =
              if initialize_response?(response_map) and session_config != false do
                create_session_for_initialize(conn, response_map, session_config)
              else
                conn
              end

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, JSON.encode!(response_map))
        end

      _ ->
        error_response =
          ConduitMcp.Protocol.error_response(
            nil,
            ConduitMcp.Protocol.invalid_request(),
            "Request body must be valid JSON"
          )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, JSON.encode!(error_response))
    end
  end

  # Health check endpoint
  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{status: "ok"}))
  end

  # OAuth Protected Resource Metadata (RFC 9728)
  get "/.well-known/oauth-protected-resource" do
    case conn.private[:auth_config] do
      auth_config when is_list(auth_config) and auth_config != [] ->
        strategy = Keyword.get(auth_config, :strategy)

        if strategy == :oauth do
          metadata = ConduitMcp.OAuth.ResourceMetadata.build(auth_config)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(metadata))
        else
          send_resp(conn, 404, "Not found")
        end

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  # Catch all
  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp add_mcp_protocol_version_header(conn) do
    put_resp_header(conn, "mcp-protocol-version", ConduitMcp.Protocol.protocol_version())
  end

  defp initialize_request?(%Plug.Conn{body_params: %{"method" => "initialize"}}), do: true
  defp initialize_request?(_conn), do: false

  defp initialize_response?(response_map) do
    case response_map do
      %{"result" => %{"protocolVersion" => _, "serverInfo" => _}} -> true
      _ -> false
    end
  end

  defp create_session_for_initialize(conn, response_map, session_config) do
    store =
      case session_config do
        config when is_list(config) -> Keyword.get(config, :store, Session.EtsStore)
        _ -> Session.EtsStore
      end

    session_id = Session.generate_id()
    protocol_version = get_in(response_map, ["result", "protocolVersion"])

    Session.create(
      session_id,
      %{"protocol_version" => protocol_version},
      store
    )

    put_resp_header(conn, "mcp-session-id", session_id)
  end
end

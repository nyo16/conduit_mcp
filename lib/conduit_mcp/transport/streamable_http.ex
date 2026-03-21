defmodule ConduitMcp.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport for MCP (recommended).

  Provides a single POST endpoint for bidirectional communication.
  This is the modern replacement for SSE transport.

  ## Options

  - `:server_module` (required) - The MCP server module to route requests to
  - `:cors_origin` - CORS allow-origin header (default: "*")
  - `:cors_methods` - CORS allow-methods header (default: "GET, POST, OPTIONS")
  - `:cors_headers` - CORS allow-headers header (default: "content-type, authorization")
  - `:auth` - Authentication plug configuration (optional)

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
  plug(:validate_origin)
  plug(:add_cors_headers)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:maybe_authenticate)
  plug(:maybe_rate_limit)
  plug(:maybe_message_rate_limit)
  plug(:validate_session)
  plug(:dispatch)

  defp validate_origin(conn, _opts) do
    allowed_origins = conn.private[:allowed_origins]

    cond do
      # No origin restriction configured, or explicitly set to "*"
      is_nil(allowed_origins) or allowed_origins == "*" ->
        conn

      # OPTIONS requests skip origin validation (CORS preflight)
      conn.method == "OPTIONS" ->
        conn

      true ->
        origin = get_req_header(conn, "origin") |> List.first()

        cond do
          # No Origin header — allow (browser-less clients don't send it)
          is_nil(origin) ->
            conn

          # Origin matches allowed list
          is_list(allowed_origins) and origin in allowed_origins ->
            conn

          # Origin doesn't match
          true ->
            Logger.warning("Blocked request from disallowed origin: #{origin}")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{"error" => "Origin not allowed"}))
            |> halt()
        end
    end
  end

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
        # No auth configured
        conn

      auth_opts ->
        # Apply auth plug
        ConduitMcp.Plugs.Auth.call(conn, ConduitMcp.Plugs.Auth.init(auth_opts))
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
      # No session header — only allowed for initialize requests
      conn
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
            Jason.encode!(
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

    opts
  end

  def call(conn, opts) do
    server_module = Keyword.get(opts, :server_module)
    cors_origin = Keyword.get(opts, :cors_origin, "*")
    cors_methods = Keyword.get(opts, :cors_methods, "GET, POST, OPTIONS")
    cors_headers = Keyword.get(opts, :cors_headers, "content-type, authorization")
    auth_config = Keyword.get(opts, :auth)
    rate_limit_config = Keyword.get(opts, :rate_limit)
    message_rate_limit_config = Keyword.get(opts, :message_rate_limit)
    server_name = Keyword.get(opts, :server_name)
    server_version = Keyword.get(opts, :server_version)
    session_config = Keyword.get(opts, :session)
    allowed_origins = Keyword.get(opts, :allowed_origins)

    conn
    |> Plug.Conn.put_private(:server_module, server_module)
    |> Plug.Conn.put_private(:allowed_origins, allowed_origins)
    |> Plug.Conn.put_private(:cors_origin, cors_origin)
    |> Plug.Conn.put_private(:cors_methods, cors_methods)
    |> Plug.Conn.put_private(:cors_headers, cors_headers)
    |> Plug.Conn.put_private(:auth_config, auth_config)
    |> Plug.Conn.put_private(:rate_limit_config, rate_limit_config)
    |> Plug.Conn.put_private(:message_rate_limit_config, message_rate_limit_config)
    |> Plug.Conn.put_private(:server_name, server_name)
    |> Plug.Conn.put_private(:server_version, server_version)
    |> Plug.Conn.put_private(:session_config, session_config)
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
      Jason.encode!(%{
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
        Logger.debug("Received request: #{inspect(params)}")

        response = Handler.handle_request(params, server_module, conn)

        case response do
          :ok ->
            # It was a notification, no response needed
            send_resp(conn, 204, "")

          response_map when is_map(response_map) ->
            conn = add_mcp_protocol_version_header(conn)

            conn =
              if is_initialize_response?(response_map) and session_config != false do
                create_session_for_initialize(conn, response_map, session_config)
              else
                conn
              end

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response_map))
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
        |> send_resp(400, Jason.encode!(error_response))
    end
  end

  # Health check endpoint
  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  # Catch all
  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp add_mcp_protocol_version_header(conn) do
    put_resp_header(conn, "mcp-protocol-version", ConduitMcp.Protocol.protocol_version())
  end

  defp is_initialize_response?(response_map) do
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

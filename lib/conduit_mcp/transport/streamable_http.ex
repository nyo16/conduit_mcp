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

  ## Example

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP,
              server_module: MyApp.MCPServer,
              cors_origin: "https://myapp.com",
              cors_methods: "POST, OPTIONS",
              cors_headers: "content-type"},
       port: 4001}
  """

  use Plug.Router
  require Logger

  alias ConduitMcp.Handler

  plug(Plug.Logger)
  plug(:add_cors_headers)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
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

    conn
    |> Plug.Conn.put_private(:server_module, server_module)
    |> Plug.Conn.put_private(:cors_origin, cors_origin)
    |> Plug.Conn.put_private(:cors_methods, cors_methods)
    |> Plug.Conn.put_private(:cors_headers, cors_headers)
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
    |> send_resp(200, Jason.encode!(%{
      "transport" => "streamable-http",
      "version" => "2025-06-18",
      "status" => "ready"
    }))
  end

  # Main endpoint for bidirectional streaming
  post "/" do
    server_module = conn.private[:server_module]

    case conn.body_params do
      params when is_map(params) ->
        Logger.debug("Received request: #{inspect(params)}")

        response = Handler.handle_request(params, server_module, conn)

        case response do
          :ok ->
            # It was a notification, no response needed
            send_resp(conn, 204, "")

          response_map when is_map(response_map) ->
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
end

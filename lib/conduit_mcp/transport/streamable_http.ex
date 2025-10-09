defmodule ConduitMcp.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport for MCP (recommended).

  Provides a single POST endpoint for bidirectional communication.
  This is the modern replacement for SSE transport.
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
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
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
    conn = Plug.Conn.put_private(conn, :server_module, server_module)
    super(conn, opts)
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

        response = Handler.handle_request(params, server_module)

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

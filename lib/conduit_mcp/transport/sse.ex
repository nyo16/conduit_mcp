defmodule ConduitMcp.Transport.SSE do
  @moduledoc """
  Server-Sent Events (SSE) transport layer for MCP.

  Provides two endpoints:
  - GET /sse - Server-Sent Events stream for server-to-client messages
  - POST /message - HTTP endpoint for client-to-server messages

  ## Options

  - `:server_module` (required) - The MCP server module to route requests to
  - `:cors_origin` - CORS allow-origin header (default: "*")
  - `:cors_methods` - CORS allow-methods header (default: "GET, POST, OPTIONS")
  - `:cors_headers` - CORS allow-headers header (default: "content-type, authorization")

  ## Example

      {Bandit,
       plug: {ConduitMcp.Transport.SSE,
              server_module: MyApp.MCPServer,
              cors_origin: "https://myapp.com"},
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

  # SSE endpoint for server-to-client streaming
  get "/sse" do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
    |> send_sse_endpoint_info()
  end

  # Message endpoint for client-to-server requests
  post "/message" do
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

  defp send_sse_endpoint_info(conn) do
    # Build the full endpoint URL
    # Get the host from the connection
    host = get_req_header(conn, "host") |> List.first() || "localhost:4001"
    scheme = if conn.scheme == :https, do: "https", else: "http"
    endpoint_url = "#{scheme}://#{host}/message"

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

  defp keep_alive_loop(conn) do
    # Send periodic keepalive comments
    :timer.sleep(15_000)

    case chunk(conn, ": keepalive\n\n") do
      {:ok, conn} ->
        keep_alive_loop(conn)

      {:error, _reason} ->
        # Client disconnected
        conn
    end
  end
end

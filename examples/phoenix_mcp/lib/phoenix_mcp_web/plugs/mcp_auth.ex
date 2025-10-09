defmodule PhoenixMcpWeb.Plugs.MCPAuth do
  @moduledoc """
  Authentication plug for MCP endpoints.

  Supports bearer token authentication with configurable verification.

  ## Configuration

  Pass one of the following options when using this plug:

  - `:enabled` - Set to `false` to disable auth (default: true)
  - `:token` - A static bearer token to check against
  - `:verify_token` - A function that takes a token and returns `{:ok, metadata}` or `:error`

  ## Examples

      # No authentication (development only!)
      plug PhoenixMcpWeb.Plugs.MCPAuth, enabled: false

      # Static token
      plug PhoenixMcpWeb.Plugs.MCPAuth, token: "my-secret-token"

      # Custom verification function
      plug PhoenixMcpWeb.Plugs.MCPAuth,
        verify_token: fn token ->
          if MyApp.Auth.valid_mcp_token?(token) do
            {:ok, %{user_id: "123"}}
          else
            :error
          end
        end
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      verify_auth(conn, opts)
    else
      conn
    end
  end

  defp verify_auth(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        verify_token(conn, token, opts)

      ["bearer " <> token] ->
        verify_token(conn, token, opts)

      _ ->
        unauthorized(conn, "Missing or invalid Authorization header")
    end
  end

  defp verify_token(conn, token, opts) do
    cond do
      # Option 1: Static token
      static_token = Keyword.get(opts, :token) ->
        if token == static_token do
          conn
        else
          unauthorized(conn, "Invalid token")
        end

      # Option 2: Custom verification function
      verify_fn = Keyword.get(opts, :verify_token) ->
        case verify_fn.(token) do
          {:ok, metadata} ->
            # Store auth metadata in conn for later use
            put_private(conn, :mcp_auth_metadata, metadata)

          :error ->
            unauthorized(conn, "Invalid token")
        end

      # No auth configured
      true ->
        Logger.warning(
          "MCPAuth plug enabled but no token or verify_token configured. " <>
            "Set enabled: false to disable auth, or provide :token or :verify_token option."
        )

        unauthorized(conn, "Authentication not configured")
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end

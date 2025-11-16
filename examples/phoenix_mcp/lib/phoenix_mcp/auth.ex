defmodule PhoenixMcp.Auth do
  @moduledoc """
  Example authentication module for MCP server.

  This module demonstrates how to implement custom token verification
  for use with ConduitMcp.Plugs.Auth.
  """

  @doc """
  Verifies an MCP authentication token.

  This is an example implementation. In production, you would:
  - Look up the token in a database
  - Verify JWT tokens
  - Check against an OAuth2 provider
  - Validate API keys against a service

  ## Example Usage

  In your router:

      forward "/mcp", ConduitMcp.Transport.StreamableHTTP,
        server_module: PhoenixMcp.MCPServer,
        auth: [
          strategy: :function,
          verify: &PhoenixMcp.Auth.verify_token/1
        ]
  """
  def verify_token(token) do
    # Example: Simple hardcoded token (don't use in production!)
    case token do
      "dev-token-123" ->
        {:ok, %{user_id: "dev-user", role: :developer}}

      "admin-token-456" ->
        {:ok, %{user_id: "admin-user", role: :admin}}

      _ ->
        {:error, "Invalid token"}
    end
  end

  @doc """
  Example: Database token verification.

  In production, you might do something like:

      def verify_token(token) do
        case PhoenixMcp.Repo.get_by(ApiToken, token: token, active: true) do
          %ApiToken{user: user} ->
            {:ok, user}

          nil ->
            {:error, "Invalid or expired token"}
        end
      end
  """
  def verify_token_db(_token) do
    # Placeholder for database verification example
    {:error, "Not implemented"}
  end

  @doc """
  Example: JWT token verification.

  In production with a JWT library:

      def verify_jwt_token(token) do
        case MyApp.Guardian.decode_and_verify(token) do
          {:ok, claims} ->
            user = PhoenixMcp.Accounts.get_user!(claims["sub"])
            {:ok, user}

          {:error, _reason} ->
            {:error, "Invalid JWT"}
        end
      end
  """
  def verify_jwt_token(_token) do
    # Placeholder for JWT verification example
    {:error, "Not implemented"}
  end
end

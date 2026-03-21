defmodule ConduitMcp.OAuth.ResourceMetadata do
  @moduledoc """
  Generates OAuth 2.0 Protected Resource Metadata (RFC 9728) for MCP servers.

  This metadata document tells OAuth clients how to discover the authorization
  server and what scopes are available for this MCP resource server.

  ## Endpoint

  Served at `GET /.well-known/oauth-protected-resource`

  ## Response Format

      {
        "resource": "https://mcp.example.com",
        "authorization_servers": ["https://auth.example.com"],
        "scopes_supported": ["read", "write", "admin"],
        "bearer_methods_supported": ["header"]
      }
  """

  @doc """
  Builds the Protected Resource Metadata document from OAuth config.
  """
  def build(oauth_config) do
    resource_uri = oauth_config[:resource_uri] || oauth_config[:audience]
    issuer = oauth_config[:issuer]
    scopes = oauth_config[:scopes_supported] || []

    metadata = %{
      "resource" => resource_uri,
      "authorization_servers" => [issuer],
      "bearer_methods_supported" => ["header"]
    }

    if scopes != [] do
      Map.put(metadata, "scopes_supported", scopes)
    else
      metadata
    end
  end
end

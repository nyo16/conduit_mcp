if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.ClientCredentials do
    @moduledoc """
    Machine-to-machine authorization: the OAuth 2.1 `client_credentials`
    grant (the MCP `io.modelcontextprotocol/oauth-client-credentials`
    extension). No user and no browser: the client authenticates as itself
    and gets a token for the MCP server. Compiled only with `:finch`.

        {ConduitMcp.Client,
         name: :reports,
         transport:
           {ConduitMcp.Client.Transport.StreamableHTTP,
            url: "https://mcp.example.com/mcp",
            auth:
              {:client_credentials,
               client_id: "reporting-service",
               client_secret: {:system, "MCP_CLIENT_SECRET"},
               scopes: ["reports:read"]}}}

    Discovery is the same as for the authorization-code flow (Protected
    Resource Metadata, then the authorization server's metadata; `S256` and
    an `authorization_endpoint` are not required). The token request
    carries `resource` (RFC 8707) and `scope` (the configured `:scopes`,
    else the server's `scopes_supported`), and authenticates the client
    with:

      * `client_secret` - a string, a `ConduitMcp.Client.Secret` or
        `{:system, "VAR"}` (read from the environment on every token
        request, never kept), sent as `client_secret_basic` (default) or
        `client_secret_post` (`token_endpoint_auth_method:`);
      * `private_key` - a private JWK map or PEM for `private_key_jwt`
        (RFC 7523): a signed assertion with `aud` = the token endpoint.
        Needs the optional `:jose` dependency, checked when the options
        are validated.

    Tokens are cached in the token store under `{principal, issuer,
    resource}` like any other, and renewed by requesting a new one when
    they expire (within `refresh_skew`), single-flight. A step-up (403
    `insufficient_scope`) requests a new token for the union of the held and
    challenged scopes, within `max_step_up_attempts`.

    `ConduitMcp.Client.OAuth.token_for/2` returns the current token; this
    module holds the token request itself.
    """

    alias ConduitMcp.Client.OAuth.{Config, Scopes, Session, TokenEndpoint}
    alias ConduitMcp.Client.OAuth.Telemetry

    @doc false
    # A new token for `scopes` (nil: the configured scopes, else the PRM's
    # `scopes_supported`), stored under `key`. Call it under the store's
    # lock (`ConduitMcp.Client.OAuth.TokenStore.transaction/3`).
    @spec request(Session.t(), term(), [String.t()] | nil) ::
            {:ok, ConduitMcp.Client.OAuth.Tokens.t()}
            | {:error, ConduitMcp.Client.OAuth.Error.t()}
    def request(%Session{config: config, context: context}, key, scopes) do
      scopes = requested(config, context, scopes)

      Telemetry.span(
        :token_exchange,
        Map.put(Telemetry.base(config), :grant, :client_credentials),
        fn ->
          params =
            [grant_type: "client_credentials", resource: context.resource] ++
              if(scopes == [], do: [], else: [scope: Scopes.join(scopes)])

          result =
            case TokenEndpoint.request(
                   config,
                   context.metadata["token_endpoint"],
                   config.credentials,
                   params,
                   scopes
                 ) do
              {:ok, tokens, _scopes} -> Session.persist(config, key, tokens)
              error -> error
            end

          {result, %{}}
        end
      )
    end

    defp requested(_config, _context, [_ | _] = scopes), do: scopes
    defp requested(%Config{scopes: [_ | _] = scopes}, _context, _given), do: scopes
    defp requested(_config, %{prm: prm}, _given), do: Map.get(prm, "scopes_supported", [])
  end
end

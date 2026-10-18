if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth do
    @moduledoc """
    OAuth 2.1 for the MCP client (the MCP authorization spec, both protocol
    eras, Streamable HTTP only). Compiled only with the optional `:finch`
    dependency.

    ## Wiring

        {ConduitMcp.Client,
         name: :docs,
         transport:
           {ConduitMcp.Client.Transport.StreamableHTTP,
            url: "https://mcp.example.com/mcp",
            auth:
              {:oauth,
               redirect_uri: "https://app.example.com/oauth/callback",
               client_metadata_url: "https://app.example.com/oauth/client.json",
               on_authorization_required: &MyApp.MCPAuth.prompt/1}}}

    See `ConduitMcp.Client.OAuth.Config` for every option, and
    `ConduitMcp.Client.OAuth.ClientCredentials` for machine-to-machine
    clients.

    ## What the client does on its own

      * Attaches `Authorization: Bearer` to every request to the MCP server
        (including `server/discover`), and only to it: never to metadata,
        registration or token requests, never across a redirect.
      * Refreshes a token that expires within `refresh_skew` seconds before
        sending it, and after a 401 - single-flight across all processes
        sharing the token store, persisting rotated refresh tokens.
      * Discovers the authorization server (`ConduitMcp.Client.OAuth.Discovery.Fetch`)
        and chooses a client identity (`ConduitMcp.Client.OAuth.Registration`).

    ## What the host does: interactive authorization

    When no usable token exists, the user has to authorize in a browser.
    The client **never blocks** on that and never opens a browser:

      1. The request fails with `{:error, %ConduitMcp.Client.Error{kind:
         :auth, reason: :authorization_required, data: %{challenge:
         challenge}}}`, the connection enters `:authorizing`, and
         `on_authorization_required` receives the
         `ConduitMcp.Client.OAuth.Challenge` (in a task).
      2. The host calls `authorize_url/2` with the client's name and the
         challenge, stores the returned `ConduitMcp.Client.OAuth.Pending`
         (server-side or encrypted: it holds the PKCE verifier and `state`)
         and sends the user to the URL.
      3. The authorization server redirects to the redirect URI. The host
         looks the pending authorization up by `state` **and deletes it**
         (single use), then calls `handle_callback/3`. The tokens are stored
         and the connection resumes at once.

    A CLI or desktop app can let `ConduitMcp.Client.OAuth.Loopback` run
    steps 2-3 with a one-shot server on `127.0.0.1`.

    While waiting, every request fails fast with `:authorization_required`.
    A request also re-reads the store, so tokens stored by other means are
    picked up; `ConduitMcp.Client.authorized/1` does the same explicitly.

    ## Step-up

    A 403 with `error="insufficient_scope"` fails that request with
    `:authorization_required` and a challenge for the **union** of the
    scopes already requested and the challenged ones (MCP 2026-07-28; used
    for both eras). The host authorizes again as above. At most
    `max_step_up_attempts` (2) step-ups are made per resource and scope set;
    beyond that the request fails with `:step_up_limit` (OA-10).

    ## Errors

    The functions here return `{:error, %ConduitMcp.Client.OAuth.Error{}}`
    (see its reasons), or a `ConduitMcp.Client.Error` when a running client
    named by `client_or_config` cannot be reached.
    """

    alias ConduitMcp.Client.Error, as: ClientError

    alias ConduitMcp.Client.OAuth.{
      Callback,
      Challenge,
      Config,
      Error,
      Pending,
      PKCE,
      Registration,
      Scopes,
      Session,
      TokenEndpoint,
      Tokens
    }

    alias ConduitMcp.Client.OAuth.Telemetry
    alias ConduitMcp.Client.Request
    alias ConduitMcp.Client.Secret

    @typedoc """
    A running client's name, an `ConduitMcp.Client.OAuth.Config`, or OAuth
    options for one (with `:server_url`).
    """
    @type client_or_config :: term() | Config.t() | keyword()

    @control_timeout 5_000

    @doc """
    Starts an authorization: discovery (always afresh, so an authorization
    server the server switched to is found), client registration, PKCE and
    `state`. Returns the URL to send the user
    to and the pending authorization the callback needs.

    ## Options

      * `:challenge` - the `ConduitMcp.Client.OAuth.Challenge` the client
        reported; its `resource_metadata` and `scope` are used.
      * `:scopes` - the scopes to request. Default: the challenge's, else
        the server's `scopes_supported`, else the configured `:scopes`
        (none ⇒ no `scope` parameter).
      * `:redirect_uri` - overrides the configured one.
      * `:principal` - the identity to bind the flow and its tokens to.
        Default: the configured `:principal`.
    """
    @spec authorize_url(client_or_config(), keyword()) ::
            {:ok, String.t(), Pending.t()} | {:error, Error.t() | ClientError.t()}
    def authorize_url(client_or_config, opts \\ []) do
      challenge = Keyword.get(opts, :challenge)

      # Discovery runs afresh: the server may have named another
      # authorization server since the client last looked (OA-6).
      with {:ok, session} <- session(client_or_config),
           {:ok, session} <- Session.ensure_context(%{session | context: nil}, challenge),
           {:ok, redirect_uri} <- redirect_uri(session.config, opts),
           %{config: config, context: context} = session,
           {:ok, client} <-
             Registration.resolve(config, context.issuer, context.metadata,
               redirect_uri: redirect_uri
             ) do
        scopes = scopes(config, context, challenge, opts)

        pending =
          Pending.new(
            redirect_uri: redirect_uri,
            issuer: context.issuer,
            resource: context.resource,
            scopes: scopes,
            principal: Keyword.get(opts, :principal, config.principal),
            iss_parameter_supported:
              context.metadata["authorization_response_iss_parameter_supported"] == true,
            client_id: client.client_id,
            token_endpoint: context.metadata["token_endpoint"],
            now: Config.now(config)
          )

        {:ok, url(context.metadata["authorization_endpoint"], client, pending), pending}
      end
    end

    defp redirect_uri(config, opts) do
      case Keyword.get(opts, :redirect_uri, config.redirect_uri) do
        nil ->
          Error.error(:invalid_url, :missing_redirect_uri)

        uri ->
          case Pending.validate_redirect_uri(uri) do
            {:ok, uri} -> {:ok, uri}
            {:error, _message} -> Error.error(:invalid_url, :redirect_uri)
          end
      end
    end

    defp scopes(config, context, challenge, opts) do
      challenged = if challenge, do: Challenge.scopes(challenge), else: []
      supported = Map.get(context.prm, "scopes_supported", [])

      cond do
        Keyword.has_key?(opts, :scopes) -> Keyword.fetch!(opts, :scopes)
        challenged != [] -> challenged
        supported != [] -> supported
        true -> config.scopes
      end
    end

    defp url(endpoint, client, pending) do
      params =
        [
          {"response_type", "code"},
          {"client_id", client.client_id},
          {"redirect_uri", pending.redirect_uri},
          {"code_challenge", Pending.code_challenge(pending)},
          {"code_challenge_method", PKCE.method()},
          {"state", Secret.expose(pending.state)},
          {"resource", pending.resource}
        ] ++
          case Scopes.join(pending.scopes) do
            nil -> []
            scope -> [{"scope", scope}]
          end

      uri = URI.parse(endpoint)
      query = URI.encode_query(params, :rfc3986)

      query =
        if uri.query in [nil, ""], do: query, else: uri.query <> "&" <> query

      URI.to_string(%{uri | query: query})
    end

    @doc """
    Completes an authorization: validates the response (`state` in
    constant time, the principal, the expiry, then RFC 9207 `iss` - all
    before any token request; see `ConduitMcp.Client.OAuth.Callback`),
    redeems the code with the same `redirect_uri`, `resource` and PKCE
    verifier, and stores the tokens under `{principal, issuer, resource}`.

    The host must look `pending` up by the response's `state` and delete it
    first: `state` is single use.

    ## Options

      * `:client` - the running client's name, or `:config` - its OAuth
        configuration (one is required). With `:client` the connection is
        told the tokens are stored (`ConduitMcp.Client.authorized/1`).
      * `:principal` - the identity completing the flow; must equal the one
        that started it. Default: the configured `:principal`.
    """
    @spec handle_callback(Pending.t(), map(), keyword()) ::
            {:ok, Tokens.t()} | {:error, Error.t() | ClientError.t()}
    def handle_callback(%Pending{} = pending, params, opts) when is_map(params) do
      target = Keyword.get_lazy(opts, :client, fn -> Keyword.fetch!(opts, :config) end)

      with {:ok, session} <- session(target),
           config = session.config,
           {:ok, code} <-
             Callback.validate(pending, params,
               principal: Keyword.get(opts, :principal, config.principal),
               now: Config.now(config)
             ),
           {:ok, tokens} <- exchange(session, pending, code) do
        if Keyword.has_key?(opts, :client), do: ConduitMcp.Client.authorized(target)
        {:ok, tokens}
      end
    end

    defp exchange(%Session{config: config} = session, pending, code) do
      meta = Map.put(Telemetry.base(config), :grant, :authorization_code)

      Telemetry.span(:token_exchange, meta, fn ->
        result =
          with {:ok, endpoint} <- token_endpoint(pending),
               {:ok, client} <- callback_client(session, pending) do
            params = [
              grant_type: "authorization_code",
              code: Secret.expose(code),
              redirect_uri: pending.redirect_uri,
              code_verifier: Secret.expose(pending.verifier),
              resource: pending.resource
            ]

            case TokenEndpoint.request(config, endpoint, client, params, pending.scopes) do
              {:ok, tokens, _scopes} ->
                Session.persist(
                  config,
                  {pending.principal, pending.issuer, pending.resource},
                  tokens
                )

              error ->
                error
            end
          end

        {result, %{}}
      end)
    end

    defp token_endpoint(%Pending{token_endpoint: endpoint}) when is_binary(endpoint),
      do: {:ok, endpoint}

    defp token_endpoint(_pending), do: Error.error(:invalid_pending, %{field: "token_endpoint"})

    # The client that started the flow: its credentials when it is a
    # pre-registered or dynamically registered confidential client of the
    # same issuer, else a public client with the recorded id.
    defp callback_client(%Session{config: config, context: context}, pending) do
      public = %{
        client_id: pending.client_id,
        auth_method: :none,
        secret: nil,
        private_key: nil,
        alg: "RS256",
        kid: nil
      }

      cond do
        pending.client_id == nil ->
          Error.error(:invalid_pending, %{field: "client_id"})

        context != nil and context.issuer == pending.issuer ->
          case Registration.resolve(config, pending.issuer, context.metadata, register: false) do
            {:ok, %{client_id: id} = client} when id == pending.client_id -> {:ok, client}
            _other -> {:ok, public}
          end

        true ->
          case Map.fetch(config.pre_registered, pending.issuer) do
            {:ok, %{client_id: id} = client} when id == pending.client_id -> {:ok, client}
            _other -> {:ok, public}
          end
      end
    end

    @doc """
    The current tokens for `principal`, refreshed first (single-flight) when
    they expire within `refresh_skew`. `{:error, %OAuth.Error{reason:
    :authorization_required}}` when there are none and the user must
    authorize. A client-credentials configuration requests a token instead.

    With a `ConduitMcp.Client.OAuth.Config`, discovery runs on every call;
    with a running client's name, its discovered context is reused.
    """
    @spec token_for(client_or_config(), term()) ::
            {:ok, Tokens.t()} | {:error, Error.t() | ClientError.t()}
    def token_for(client_or_config, principal \\ :default) do
      with {:ok, session} <- session(client_or_config) do
        Session.token(session, principal)
      end
    end

    @doc """
    Refreshes the tokens of `principal` now (single-flight: a caller that
    waited for another's refresh gets that result). `invalid_grant` deletes
    them and returns `:authorization_required`.
    """
    @spec refresh(client_or_config(), term()) ::
            {:ok, Tokens.t()} | {:error, Error.t() | ClientError.t()}
    def refresh(client_or_config, principal \\ :default) do
      with {:ok, session} <- session(client_or_config) do
        Session.refresh(session, principal)
      end
    end

    # --- the session ---------------------------------------------------------

    defp session(%Config{server_url: url} = config) when is_binary(url),
      do: {:ok, Session.new(config)}

    defp session(%Config{}), do: Error.error(:invalid_url, :missing_server_url)

    defp session(opts) when is_list(opts) do
      case Config.new(opts) do
        {:ok, config} -> session(config)
        {:error, message} -> raise ArgumentError, message
      end
    end

    defp session(client) do
      case Request.call(client, :oauth_session, @control_timeout) do
        {:ok, %Session{} = session} -> {:ok, session}
        {:error, %ClientError{}} = error -> error
      end
    end
  end
end

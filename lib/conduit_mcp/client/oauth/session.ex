if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.Session do
    @moduledoc false

    # The OAuth state of one client and the operations its processes run:
    # an `ConduitMcp.Client.OAuth.Config` plus what discovery found (the
    # canonical resource, the issuer and its metadata - no secrets). The
    # connection builds it, keeps the discovered context, and hands it to
    # the transport (`set_auth/2`), so every request process can find its
    # bearer token in the store.
    #
    #   * `bearer/1` - in an HTTP exchange, before each request: the stored
    #     access token, refreshed first when it expires within
    #     `refresh_skew` (single-flight, in that process - never in the
    #     connection).
    #   * `check/2` - in the connection's authorization task after a 401:
    #     discovery if needed, then a token that differs from the one the
    #     server refused (another process refreshed, or the host completed
    #     an authorization), a refresh, a new client-credentials token, or
    #     `:authorization_required`.
    #   * `token/2`, `refresh/2` - `ConduitMcp.Client.OAuth.token_for/2` and
    #     `refresh/2`.
    #
    # Refreshes are single-flight per `{principal, issuer, resource}`
    # through `ConduitMcp.Client.OAuth.TokenStore.transaction/3`: inside the
    # lock the store is read again, and a token another process already
    # renewed is used as is. A rotated refresh token is persisted before the
    # lock is released; `invalid_grant` deletes the tokens (the user must
    # authorize again).

    alias ConduitMcp.Client.OAuth.{
      Challenge,
      ClientCredentials,
      Config,
      Error,
      Registration,
      TokenEndpoint,
      Tokens,
      TokenStore
    }

    alias ConduitMcp.Client.OAuth.Discovery.Fetch
    alias ConduitMcp.Client.OAuth.Telemetry
    alias ConduitMcp.Client.Secret

    require Logger

    defstruct [:config, context: nil]

    @type t :: %__MODULE__{config: Config.t(), context: Fetch.context() | nil}

    @spec new(Config.t()) :: t()
    def new(%Config{} = config), do: %__MODULE__{config: config}

    @doc "Discovers the authorization server unless already known."
    @spec ensure_context(t(), Challenge.t() | nil) :: {:ok, t()} | {:error, Error.t()}
    def ensure_context(%__MODULE__{context: %{}} = session, _challenge), do: {:ok, session}

    def ensure_context(%__MODULE__{config: config} = session, challenge) do
      with {:ok, context} <- Fetch.discover(config, challenge) do
        {:ok, %{session | context: context}}
      end
    end

    @doc "The token-store key for `principal` (default: the configured one)."
    @spec key(t(), term()) :: TokenStore.key()
    def key(%__MODULE__{config: config, context: context}, principal \\ :default) do
      principal = if principal == :default, do: config.principal, else: principal
      {principal, context.issuer, context.resource}
    end

    @doc "A short, non-reversible fingerprint of an access token."
    @spec fingerprint(Secret.t()) :: binary()
    def fingerprint(secret),
      do: :sha256 |> :crypto.hash(Secret.expose(secret)) |> binary_part(0, 16)

    # --- per request ---------------------------------------------------------

    @doc """
    The access token to send, or `nil` (no context yet, no token, or a
    renewal that failed: the request goes without one and a 401 starts the
    authorization path).
    """
    @spec bearer(t()) :: {:ok, Secret.t() | nil}
    def bearer(%__MODULE__{context: nil}), do: {:ok, nil}

    def bearer(%__MODULE__{config: config} = session) do
      key = key(session)
      store = Config.store(config)
      now = Config.now(config)
      fresh? = &(not Tokens.expired?(&1, Config.now(config), config.refresh_skew))

      case TokenStore.fetch_tokens(store, key) do
        {:ok, tokens} ->
          cond do
            not Tokens.expired?(tokens, now, config.refresh_skew) ->
              {:ok, tokens.access_token}

            renewable?(config, tokens) ->
              access(renew_locked(session, key, fresh?))

            # Expired with no way to renew it: let the server say so.
            true ->
              {:ok, nil}
          end

        :error ->
          if config.grant == :client_credentials,
            do: access(renew_locked(session, key, fresh?)),
            else: {:ok, nil}
      end
    end

    defp renewable?(config, tokens),
      do: tokens.refresh_token != nil or config.grant == :client_credentials

    defp access({:ok, %Tokens{access_token: access}}), do: {:ok, access}
    defp access({:error, _error}), do: {:ok, nil}

    # --- after a 401 ---------------------------------------------------------

    @doc """
    Runs after the server refused a request with 401. `sent` is the
    fingerprint of the token that request carried (`nil` when none).

    Returns `{:ok, session, scopes}` when a usable token is now stored
    (`scopes` are its scopes), `{:authorization_required, session}` when the
    user must authorize, or `{:error, error, session}`.
    """
    @spec check(t(), %{challenge: Challenge.t() | nil, sent: binary() | nil}) ::
            {:ok, t(), [String.t()]}
            | {:authorization_required, t()}
            | {:error, Error.t(), t()}
    def check(%__MODULE__{} = session, %{challenge: challenge, sent: sent}) do
      case ensure_context(session, challenge) do
        {:ok, session} ->
          config = session.config

          usable? = fn tokens ->
            (sent == nil or fingerprint(tokens.access_token) != sent) and
              not Tokens.expired?(tokens, Config.now(config), config.refresh_skew)
          end

          case renew_locked(session, key(session), usable?) do
            {:ok, tokens} ->
              {:ok, session, tokens.scopes}

            {:error, %Error{reason: :authorization_required}} ->
              {:authorization_required, session}

            {:error, error} ->
              {:error, error, session}
          end

        {:error, error} ->
          {:error, error, session}
      end
    end

    @doc """
    A client-credentials step-up: a new token for `scopes` (the union of
    the scopes held and the ones the server challenged).
    """
    @spec step_up(t(), [String.t()]) :: {:ok, t(), [String.t()]} | {:error, Error.t(), t()}
    def step_up(%__MODULE__{} = session, scopes) do
      with {:ok, session} <- ensure_context(session, nil),
           key = key(session),
           {:ok, tokens} <-
             TokenStore.transaction(Config.store(session.config), key, fn ->
               ClientCredentials.request(session, key, scopes)
             end) do
        {:ok, session, tokens.scopes}
      else
        {:error, error} -> {:error, error, session}
      end
    end

    # --- facade --------------------------------------------------------------

    @doc "`ConduitMcp.Client.OAuth.token_for/2`."
    @spec token(t(), term()) :: {:ok, Tokens.t()} | {:error, Error.t()}
    def token(%__MODULE__{config: config} = session, principal) do
      with {:ok, session} <- ensure_context(session, nil) do
        key = key(session, principal)
        fresh? = &(not Tokens.expired?(&1, Config.now(config), config.refresh_skew))

        case TokenStore.fetch_tokens(Config.store(config), key) do
          {:ok, tokens} ->
            if fresh?.(tokens), do: {:ok, tokens}, else: renew_locked(session, key, fresh?)

          :error ->
            renew_locked(session, key, fresh?)
        end
      end
    end

    @doc "`ConduitMcp.Client.OAuth.refresh/2`: renew now, single-flight."
    @spec refresh(t(), term()) :: {:ok, Tokens.t()} | {:error, Error.t()}
    def refresh(%__MODULE__{config: config} = session, principal) do
      with {:ok, session} <- ensure_context(session, nil) do
        key = key(session, principal)

        seen =
          case TokenStore.fetch_tokens(Config.store(config), key) do
            {:ok, tokens} -> Secret.expose(tokens.access_token)
            :error -> nil
          end

        # A token that changed since `seen` was renewed by someone else
        # while this call waited for the lock.
        changed? = &(seen != nil and Secret.expose(&1.access_token) != seen)
        renew_locked(session, key, changed?)
      end
    end

    # --- renewal -------------------------------------------------------------

    # Under the store's lock: re-read, and keep a token `usable?` accepts;
    # otherwise refresh it, request a new client-credentials token, or say
    # the user must authorize.
    defp renew_locked(%__MODULE__{config: config} = session, key, usable?) do
      store = Config.store(config)

      TokenStore.transaction(store, key, fn ->
        case TokenStore.fetch_tokens(store, key) do
          {:ok, tokens} ->
            if usable?.(tokens), do: {:ok, tokens}, else: renew(session, key, tokens)

          :error ->
            renew(session, key, nil)
        end
      end)
    end

    defp renew(session, key, %Tokens{refresh_token: refresh_token} = tokens)
         when refresh_token != nil do
      case refresh_grant(session, key, tokens) do
        {:error, %Error{reason: :invalid_grant}} ->
          :ok = TokenStore.delete(Config.store(session.config), key, :tokens)

          if session.config.grant == :client_credentials,
            do: ClientCredentials.request(session, key, tokens.scopes),
            else: Error.error(:authorization_required)

        result ->
          result
      end
    end

    defp renew(%__MODULE__{config: %{grant: :client_credentials}} = session, key, tokens),
      do: ClientCredentials.request(session, key, if(tokens, do: tokens.scopes))

    defp renew(_session, _key, _tokens), do: Error.error(:authorization_required)

    defp refresh_grant(%__MODULE__{config: config, context: context} = session, key, tokens) do
      Telemetry.span(:refresh, Telemetry.base(config), fn ->
        result =
          with {:ok, client} <- client(session) do
            params = [
              grant_type: "refresh_token",
              refresh_token: Secret.expose(tokens.refresh_token),
              resource: context.resource
            ]

            case TokenEndpoint.request(
                   config,
                   context.metadata["token_endpoint"],
                   client,
                   params,
                   tokens.scopes
                 ) do
              {:ok, new, _scopes} ->
                # The server may rotate the refresh token, or keep it.
                new = %{new | refresh_token: new.refresh_token || tokens.refresh_token}
                persist(config, key, new)

              error ->
                error
            end
          end

        {result, %{}}
      end)
    end

    @doc false
    # The client identity used at the token endpoint for a refresh.
    @spec client(t()) :: {:ok, map()} | {:error, Error.t()}
    def client(%__MODULE__{config: %{grant: :client_credentials} = config}),
      do: {:ok, config.credentials}

    def client(%__MODULE__{config: config, context: context}),
      do: Registration.resolve(config, context.issuer, context.metadata, register: false)

    @doc false
    # Stores `tokens` under `key` and returns them.
    @spec persist(Config.t(), TokenStore.key(), Tokens.t()) ::
            {:ok, Tokens.t()} | {:error, Error.t()}
    def persist(config, key, tokens) do
      case TokenStore.put_tokens(Config.store(config), key, tokens) do
        :ok ->
          {:ok, tokens}

        {:error, _reason} ->
          # The tokens still serve this request; the next one re-authorizes.
          Logger.warning("MCP client OAuth token store refused a write")
          {:ok, tokens}
      end
    end
  end
end

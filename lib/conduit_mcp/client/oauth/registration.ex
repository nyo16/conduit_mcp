if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.Registration do
    @moduledoc """
    Chooses the client identity presented to an authorization server, in
    the MCP authorization spec's order (compiled only with `:finch`):

      1. **Pre-registered** - `pre_registered[issuer]` from the OAuth
         options. When pre-registered clients are configured but none is
         for this issuer, the server has moved to another authorization
         server and the flow stops with `:authorization_server_changed`
         (OA-6): credentials are bound to their issuer, and falling back to
         another method would silently re-identify the client.
      2. **Client ID Metadata Document** - when the authorization server
         advertises `client_id_metadata_document_supported: true` and
         `:client_metadata_url` is set, that URL is the client id (see
         `ConduitMcp.Client.OAuth.CIMD`).
      3. **Dynamic client registration** (RFC 7591; deprecated in MCP
         2026-07-28, kept for older authorization servers) - when the
         metadata has a `registration_endpoint`. The request declares
         `application_type` (`native` for a loopback or custom-scheme
         redirect URI, else `web`, unless `client_metadata` says
         otherwise), `grant_types: ["authorization_code", "refresh_token"]`,
         `response_types: ["code"]` and `token_endpoint_auth_method:
         "none"`. The registered client is kept in the token store under
         the issuer (`c:ConduitMcp.Client.OAuth.TokenStore.put_client/3`)
         and reused while its `redirect_uris` include the redirect URI, so
         a client registered with one authorization server is never shown
         to another.
      4. Otherwise `:no_registration_method`.
    """

    alias ConduitMcp.Client.OAuth.{Config, Error, HTTP, TokenStore, URL}
    alias ConduitMcp.Client.OAuth.Telemetry
    alias ConduitMcp.Client.Secret

    @typedoc "A resolved client identity and how it was obtained."
    @type t :: %{
            required(:client_id) => String.t(),
            required(:auth_method) => atom(),
            required(:method) => :pre_registered | :cimd | :dcr,
            optional(atom()) => term()
          }

    @auth_methods %{
      "none" => :none,
      "client_secret_basic" => :client_secret_basic,
      "client_secret_post" => :client_secret_post
    }

    @doc """
    Resolves the client identity for authorization server `issuer` with
    validated `metadata`.

    ## Options

      * `:redirect_uri` - the redirect URI of the flow (needed to register).
      * `:register` - whether dynamic registration may send a request
        (default `true`; `false` only reuses a stored registration, as a
        token refresh does).
    """
    @spec resolve(Config.t(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
    def resolve(%Config{} = config, issuer, metadata, opts \\ []) do
      Telemetry.span(:registration, Telemetry.base(config), fn ->
        result = do_resolve(config, issuer, metadata, opts)

        method =
          case result do
            {:ok, %{method: method}} -> method
            _error -> nil
          end

        {result, %{method: method}}
      end)
    end

    defp do_resolve(config, issuer, metadata, opts) do
      cond do
        config.pre_registered != %{} ->
          case Map.fetch(config.pre_registered, issuer) do
            {:ok, client} -> {:ok, Map.put(client, :method, :pre_registered)}
            :error -> Error.error(:authorization_server_changed)
          end

        config.client_metadata_url != nil and
            metadata["client_id_metadata_document_supported"] == true ->
          {:ok, public_client(config.client_metadata_url, :cimd)}

        is_binary(metadata["registration_endpoint"]) ->
          dynamic(config, issuer, metadata["registration_endpoint"], opts)

        true ->
          Error.error(:no_registration_method)
      end
    end

    defp public_client(client_id, method) do
      %{
        client_id: client_id,
        auth_method: :none,
        secret: nil,
        private_key: nil,
        alg: "RS256",
        kid: nil,
        method: method
      }
    end

    defp dynamic(config, issuer, endpoint, opts) do
      store = Config.store(config)
      redirect_uri = Keyword.get(opts, :redirect_uri)

      case TokenStore.fetch_client(store, issuer) do
        {:ok, %{"client_id" => id} = stored} when is_binary(id) ->
          if redirect_uri == nil or redirect_uri in List.wrap(stored["redirect_uris"]),
            do: {:ok, from_stored(stored)},
            else: register(config, store, issuer, endpoint, redirect_uri, opts)

        :error ->
          register(config, store, issuer, endpoint, redirect_uri, opts)
      end
    end

    defp register(config, store, issuer, endpoint, redirect_uri, opts) do
      cond do
        not Keyword.get(opts, :register, true) -> Error.error(:no_registration_method)
        redirect_uri == nil -> Error.error(:no_registration_method)
        true -> post_registration(config, store, issuer, endpoint, redirect_uri)
      end
    end

    defp post_registration(config, store, issuer, endpoint, redirect_uri) do
      body = registration_body(config, redirect_uri)

      with {:ok, %{status: status} = response} when status in [200, 201] <-
             HTTP.post_json(endpoint, body, Config.http(config)),
           {:ok, %{"client_id" => id} = answer} when is_binary(id) and id != "" <-
             HTTP.json(response) do
        secret = answer["client_secret"]

        stored = %{
          "client_id" => id,
          "client_secret" => if(is_binary(secret) and secret != "", do: Secret.new(secret)),
          "token_endpoint_auth_method" =>
            answer["token_endpoint_auth_method"] || body["token_endpoint_auth_method"],
          "redirect_uris" => [redirect_uri]
        }

        _ = TokenStore.put_client(store, issuer, stored)
        {:ok, from_stored(stored)}
      else
        {:error, {:url_blocked, reason}} -> Error.error(:url_blocked, reason)
        {:ok, %{status: status}} -> Error.error(:registration_failed, %{status: status})
        _other -> Error.error(:registration_failed)
      end
    end

    @doc false
    @spec registration_body(Config.t(), String.t()) :: map()
    def registration_body(config, redirect_uri) do
      metadata = config.client_metadata
      type = metadata[:application_type] || application_type(redirect_uri)

      %{
        "redirect_uris" => [redirect_uri],
        "client_name" => metadata[:client_name] || "ConduitMCP client",
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none",
        "application_type" => Atom.to_string(type)
      }
      |> put_present("client_uri", metadata[:client_uri])
      |> put_present("logo_uri", metadata[:logo_uri])
    end

    defp put_present(map, _key, nil), do: map
    defp put_present(map, key, value), do: Map.put(map, key, value)

    # RFC 8252 / OIDC Registration: loopback and private-use schemes are
    # native apps; an https redirect on a real host is a web client.
    defp application_type(redirect_uri) do
      case URI.parse(redirect_uri) do
        %URI{scheme: "https", host: host} -> if URL.loopback?(host), do: :native, else: :web
        _other -> :native
      end
    end

    defp from_stored(stored) do
      secret = stored["client_secret"]

      method =
        Map.get(@auth_methods, stored["token_endpoint_auth_method"]) ||
          if(secret, do: :client_secret_basic, else: :none)

      %{public_client(stored["client_id"], :dcr) | auth_method: method, secret: secret}
    end
  end
end

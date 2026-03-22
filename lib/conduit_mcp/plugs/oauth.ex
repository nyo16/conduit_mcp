if Code.ensure_loaded?(Joken) do
  defmodule ConduitMcp.Plugs.OAuth do
    @moduledoc """
    OAuth 2.1 authentication plug for MCP servers.

    Validates JWT Bearer tokens against a configured authorization server.
    Implements the MCP specification's OAuth 2.1 Resource Server requirements.

    ## Features

    - JWT signature verification via pluggable key providers
    - Issuer and audience validation
    - Token expiration checking
    - Scope extraction and enforcement
    - WWW-Authenticate headers per RFC 9728
    - Protected Resource Metadata endpoint support

    ## Configuration

        # Basic OAuth with JWKS auto-discovery
        {ConduitMcp.Transport.StreamableHTTP,
          server_module: MyServer,
          auth: [
            strategy: :oauth,
            issuer: "https://auth.example.com",
            audience: "https://mcp.example.com",
            scopes_supported: ["read", "write", "admin"],
            key_provider: {ConduitMcp.OAuth.KeyProvider.JWKS,
              jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
          ]}

        # Static keys for testing
        {ConduitMcp.Transport.StreamableHTTP,
          server_module: MyServer,
          auth: [
            strategy: :oauth,
            issuer: "test-issuer",
            audience: "test-audience",
            key_provider: {ConduitMcp.OAuth.KeyProvider.Static,
              keys: [test_key_map]}
          ]}

    ## Token Claims

    After successful validation, the token claims are stored in `conn.assigns[:oauth_claims]`
    and the scopes in `conn.assigns[:oauth_scopes]`.
    """

    import Plug.Conn
    require Logger

    @behaviour Plug

    @impl true
    def init(opts) do
      issuer = Keyword.fetch!(opts, :issuer)
      audience = Keyword.fetch!(opts, :audience)

      {provider_mod, provider_config} =
        case Keyword.fetch!(opts, :key_provider) do
          {mod, config} when is_atom(mod) and is_list(config) -> {mod, config}
          {mod, config} when is_atom(mod) and is_atom(config) -> {mod, []}
          mod when is_atom(mod) -> {mod, []}
        end

      %{
        issuer: issuer,
        audience: audience,
        scopes_supported: Keyword.get(opts, :scopes_supported, []),
        resource_uri: Keyword.get(opts, :resource_uri) || audience,
        key_provider: provider_mod,
        key_provider_config: provider_config,
        scope_claim: Keyword.get(opts, :scope_claim, "scope"),
        assign_as: Keyword.get(opts, :assign_as, :oauth_claims)
      }
    end

    @impl true
    def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
      conn
    end

    def call(conn, opts) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          verify_token(conn, token, opts)

        ["bearer " <> token] ->
          verify_token(conn, token, opts)

        _ ->
          unauthorized(conn, opts, "Missing or invalid Authorization header")
      end
    end

    defp verify_token(conn, token, opts) do
      start_time = System.monotonic_time()

      result =
        with {:ok, header} <- peek_header(token),
             {:ok, key} <- fetch_signing_key(header, opts),
             {:ok, claims} <- verify_and_validate(token, key, opts) do
          scopes = extract_scopes(claims, opts.scope_claim)

          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:conduit_mcp, :auth, :verify],
            %{duration: duration},
            %{strategy: :oauth, status: :ok}
          )

          conn
          |> assign(opts.assign_as, claims)
          |> assign(:oauth_scopes, scopes)
          |> assign(:current_user, %{claims: claims, scopes: scopes})
        end

      case result do
        %Plug.Conn{} = conn ->
          conn

        {:error, :expired} ->
          duration = System.monotonic_time() - start_time
          emit_auth_error(duration, :expired)
          unauthorized(conn, opts, "Token expired")

        {:error, :invalid_audience} ->
          duration = System.monotonic_time() - start_time
          emit_auth_error(duration, :invalid_audience)
          unauthorized(conn, opts, "Invalid token audience")

        {:error, :invalid_issuer} ->
          duration = System.monotonic_time() - start_time
          emit_auth_error(duration, :invalid_issuer)
          unauthorized(conn, opts, "Invalid token issuer")

        {:error, :not_found} ->
          duration = System.monotonic_time() - start_time
          emit_auth_error(duration, :key_not_found)
          unauthorized(conn, opts, "Signing key not found")

        {:error, reason} ->
          duration = System.monotonic_time() - start_time
          emit_auth_error(duration, reason)
          Logger.warning("OAuth token verification failed: #{inspect(reason)}")
          unauthorized(conn, opts, "Token verification failed")
      end
    end

    defp peek_header(token) do
      case Joken.peek_header(token) do
        {:ok, header} -> {:ok, header}
        {:error, reason} -> {:error, {:invalid_token, reason}}
      end
    rescue
      _ -> {:error, :invalid_token_format}
    end

    defp fetch_signing_key(header, opts) do
      kid = Map.get(header, "kid")

      if kid do
        opts.key_provider.fetch_key(kid, opts.key_provider_config)
      else
        case opts.key_provider.fetch_keys(opts.key_provider_config) do
          {:ok, [key | _]} -> {:ok, key}
          {:ok, []} -> {:error, :not_found}
          error -> error
        end
      end
    end

    defp verify_and_validate(token, key_map, opts) do
      signer = Joken.Signer.create(alg_from_key(key_map), key_map)

      # Only use Joken for signature verification and issuer check.
      # We handle audience validation ourselves to support array audiences.
      token_config =
        Joken.Config.default_claims(
          iss: opts.issuer,
          skip: [:aud],
          default_exp: 3600
        )

      case Joken.verify_and_validate(token_config, token, signer) do
        {:ok, claims} ->
          validate_claims(claims, opts)

        {:error, reason} ->
          normalize_joken_error(reason)
      end
    end

    defp normalize_joken_error(reason) do
      reason_str = inspect(reason)

      cond do
        String.contains?(reason_str, "expired") -> {:error, :expired}
        String.contains?(reason_str, "Invalid") -> {:error, :invalid_signature}
        String.contains?(reason_str, "signature") -> {:error, :invalid_signature}
        true -> {:error, reason}
      end
    end

    defp validate_claims(claims, opts) do
      with :ok <- validate_issuer(claims, opts.issuer),
           :ok <- validate_audience(claims, opts.audience) do
        {:ok, claims}
      end
    end

    defp validate_issuer(claims, expected_issuer) do
      case Map.get(claims, "iss") do
        ^expected_issuer -> :ok
        _ -> {:error, :invalid_issuer}
      end
    end

    defp validate_audience(claims, expected_audience) do
      case Map.get(claims, "aud") do
        ^expected_audience ->
          :ok

        aud when is_list(aud) ->
          if expected_audience in aud, do: :ok, else: {:error, :invalid_audience}

        _ ->
          {:error, :invalid_audience}
      end
    end

    defp extract_scopes(claims, scope_claim) do
      case Map.get(claims, scope_claim) do
        scope when is_binary(scope) -> String.split(scope, " ", trim: true)
        scopes when is_list(scopes) -> scopes
        _ -> []
      end
    end

    defp alg_from_key(%{"kty" => "RSA"}), do: "RS256"
    defp alg_from_key(%{"kty" => "EC", "crv" => "P-256"}), do: "ES256"
    defp alg_from_key(%{"kty" => "EC", "crv" => "P-384"}), do: "ES384"
    defp alg_from_key(%{"kty" => "EC", "crv" => "P-521"}), do: "ES512"
    defp alg_from_key(%{"kty" => "oct"}), do: "HS256"
    defp alg_from_key(%{"alg" => alg}), do: alg
    defp alg_from_key(_), do: "RS256"

    defp emit_auth_error(duration, reason) do
      :telemetry.execute(
        [:conduit_mcp, :auth, :verify],
        %{duration: duration},
        %{strategy: :oauth, status: :error, reason: reason}
      )
    end

    @doc """
    Checks if the authenticated request has the required scope.
    Returns `true` if the scope is present, `false` otherwise.
    """
    def has_scope?(conn, required_scope) do
      scopes = conn.assigns[:oauth_scopes] || []
      required_scope in scopes
    end

    @doc """
    Checks if the authenticated request has all required scopes.
    """
    def has_scopes?(conn, required_scopes) do
      scopes = conn.assigns[:oauth_scopes] || []
      Enum.all?(required_scopes, &(&1 in scopes))
    end

    defp unauthorized(conn, opts, message) do
      resource_metadata_uri =
        "#{opts.resource_uri}/.well-known/oauth-protected-resource"

      www_authenticate =
        "Bearer resource_metadata=\"#{resource_metadata_uri}\""

      www_authenticate =
        case opts.scopes_supported do
          [] -> www_authenticate
          scopes -> "#{www_authenticate}, scope=\"#{Enum.join(scopes, " ")}\""
        end

      conn
      |> put_resp_header("www-authenticate", www_authenticate)
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        JSON.encode!(%{"error" => "Unauthorized", "message" => message})
      )
      |> halt()
    end

    @doc """
    Sends a 403 Forbidden response with insufficient_scope error.
    Used by the handler when a tool/resource requires a scope the token doesn't have.
    """
    def forbidden(conn, opts, required_scopes) do
      resource_metadata_uri =
        "#{opts.resource_uri}/.well-known/oauth-protected-resource"

      www_authenticate =
        "Bearer error=\"insufficient_scope\", " <>
          "scope=\"#{Enum.join(required_scopes, " ")}\", " <>
          "resource_metadata=\"#{resource_metadata_uri}\""

      conn
      |> put_resp_header("www-authenticate", www_authenticate)
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        JSON.encode!(%{
          "error" => "Forbidden",
          "message" => "Insufficient scope. Required: #{Enum.join(required_scopes, ", ")}"
        })
      )
      |> halt()
    end
  end
end

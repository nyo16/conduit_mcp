if Code.ensure_loaded?(Finch) do
  defmodule ConduitMcp.Client.OAuth.TokenEndpoint do
    @moduledoc false

    # Token requests (RFC 6749 §3.2): the authorization-code exchange, the
    # refresh grant and the client-credentials grant. Each one carries
    # `resource` (RFC 8707) and the client's own authentication, never the
    # MCP server's bearer, and goes through `ConduitMcp.Client.OAuth.HTTP`
    # (URL policy, pinning, no redirects).
    #
    # Client authentication (RFC 6749 §2.3, RFC 7523):
    #
    #   * `:none` - a public client: `client_id` in the body.
    #   * `:client_secret_basic` - `Authorization: Basic` with the
    #     form-urlencoded id and secret (RFC 6749 §2.3.1).
    #   * `:client_secret_post` - `client_id` and `client_secret` in the body.
    #   * `:private_key_jwt` - a signed client assertion
    #     (`ConduitMcp.Client.OAuth.ClientAssertion`, needs `:jose`).

    alias ConduitMcp.Client.OAuth.{Config, Error, HTTP, Scopes, Tokens}
    alias ConduitMcp.Client.Secret

    @doc """
    Posts `params` (the grant's own parameters) to `endpoint` with `client`'s
    authentication and builds the tokens. `requested` scopes stand in when
    the response has no `scope` (RFC 6749 §5.1: unchanged).
    """
    @spec request(Config.t(), String.t(), Config.client_credentials(), keyword(), [String.t()]) ::
            {:ok, Tokens.t(), [String.t()]} | {:error, Error.t()}
    def request(%Config{} = config, endpoint, client, params, requested) do
      with {:ok, form, headers} <- authenticate(config, endpoint, client, params),
           {:ok, response} <- post(config, endpoint, form, headers) do
        parse(config, response, requested)
      end
    end

    defp post(config, endpoint, form, headers) do
      case HTTP.post_form(endpoint, form, headers, Config.http(config)) do
        {:ok, response} -> {:ok, response}
        {:error, {:url_blocked, reason}} -> Error.error(:url_blocked, reason)
        {:error, reason} -> Error.error(:token_request_failed, %{reason: reason_tag(reason)})
      end
    end

    defp reason_tag(reason) when is_tuple(reason), do: elem(reason, 0)
    defp reason_tag(reason), do: reason

    defp authenticate(config, endpoint, client, params) do
      form = Enum.map(params, fn {key, value} -> {Atom.to_string(key), value} end)

      case client.auth_method do
        :none ->
          {:ok, [{"client_id", client.client_id} | form], []}

        :client_secret_post ->
          with {:ok, secret} <- Config.secret(client) do
            {:ok, [{"client_id", client.client_id}, {"client_secret", secret} | form], []}
          end

        :client_secret_basic ->
          with {:ok, secret} <- Config.secret(client) do
            credentials =
              Base.encode64(form_encode(client.client_id) <> ":" <> form_encode(secret || ""))

            {:ok, form, [{"authorization", Secret.new("Basic " <> credentials)}]}
          end

        :private_key_jwt ->
          module = ConduitMcp.OptionalDeps.client_assertion!()
          assertion = module.sign(client, endpoint, Config.now(config))

          {:ok,
           [
             {"client_id", client.client_id},
             {"client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"},
             {"client_assertion", assertion}
             | form
           ], []}
      end
    end

    defp form_encode(value), do: URI.encode_www_form(value)

    defp parse(config, %{status: 200} = response, requested) do
      with {:ok, body} <- json(response),
           {:ok, tokens} <- tokens(config, body, requested) do
        {:ok, tokens, tokens.scopes}
      end
    end

    defp parse(_config, %{status: status} = response, _requested) when status in 400..499 do
      case json(response) do
        {:ok, %{"error" => "invalid_grant"}} ->
          Error.error(:invalid_grant)

        {:ok, %{"error" => code}} when is_binary(code) ->
          Error.error(:token_request_failed, %{status: status, error: code})

        _other ->
          Error.error(:token_request_failed, %{status: status})
      end
    end

    defp parse(_config, %{status: status}, _requested),
      do: Error.error(:token_request_failed, %{status: status})

    defp json(response) do
      case HTTP.json(response) do
        {:ok, body} -> {:ok, body}
        :error -> Error.error(:token_request_failed, %{reason: :invalid_json})
      end
    end

    # RFC 6749 §5.1; `token_type` must be Bearer (case-insensitive).
    defp tokens(config, body, requested) do
      with access when is_binary(access) and access != "" <- body["access_token"],
           type when is_binary(type) <- body["token_type"],
           "bearer" <- String.downcase(type),
           refresh when is_nil(refresh) or (is_binary(refresh) and refresh != "") <-
             body["refresh_token"],
           expires_in when is_nil(expires_in) or (is_integer(expires_in) and expires_in >= 0) <-
             body["expires_in"],
           scope when is_nil(scope) or is_binary(scope) <- body["scope"] do
        {:ok,
         Tokens.new(
           access_token: access,
           refresh_token: refresh,
           expires_at: expires_in && Config.now(config) + expires_in,
           scopes: if(scope, do: Scopes.parse(scope), else: requested)
         )}
      else
        _invalid -> Error.error(:token_request_failed, %{reason: :invalid_token_response})
      end
    end
  end
end

if Code.ensure_loaded?(JOSE) do
  defmodule ConduitMcp.Client.OAuth.ClientAssertion do
    @moduledoc false

    # `private_key_jwt` client authentication (RFC 7523 §2.2, OIDC Core §9):
    # a short-lived JWT signed with the client's private key, with `iss` and
    # `sub` = the client id, `aud` = the token endpoint, a random `jti`, and
    # `iat`/`exp` 60 s apart. Compiled only with the optional `:jose`
    # dependency (`ConduitMcp.OptionalDeps.client_assertion!/0`).

    alias ConduitMcp.Client.Secret

    @lifetime 60

    @doc "The compact client assertion for `client` at `audience`, issued at `now`."
    @spec sign(map(), String.t(), integer()) :: String.t()
    def sign(%{client_id: client_id, private_key: key, alg: alg, kid: kid}, audience, now) do
      jwk =
        case Secret.expose(key) do
          %{} = map -> JOSE.JWK.from_map(map)
          pem when is_binary(pem) -> JOSE.JWK.from_pem(pem)
        end

      header = if kid, do: %{"alg" => alg, "kid" => kid}, else: %{"alg" => alg}

      claims = %{
        "iss" => client_id,
        "sub" => client_id,
        "aud" => audience,
        "jti" => 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
        "iat" => now,
        "exp" => now + @lifetime
      }

      {_meta, compact} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
      compact
    end
  end
end

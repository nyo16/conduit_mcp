# Redis-backed JWKS key provider for multi-node OAuth deployments.
#
# Caches JWKS keys in Redis so all nodes share the same cache.
# Falls back to HTTP fetch on cache miss.
#
# Requires: {:redix, "~> 1.5"} and {:req, "~> 0.5"} in your deps
#
# Configuration:
#
#     auth: [
#       strategy: :oauth,
#       issuer: "https://auth.example.com",
#       audience: "https://mcp.example.com",
#       key_provider: {MyApp.RedisKeyProvider,
#         jwks_uri: "https://auth.example.com/.well-known/jwks.json",
#         cache_ttl: 3600}   # 1 hour in seconds
#     ]
#
defmodule MyApp.RedisKeyProvider do
  @behaviour ConduitMcp.OAuth.KeyProvider

  @prefix "mcp:jwks:"
  @default_ttl 3600

  @impl true
  def fetch_keys(config) do
    jwks_uri = Keyword.fetch!(config, :jwks_uri)
    ttl = Keyword.get(config, :cache_ttl, @default_ttl)

    case Redix.command(:redix, ["GET", key(jwks_uri)]) do
      {:ok, nil} ->
        fetch_and_cache(jwks_uri, ttl)

      {:ok, cached} ->
        {:ok, Jason.decode!(cached)}

      {:error, _reason} ->
        # Redis down — fall back to direct fetch
        fetch_from_upstream(jwks_uri)
    end
  end

  @impl true
  def fetch_key(kid, config) do
    case fetch_keys(config) do
      {:ok, keys} ->
        case Enum.find(keys, fn k -> Map.get(k, "kid") == kid end) do
          nil ->
            # Force refresh — key may have rotated
            jwks_uri = Keyword.fetch!(config, :jwks_uri)
            ttl = Keyword.get(config, :cache_ttl, @default_ttl)

            case fetch_and_cache(jwks_uri, ttl) do
              {:ok, fresh_keys} ->
                case Enum.find(fresh_keys, fn k -> Map.get(k, "kid") == kid end) do
                  nil -> {:error, :not_found}
                  found -> {:ok, found}
                end

              error ->
                error
            end

          found ->
            {:ok, found}
        end

      error ->
        error
    end
  end

  defp fetch_and_cache(jwks_uri, ttl) do
    case fetch_from_upstream(jwks_uri) do
      {:ok, keys} ->
        # Cache in Redis with TTL
        Redix.command(:redix, [
          "SET",
          key(jwks_uri),
          Jason.encode!(keys),
          "EX",
          to_string(ttl)
        ])

        {:ok, keys}

      error ->
        error
    end
  end

  defp fetch_from_upstream(jwks_uri) do
    case Req.get(jwks_uri) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} -> {:ok, keys}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key(jwks_uri), do: @prefix <> jwks_uri
end

if Code.ensure_loaded?(Req) do
  defmodule ConduitMcp.OAuth.KeyProvider.JWKS do
    @moduledoc """
    JWKS key provider that fetches keys from an HTTP endpoint with ETS caching.

    Fetches JSON Web Key Sets from the authorization server's JWKS URI,
    caches them in ETS, and auto-refreshes on cache miss or expiration.

    ## Configuration

        auth: [
          strategy: :oauth,
          key_provider: {ConduitMcp.OAuth.KeyProvider.JWKS,
            jwks_uri: "https://auth.example.com/.well-known/jwks.json",
            cache_ttl: :timer.hours(1)}    # default: 1 hour
        ]

    ## Requirements

    Requires the `req` package:

        {:req, "~> 0.5"}
    """

    @behaviour ConduitMcp.OAuth.KeyProvider

    require Logger

    @table :conduit_mcp_jwks_cache
    @default_ttl :timer.hours(1)

    @impl true
    def fetch_keys(config) do
      jwks_uri = Keyword.fetch!(config, :jwks_uri)
      ttl = Keyword.get(config, :cache_ttl, @default_ttl)

      case get_cached(jwks_uri, ttl) do
        {:ok, keys} ->
          {:ok, keys}

        :miss ->
          fetch_and_cache(jwks_uri)
      end
    end

    @impl true
    def fetch_key(kid, config) do
      with {:ok, keys} <- fetch_keys(config),
           nil <- find_key(keys, kid),
           {:ok, fresh_keys} <- refresh_keys(config),
           nil <- find_key(fresh_keys, kid) do
        {:error, :not_found}
      else
        {:ok, key} -> {:ok, key}
        {:error, _} = error -> error
      end
    end

    defp find_key(keys, kid) do
      case Enum.find(keys, fn key -> Map.get(key, "kid") == kid end) do
        nil -> nil
        key -> {:ok, key}
      end
    end

    defp refresh_keys(config) do
      jwks_uri = Keyword.fetch!(config, :jwks_uri)
      fetch_and_cache(jwks_uri)
    end

    defp ensure_table do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      end

      :ok
    end

    defp get_cached(jwks_uri, ttl) do
      ensure_table()

      case :ets.lookup(@table, jwks_uri) do
        [{^jwks_uri, keys, cached_at}] ->
          if System.system_time(:millisecond) - cached_at < ttl do
            {:ok, keys}
          else
            :miss
          end

        [] ->
          :miss
      end
    end

    defp fetch_and_cache(jwks_uri) do
      ensure_table()
      Logger.debug("Fetching JWKS from #{jwks_uri}")

      case Req.get(jwks_uri) do
        {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
          :ets.insert(@table, {jwks_uri, keys, System.system_time(:millisecond)})
          {:ok, keys}

        {:ok, %{status: status}} ->
          Logger.error("JWKS fetch failed with status #{status} from #{jwks_uri}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.error("JWKS fetch error from #{jwks_uri}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end

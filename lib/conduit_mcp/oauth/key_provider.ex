defmodule ConduitMcp.OAuth.KeyProvider do
  @moduledoc """
  Behaviour for pluggable JWKS key providers.

  Key providers fetch and optionally cache the public keys used to verify
  JWT access tokens from OAuth authorization servers.

  ## Built-in Providers

  - `ConduitMcp.OAuth.KeyProvider.JWKS` — Fetches keys from a JWKS endpoint over HTTP with ETS caching
  - `ConduitMcp.OAuth.KeyProvider.Static` — Uses statically configured keys (testing/development)

  ## Custom Providers

  ### Redis Example

      defmodule MyApp.RedisKeyProvider do
        @behaviour ConduitMcp.OAuth.KeyProvider

        @impl true
        def fetch_keys(config) do
          case Redix.command(:redix, ["GET", "oauth:jwks"]) do
            {:ok, nil} ->
              # Cache miss — fetch from upstream and cache
              {:ok, keys} = fetch_from_upstream(config)
              Redix.command(:redix, ["SET", "oauth:jwks", JSON.encode!(keys), "EX", "3600"])
              {:ok, keys}

            {:ok, cached} ->
              {:ok, JSON.decode!(cached)}
          end
        end

        @impl true
        def fetch_key(kid, config) do
          {:ok, keys} = fetch_keys(config)
          case Enum.find(keys, &(&1["kid"] == kid)) do
            nil -> {:error, :not_found}
            key -> {:ok, key}
          end
        end
      end

  ## Configuration

      auth: [
        strategy: :oauth,
        key_provider: {ConduitMcp.OAuth.KeyProvider.JWKS,
          jwks_uri: "https://auth.example.com/.well-known/jwks.json",
          cache_ttl: :timer.hours(1)}
      ]
  """

  @doc """
  Fetches all available signing keys.
  """
  @callback fetch_keys(config :: keyword()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Fetches a specific key by its Key ID (kid).
  """
  @callback fetch_key(kid :: String.t(), config :: keyword()) ::
              {:ok, map()} | {:error, :not_found | term()}
end

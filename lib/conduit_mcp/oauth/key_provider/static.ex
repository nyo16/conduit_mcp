defmodule ConduitMcp.OAuth.KeyProvider.Static do
  @moduledoc """
  Static key provider for testing and development.

  Uses keys directly from configuration — no network calls.

  ## Configuration

      auth: [
        strategy: :oauth,
        key_provider: {ConduitMcp.OAuth.KeyProvider.Static,
          keys: [
            %{
              "kty" => "RSA",
              "kid" => "test-key-1",
              "n" => "...",
              "e" => "AQAB"
            }
          ]}
      ]

  You can also pass a single JOSE-compatible key map:

      key_provider: {ConduitMcp.OAuth.KeyProvider.Static,
        keys: [JOSE.JWK.to_map(my_jwk) |> elem(1)]}
  """

  @behaviour ConduitMcp.OAuth.KeyProvider

  @impl true
  def fetch_keys(config) do
    {:ok, Keyword.get(config, :keys, [])}
  end

  @impl true
  def fetch_key(kid, config) do
    keys = Keyword.get(config, :keys, [])

    case Enum.find(keys, fn key -> Map.get(key, "kid") == kid end) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end
end

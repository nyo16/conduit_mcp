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

    The `jwks_uri` must use `https`. For local development against a
    plain-HTTP authorization server, set `allow_insecure_jwks: true` in the
    provider config.

    Fetches use conservative HTTP settings: redirects are not followed,
    requests time out (5s connect / 10s receive), and responses are capped
    at 1MB. If a refresh fails and previously fetched keys are still cached,
    those stale keys are served (with a logged warning) so a transient
    authorization-server outage does not hard-fail all authentication —
    bounded by `:stale_max_age` (default 24 hours), after which the provider
    fails closed so revoked keys cannot validate tokens indefinitely.

    ## Security considerations

    **The `jwks_uri` must be trusted operator config — never client-derived.**
    Fetches are hardened against SSRF abuse (`https`-only unless
    `allow_insecure_jwks`, redirects disabled, 1MB body cap), but the URI
    *itself* is not range-checked: a `jwks_uri` pointing at a private or
    link-local address — e.g. the cloud metadata endpoint
    `http(s)://169.254.169.254/...` — **is fetched, not rejected**. Set
    `jwks_uri` from a configuration source you control. If it must come from a
    less-trusted source, restrict outbound egress at the network layer (the
    library deliberately does not block private ranges, since for most
    deployments the JWKS endpoint *is* an internal/private host).

    **Revocation lag during an outage.** While the JWKS endpoint is
    unreachable, cached keys keep validating tokens until `:stale_max_age`
    (default 24h), then the provider fails closed. The trade-off: a key
    revoked *during* an outage can still validate tokens for up to
    `:stale_max_age`. Lower it if your threat model needs faster revocation;
    raise it to tolerate longer authorization-server outages.

    ## Requirements

    Requires the `req` package. Use `0.6.1` or newer: earlier versions carry
    advisories this provider can reach, including unbounded decompression driven
    by the response's content-type (GHSA — Req `< 0.6.1`). The 1MB cap below is
    applied to the *decoded* body, so it does not protect against a compression
    bomb on its own.

        {:req, "~> 0.6"}
    """

    @behaviour ConduitMcp.OAuth.KeyProvider

    require Logger

    @table :conduit_mcp_jwks_cache
    @default_ttl :timer.hours(1)
    # Generous cap for a key set; matches the transports' 1MB body limit.
    @max_body_bytes 1_048_576
    # Stale keys must not serve forever — a revoked key would otherwise stay
    # valid for as long as the JWKS endpoint is unreachable.
    @default_stale_max_age :timer.hours(24)
    @req_options [
      redirect: false,
      retry: false,
      connect_options: [timeout: 5_000],
      receive_timeout: 10_000,
      decode_body: false
    ]

    @impl true
    def fetch_keys(config) do
      jwks_uri = Keyword.fetch!(config, :jwks_uri)
      ttl = Keyword.get(config, :cache_ttl, @default_ttl)

      case get_cached(jwks_uri, ttl) do
        {:ok, keys} ->
          {:ok, keys}

        :miss ->
          fetch_and_cache(jwks_uri, config)
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
      fetch_and_cache(jwks_uri, config)
    end

    # The table is owned by a supervised `Owner` Agent (started from
    # `ConduitMcp.Application`, like `ConduitMcp.Tasks.EtsStore.Owner` and
    # `ConduitMcp.Cancellation.Owner`) so it stays stable across short-lived
    # Bandit request processes. This matters for more than caching: without a
    # stable owner the table is created by whichever request first fetches keys
    # and is destroyed when that request ends — which not only defeats
    # cross-request caching but can make a *concurrent* request's `:ets.insert`
    # raise `ArgumentError` when the owner dies mid-operation (this path runs on
    # every authenticated request). `ensure_table/0` below is a self-healing
    # fallback for the rare case the table is missing (e.g. isolated unit tests
    # that don't boot the application).
    defp ensure_table do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      end

      :ok
    rescue
      # Lost check-then-create race: another process created the table first.
      ArgumentError -> :ok
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

    defp fetch_and_cache(jwks_uri, config) do
      with :ok <- validate_uri_scheme(jwks_uri, config) do
        ensure_table()
        Logger.debug("Fetching JWKS from #{jwks_uri}")

        case do_fetch(jwks_uri) do
          {:ok, keys} ->
            :ets.insert(@table, {jwks_uri, keys, System.system_time(:millisecond)})
            {:ok, keys}

          {:error, reason} ->
            serve_stale(jwks_uri, reason, config)
        end
      end
    end

    defp validate_uri_scheme(jwks_uri, config) do
      case URI.parse(jwks_uri) do
        %URI{scheme: "https"} ->
          :ok

        %URI{scheme: "http"} ->
          if Keyword.get(config, :allow_insecure_jwks, false) do
            :ok
          else
            Logger.error(
              "JWKS URI #{jwks_uri} must use https — " <>
                "set allow_insecure_jwks: true to override in dev/test"
            )

            {:error, :insecure_jwks_uri}
          end

        _ ->
          {:error, :invalid_jwks_uri}
      end
    end

    defp do_fetch(jwks_uri) do
      case Req.get(jwks_uri, @req_options) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          decode_jwks(body, jwks_uri)

        {:ok, %{status: status}} ->
          Logger.error("JWKS fetch failed with status #{status} from #{jwks_uri}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.error("JWKS fetch error from #{jwks_uri}: #{inspect(reason)}")
          {:error, reason}
      end
    end

    defp decode_jwks(body, jwks_uri) when byte_size(body) > @max_body_bytes do
      Logger.error("JWKS response from #{jwks_uri} exceeds #{@max_body_bytes} bytes")
      {:error, :jwks_too_large}
    end

    defp decode_jwks(body, jwks_uri) do
      case JSON.decode(body) do
        {:ok, %{"keys" => keys}} when is_list(keys) ->
          {:ok, keys}

        _ ->
          Logger.error("JWKS response from #{jwks_uri} is not a valid key set")
          {:error, :invalid_jwks}
      end
    end

    # A failed refresh must not hard-fail all authentication while we still
    # hold previously fetched keys — serve them loudly until the next
    # successful refresh, but only up to :stale_max_age (default 24h) so a
    # revoked key cannot keep validating tokens indefinitely.
    defp serve_stale(jwks_uri, reason, config) do
      stale_max_age = Keyword.get(config, :stale_max_age, @default_stale_max_age)

      case :ets.lookup(@table, jwks_uri) do
        [{^jwks_uri, keys, cached_at}] ->
          if System.system_time(:millisecond) - cached_at <= stale_max_age do
            Logger.warning(
              "JWKS refresh failed (#{inspect(reason)}); serving stale cached keys for #{jwks_uri}"
            )

            {:ok, keys}
          else
            Logger.error(
              "JWKS refresh failed and cached keys for #{jwks_uri} exceed stale_max_age; " <>
                "failing closed"
            )

            {:error, reason}
          end

        [] ->
          {:error, reason}
      end
    end

    defmodule Owner do
      @moduledoc """
      Long-lived process that owns the `:conduit_mcp_jwks_cache` ETS table so
      the JWKS cache survives — and stays stable under concurrency — across
      short-lived Bandit request processes. Started under `ConduitMcp.Supervisor`
      by `ConduitMcp.Application` whenever this provider module is available.

      Without a stable owner the table would be created by whichever request
      first fetched keys and destroyed when that request ended, both defeating
      cross-request caching and risking an `:ets.insert`/`:ets.lookup`
      `ArgumentError` in a concurrent request when the owner dies mid-operation.
      """

      use Agent

      def start_link(_opts) do
        Agent.start_link(
          fn ->
            # Create unconditionally (like Cancellation.Owner / Tasks.EtsStore.Owner):
            # at app boot the table does not exist yet, and owning it is the whole
            # point. A guarded create would let an earlier `ensure_table/0` keep the
            # table under a short-lived process while this Owner stays alive but
            # owns nothing — silently defeating the guarantee.
            :ets.new(:conduit_mcp_jwks_cache, [
              :named_table,
              :public,
              :set,
              read_concurrency: true
            ])

            :ok
          end,
          name: __MODULE__
        )
      end
    end
  end
end

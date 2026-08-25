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

    ## Refresh coordination

    Every authenticated request runs `fetch_keys/1`, and `fetch_key/2` calls
    `refresh_keys/1` for any `kid` it has not seen. Both are single-flighted
    through a lock row in the cache table:

      * **Single flight.** Exactly one process performs an outbound fetch per
        `jwks_uri` at a time. Others wait briefly for the cache to be filled
        and then read it, falling back to the stale-cache path. Without this,
        a TTL lapse at 500 rps produced 500 simultaneous fetches, each holding
        a Bandit process for up to 15 s — and IdPs rate-limit JWKS endpoints,
        so a routine expiry became a total auth outage.

      * **Cooldown.** `refresh_keys/1` refuses to fetch more often than
        `:refresh_cooldown` (default 30 s). `fetch_signing_key/2` runs
        *before* any signature check, so an unauthenticated caller can
        otherwise drive one outbound fetch per request just by inventing a
        `kid`.

      * **Lock age.** A lock older than `:refresh_lock_max_age` (default 30 s,
        comfortably past the HTTP timeouts) is treated as abandoned, so a
        crashed holder cannot wedge refreshes.

    ## Requirements

    Requires the `req` package, `0.6.1` or newer: earlier versions carry
    advisories this provider can reach, including unbounded decompression
    driven by the response's content-type (GHSA — Req `< 0.6.1`). This
    provider additionally sets `compressed: false` and streams the response
    through a size-bounded collector, so the 1 MB cap is applied to the bytes
    actually received rather than to an already-buffered, already-decompressed
    body.
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
      # Pool checkout is bounded by Finch's own 5 s default. It is deliberately
      # not set here: `pool_timeout` was a top-level Req option in 0.6 and moved
      # under `finch:` in 0.7, so setting it warns on one of the two versions
      # this provider supports — for a value identical to the default.

      # No accept-encoding: the byte cap below counts bytes on the wire, so a
      # compressed response must not be able to expand past it.
      compressed: false,
      decode_body: false
    ]

    # Refresh coordination. See the "Refresh coordination" section above.
    @default_refresh_cooldown :timer.seconds(30)
    @default_lock_max_age :timer.seconds(30)
    # How long a process that lost the single-flight race waits for the winner
    # to publish keys before giving up and taking the stale-cache path. Must
    # exceed the HTTP budget (5 s connect + 10 s receive) or a slow-but-healthy
    # IdP makes every waiter give up while the winner is still succeeding —
    # which on a cold cache means 401s for everyone but one.
    @lock_wait_timeout 16_000
    @lock_wait_step 25

    @impl true
    def fetch_keys(config) do
      jwks_uri = Keyword.fetch!(config, :jwks_uri)
      ttl = Keyword.get(config, :cache_ttl, @default_ttl)

      case get_cached(jwks_uri, ttl) do
        {:ok, keys} ->
          {:ok, keys}

        :miss ->
          # Deliberately *not* gated by `cooling_down?/2`. The TTL is the
          # operator's explicit staleness policy and the cooldown must not
          # override it, and checking it here would preempt the single-flight
          # wait: a request arriving after the winner recorded `:last_refresh`
          # but before it published keys would fail instead of waiting. The
          # pile-up this would guard against is already bounded — exactly one
          # process fetches and the rest wait on the lock, which the winner
          # releases as soon as it finishes (fast on a refused connection).
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

    # `fetch_key/2` calls this for *any* unknown `kid`, and it runs before any
    # signature check — so without a cooldown an unauthenticated caller drives
    # one outbound fetch per request by inventing a kid.
    defp refresh_keys(config) do
      jwks_uri = Keyword.fetch!(config, :jwks_uri)

      if cooling_down?(jwks_uri, config) do
        # `serve_stale/3`, not a raw cache read: it is the single place that
        # decides whether an aged key set may still be served, and it is what
        # enforces `:stale_max_age`. A bare read here would authenticate against
        # keys the fetching path has already refused.
        serve_stale(jwks_uri, :not_found, config)
      else
        fetch_and_cache(jwks_uri, config)
      end
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
    @doc false
    # One source of truth for the table's options, so the Owner and the
    # self-healing fallback below cannot drift into creating tables with
    # different concurrency semantics.
    @spec table_opts() :: [atom() | tuple()]
    def table_opts, do: [:named_table, :public, :set, read_concurrency: true]

    defp ensure_table do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, table_opts())
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

        case acquire_lock(jwks_uri, config) do
          :ok ->
            try do
              store_fetch(jwks_uri, config)
            after
              :ets.delete(@table, {:refresh_lock, jwks_uri})
            end

          :busy ->
            await_refresh(jwks_uri, config)
        end
      end
    end

    defp store_fetch(jwks_uri, config) do
      Logger.debug("Fetching JWKS from #{jwks_uri}")
      now = System.system_time(:millisecond)

      # Recorded whether or not the fetch succeeds: the cooldown exists to
      # bound outbound attempts, and a failing endpoint is exactly when
      # hammering it is worst.
      :ets.insert(@table, {{:last_refresh, jwks_uri}, now})

      case do_fetch(jwks_uri) do
        {:ok, keys} ->
          :ets.insert(@table, {jwks_uri, keys, System.system_time(:millisecond)})
          {:ok, keys}

        {:error, reason} ->
          serve_stale(jwks_uri, reason, config)
      end
    end

    # `:ets.insert_new/2` is the whole lock: it is atomic, so exactly one
    # process wins. A lock older than :refresh_lock_max_age is abandoned —
    # otherwise a holder that was killed mid-fetch would wedge every future
    # refresh.
    defp acquire_lock(jwks_uri, config) do
      key = {:refresh_lock, jwks_uri}
      now = System.system_time(:millisecond)

      if :ets.insert_new(@table, {key, now}) do
        :ok
      else
        reclaim_stale_lock(jwks_uri, key, now, config)
      end
    end

    # Compare-and-swap on the observed timestamp, not a blind overwrite: two
    # processes seeing the same expired lock would otherwise both win and both
    # fetch, weakening the "exactly one outbound fetch" guarantee this lock
    # exists to provide.
    defp reclaim_stale_lock(jwks_uri, key, now, config) do
      max_age = Keyword.get(config, :refresh_lock_max_age, @default_lock_max_age)

      case :ets.lookup(@table, key) do
        [{^key, acquired_at}] when now - acquired_at > max_age ->
          swapped =
            :ets.select_replace(@table, [
              {{key, acquired_at}, [], [{:const, {key, now}}]}
            ])

          if swapped == 1 do
            Logger.warning("JWKS refresh lock for #{jwks_uri} is stale; reclaimed")
            :ok
          else
            :busy
          end

        _ ->
          :busy
      end
    end

    # Lost the single-flight race. Wait for the winner to publish keys rather
    # than opening a second connection to a rate-limited endpoint; fall back to
    # the stale cache (which fails closed) if it never does.
    defp await_refresh(jwks_uri, config, waited \\ 0)

    defp await_refresh(jwks_uri, config, waited) when waited >= @lock_wait_timeout do
      serve_stale(jwks_uri, :refresh_in_progress, config)
    end

    defp await_refresh(jwks_uri, config, waited) do
      if :ets.member(@table, {:refresh_lock, jwks_uri}) do
        Process.sleep(@lock_wait_step)
        await_refresh(jwks_uri, config, waited + @lock_wait_step)
      else
        # Must go through `serve_stale/3` for the same reason as the cooldown
        # branch: the winner may have just failed closed because the cached row
        # is past `:stale_max_age`, and a bare `cached_keys/1` here would hand
        # the waiter exactly those keys — verifying a token against a key set
        # whose fail-closed deadline has passed.
        case fresh_cached_keys(jwks_uri, config) do
          {:ok, keys} -> {:ok, keys}
          :miss -> serve_stale(jwks_uri, :refresh_in_progress, config)
        end
      end
    end

    defp cooling_down?(jwks_uri, config) do
      ensure_table()
      cooldown = Keyword.get(config, :refresh_cooldown, @default_refresh_cooldown)

      case :ets.lookup(@table, {:last_refresh, jwks_uri}) do
        [{_key, at}] -> System.system_time(:millisecond) - at < cooldown
        [] -> false
      end
    end

    # Keys the winner just published: fresh enough that the TTL has not lapsed,
    # so no staleness question arises. Anything older is left to
    # `serve_stale/3`, which applies `:stale_max_age`.
    defp fresh_cached_keys(jwks_uri, config) do
      get_cached(jwks_uri, Keyword.get(config, :cache_ttl, @default_ttl))
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
      req_opts = Keyword.put(@req_options, :into, &collect_bounded/2)

      case Req.get(jwks_uri, req_opts) do
        {:ok, %{private: %{jwks_too_large: true}}} ->
          Logger.error("JWKS response from #{jwks_uri} exceeds #{@max_body_bytes} bytes")
          {:error, :jwks_too_large}

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

    # The cap is enforced *while streaming*, not on an already-buffered body:
    # a multi-gigabyte response would otherwise exhaust the VM before any
    # `byte_size/1` guard ran. `compressed: false` keeps these bytes the same
    # bytes the cap is meant to count.
    defp collect_bounded({:data, data}, {req, resp}) do
      body = resp.body <> data

      if byte_size(body) > @max_body_bytes do
        {:halt, {req, Req.Response.put_private(%{resp | body: ""}, :jwks_too_large, true)}}
      else
        {:cont, {req, %{resp | body: body}}}
      end
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

      # Not a GenServer itself: the process is a `ConduitMcp.EtsOwner`
      # registered under this module's name. This module is the child spec.
      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      end

      def start_link(_opts) do
        ConduitMcp.EtsOwner.start_link(
          __MODULE__,
          :conduit_mcp_jwks_cache,
          ConduitMcp.OAuth.KeyProvider.JWKS.table_opts()
        )
      end
    end
  end
end

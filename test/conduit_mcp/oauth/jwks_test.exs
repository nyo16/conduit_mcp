defmodule ConduitMcp.OAuth.KeyProvider.JWKSTest do
  # async: false — uses Req.default_options (global) to route requests
  # through Req.Test stubs, and a shared named ETS cache table.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ConduitMcp.OAuth.KeyProvider.JWKS

  @table :conduit_mcp_jwks_cache

  @keys [%{"kty" => "RSA", "kid" => "key-1", "n" => "abc", "e" => "AQAB"}]

  setup do
    Req.default_options(plug: {Req.Test, __MODULE__})

    # Global/shared mode so spawned tasks (the concurrency test below) resolve
    # the same stub as the test process. Safe here: this module is async: false
    # and is the only Req.Test user, so it won't leak into concurrent tests.
    Req.Test.set_req_test_to_shared()

    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    on_exit(fn ->
      # Both halves of the global mutation are undone. Restoring
      # :default_options alone left Req.Test in *shared* mode for the rest of
      # the run, so any later module's stubs resolved through this process —
      # the safety argument was a comment, not an invariant.
      Req.Test.set_req_test_to_private(self())
      Application.delete_env(:req, :default_options)
    end)

    :ok
  end

  defp stub_json(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end)
  end

  test "fetches and caches keys from an https JWKS endpoint" do
    stub_json(200, %{"keys" => @keys})

    config = [jwks_uri: "https://auth.example.com/jwks-fetch"]
    assert {:ok, @keys} = JWKS.fetch_keys(config)

    # Second call served from cache — break the stub to prove no refetch
    Req.Test.stub(__MODULE__, fn _conn -> raise "must not refetch" end)
    assert {:ok, @keys} = JWKS.fetch_keys(config)
  end

  test "rejects http:// URIs unless allow_insecure_jwks is set" do
    assert {:error, :insecure_jwks_uri} =
             JWKS.fetch_keys(jwks_uri: "http://auth.example.com/jwks-insecure")

    stub_json(200, %{"keys" => @keys})

    assert {:ok, @keys} =
             JWKS.fetch_keys(
               jwks_uri: "http://auth.example.com/jwks-insecure-ok",
               allow_insecure_jwks: true
             )
  end

  test "does not follow redirects" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example.com/jwks")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, {:http_error, 302}} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-redirect")
  end

  test "rejects a response body past the 1 MB cap and accepts one at it" do
    # Req.Test hands the collector the whole body as a single chunk, so this
    # pins the cap's boundary, not incremental streaming.
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("a", 1_048_577))
    end)

    assert {:error, :jwks_too_large} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-huge-boundary")

    # Exactly at the cap passes the size check and fails only on parsing.
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("a", 1_048_576))
    end)

    assert {:error, :invalid_jwks} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-at-cap")
  end

  test "never decompresses a response body, even a valid gzipped key set" do
    # A valid key set, so the only way this can fail to parse is that the
    # provider left the gzip bytes alone. Decompressing it would return keys.
    #
    # Req's `decompress_body` step skips when the request streams through
    # `into:`, and also when `compressed: false` is set. Either guard alone
    # keeps these bytes intact, so this fails only if `do_fetch/1` drops both
    # the `into:` collector and `compressed: false`.
    gzipped = :zlib.gzip(JSON.encode!(%{"keys" => @keys}))

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, gzipped)
    end)

    assert {:error, :invalid_jwks} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-gzip")
  end

  test "rejects non-HTTP URI schemes" do
    # The SSRF/LFI guard: URI.parse/1 happily accepts these, and the provider
    # must not hand them to the HTTP client.
    for uri <- [
          "file:///etc/passwd",
          "ftp://auth.example.com/jwks.json",
          "gopher://auth.example.com/jwks",
          "auth.example.com/jwks.json",
          "/etc/passwd"
        ] do
      assert {:error, :invalid_jwks_uri} = JWKS.fetch_keys(jwks_uri: uri),
             "expected #{inspect(uri)} to be rejected"
    end
  end

  test "a transport error serves stale keys when the cache is warm" do
    uri = "https://auth.example.com/jwks-transport-warm"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # Past the TTL but well inside :stale_max_age, so the stale-serve path is
    # what we exercise (not the fail-closed path below it).
    [{^uri, keys, _at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 5_000})

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :outbound_fetch)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri, cache_ttl: 1, refresh_cooldown: 0)
    # The keys came from a failed refresh, not from a cache read that skipped it.
    assert_received :outbound_fetch
  end

  test "a transport error fails closed when the cache is cold" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

    assert {:error, %Req.TransportError{reason: :nxdomain}} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-transport-cold")
  end

  test "rejects responses that are not a valid key set" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)

    assert {:error, :invalid_jwks} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-bad-json")

    stub_json(200, %{"nokeys" => true})

    assert {:error, :invalid_jwks} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-bad-shape")
  end

  test "serves stale cached keys when a refresh fails" do
    uri = "https://auth.example.com/jwks-stale"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # Backdate the cached row past the TTL (but within stale_max_age),
    # then make the endpoint fail
    [{^uri, keys, _cached_at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :outbound_fetch)
      Plug.Conn.send_resp(conn, 500, JSON.encode!(%{"error" => "down"}))
    end)

    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri, cache_ttl: 1, refresh_cooldown: 0)
    assert_received :outbound_fetch
  end

  test "fails closed when stale cached keys exceed :stale_max_age" do
    uri = "https://auth.example.com/jwks-too-stale"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, keys, _cached_at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    stub_json(500, %{"error" => "down"})

    assert {:error, {:http_error, 500}} =
             JWKS.fetch_keys(
               jwks_uri: uri,
               cache_ttl: 1,
               stale_max_age: 1_000,
               refresh_cooldown: 0
             )
  end

  test "fails when refresh fails and no cached keys exist" do
    stub_json(500, %{"error" => "down"})

    assert {:error, {:http_error, 500}} =
             JWKS.fetch_keys(jwks_uri: "https://auth.example.com/jwks-down")
  end

  test "key rollover: an unknown kid refreshes once the cooldown has passed" do
    uri = "https://auth.example.com/jwks-rollover"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # IdP rotates: kid key-2 appears upstream while the cache still has key-1
    rotated = [%{"kty" => "RSA", "kid" => "key-2", "n" => "def", "e" => "AQAB"}]
    stub_json(200, %{"keys" => rotated})

    assert {:ok, %{"kid" => "key-2"}} =
             JWKS.fetch_key("key-2", jwks_uri: uri, refresh_cooldown: 0)
  end

  test "the single-flight waiter also honours :stale_max_age" do
    # The waiter used to read the cache with no age check, so when the lock
    # winner correctly failed closed on a key set past :stale_max_age, the
    # concurrent waiter served those same keys and authenticated the token.
    uri = "https://auth.example.com/jwks-waiter-stale"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # Age the row well past :stale_max_age, and clear the cooldown the warm-up
    # fetch started so the first task really fetches.
    [{^uri, keys, _at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    :ets.delete(@table, {:last_refresh, uri})

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :outbound_fetch)
      # Hold the lock so the second task is a genuine waiter.
      Process.sleep(80)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    # `refresh_cooldown: 0`: a task that ran only after the winner released
    # the lock would then fetch again and trip `refute_received` below, so
    # the assertion proves the other tasks were waiters, not serialised.
    config = [jwks_uri: uri, cache_ttl: 1, stale_max_age: 1_000, refresh_cooldown: 0]

    results =
      1..4
      |> Task.async_stream(fn _ -> JWKS.fetch_keys(config) end,
        max_concurrency: 4,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert_receive :outbound_fetch
    # The other three waited on the lock rather than fetching themselves.
    refute_received :outbound_fetch

    # Winner and waiters must agree: nobody gets the over-age keys.
    refute Enum.any?(results, &match?({:ok, _}, &1)),
           "a waiter served keys past :stale_max_age: #{inspect(results)}"
  end

  test "an unknown kid inside the cooldown window does not refetch" do
    # fetch_signing_key/2 runs before any signature check, so an
    # unauthenticated caller could otherwise drive one outbound fetch per
    # request just by inventing a kid.
    uri = "https://auth.example.com/jwks-cooldown"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, _keys, cached_at}] = :ets.lookup(@table, uri)

    Req.Test.stub(__MODULE__, fn _conn -> raise "must not refetch inside the cooldown" end)

    for kid <- 1..20 do
      assert {:error, :not_found} =
               JWKS.fetch_key("random-#{kid}", jwks_uri: uri, refresh_cooldown: 60_000)
    end

    # And the cooldown path must not extend the TTL of the cached row.
    assert [{^uri, @keys, ^cached_at}] = :ets.lookup(@table, uri)
  end

  test "an invented kid inside the cooldown window logs no warning" do
    uri = "https://auth.example.com/jwks-cooldown-log"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    Req.Test.stub(__MODULE__, fn _conn -> raise "must not refetch inside the cooldown" end)

    log =
      capture_log(fn ->
        assert {:error, :not_found} =
                 JWKS.fetch_key("invented", jwks_uri: uri, refresh_cooldown: 60_000)
      end)

    # No refresh was attempted, so nothing failed.
    refute log =~ "[warning]"
  end

  test "past :stale_max_age inside the cooldown fails closed without logging a failed refresh" do
    uri = "https://auth.example.com/jwks-cooldown-too-stale"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    # The warm-up fetch started the cooldown; age the row past :stale_max_age.
    [{^uri, keys, _at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})

    Req.Test.stub(__MODULE__, fn _conn -> raise "must not refetch inside the cooldown" end)

    config = [jwks_uri: uri, cache_ttl: 1, stale_max_age: 1_000, refresh_cooldown: 60_000]

    log = capture_log(fn -> assert {:error, :refresh_cooldown} = JWKS.fetch_keys(config) end)

    # No refresh was attempted, so none failed: one `[error]` line per
    # unauthenticated request would otherwise flood the log for the window.
    refute log =~ "[error]"
    refute log =~ "refresh failed"
  end

  test "a lapsed TTL with a failing IdP fetches once per cooldown, serving stale keys" do
    # `authenticate` runs before `rate_limit`, so without the cooldown every
    # request after the TTL lapses is one outbound fetch to a failing IdP.
    uri = "https://auth.example.com/jwks-expired-failing"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, keys, _at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    :ets.delete(@table, {:last_refresh, uri})

    fetches = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(fetches, 1, 1)
      Plug.Conn.send_resp(conn, 503, "")
    end)

    config = [jwks_uri: uri, cache_ttl: 1, refresh_cooldown: 60_000]

    for _ <- 1..50 do
      assert {:ok, @keys} = JWKS.fetch_keys(config)
    end

    assert :counters.get(fetches, 1) == 1

    # The cooldown serves through `:stale_max_age`, not around it.
    assert {:error, _} = JWKS.fetch_keys(Keyword.put(config, :stale_max_age, 1_000))
    assert :counters.get(fetches, 1) == 1
  end

  test "a cold cache with a failing IdP fetches once per cooldown" do
    # Nothing is cached to serve, so without the cooldown every well-formed
    # JWT drives another outbound fetch at the failing IdP, back to back.
    uri = "https://auth.example.com/jwks-cold-cooldown"
    fetches = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(fetches, 1, 1)
      Plug.Conn.send_resp(conn, 503, "")
    end)

    config = [jwks_uri: uri, refresh_cooldown: 60_000]

    # The first-ever fetch has no cooldown to honour.
    assert {:error, {:http_error, 503}} = JWKS.fetch_keys(config)

    for _ <- 1..10 do
      assert {:error, :refresh_cooldown} = JWKS.fetch_keys(config)
    end

    assert :counters.get(fetches, 1) == 1

    # Once the cooldown has passed, the provider fetches again and recovers.
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(Keyword.put(config, :refresh_cooldown, 0))
  end

  test "a request arriving mid-refresh waits for the new keys instead of serving stale" do
    # The winner records `:last_refresh` before it fetches, so a cooldown
    # check ahead of the lock check would hand this request the old key set.
    uri = "https://auth.example.com/jwks-mid-refresh"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, keys, _at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, System.system_time(:millisecond) - 60_000})
    :ets.delete(@table, {:last_refresh, uri})

    rotated = [%{"kty" => "RSA", "kid" => "key-2", "n" => "def", "e" => "AQAB"}]
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:fetching, self()})

      receive do
        :publish -> :ok
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(%{"keys" => rotated}))
    end)

    config = [jwks_uri: uri, cache_ttl: 5_000]
    winner = Task.async(fn -> JWKS.fetch_keys(config) end)
    assert_receive {:fetching, fetcher}

    # Lock held, `:last_refresh` recorded, nothing published yet.
    late = Task.async(fn -> JWKS.fetch_keys(config) end)
    assert Task.yield(late, 100) == nil

    send(fetcher, :publish)
    assert {:ok, ^rotated} = Task.await(winner)
    assert {:ok, ^rotated} = Task.await(late)
  end

  test "an unknown kid arriving mid-refresh waits for the new keys" do
    # The winner records `:last_refresh` before it fetches, so a cooldown
    # check ahead of the lock check would answer this kid from the old key
    # set — a 401 for every new-kid token that lands mid-rotation.
    uri = "https://auth.example.com/jwks-kid-mid-refresh"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)
    :ets.delete(@table, {:last_refresh, uri})

    rotated = [%{"kty" => "RSA", "kid" => "key-2", "n" => "def", "e" => "AQAB"}]
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:fetching, self()})

      receive do
        :publish -> :ok
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(%{"keys" => rotated}))
    end)

    # The cached key-1 set is inside its TTL, so both calls reach
    # `refresh_keys/1` through the unknown kid.
    config = [jwks_uri: uri, refresh_cooldown: 60_000]
    winner = Task.async(fn -> JWKS.fetch_key("key-2", config) end)
    assert_receive {:fetching, fetcher}

    # Lock held, `:last_refresh` recorded, nothing published yet.
    late = Task.async(fn -> JWKS.fetch_key("key-2", config) end)
    assert Task.yield(late, 100) == nil

    send(fetcher, :publish)
    assert {:ok, %{"kid" => "key-2"}} = Task.await(winner)
    assert {:ok, %{"kid" => "key-2"}} = Task.await(late)
  end

  test "concurrent cold-cache requests produce exactly one outbound fetch" do
    uri = "https://auth.example.com/jwks-single-flight"
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :outbound_fetch)
      # Hold the connection long enough that every other task is genuinely
      # racing, not merely arriving after the winner finished.
      Process.sleep(50)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(%{"keys" => @keys}))
    end)

    results =
      1..25
      |> Task.async_stream(fn _ -> JWKS.fetch_keys(jwks_uri: uri) end,
        max_concurrency: 25,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, @keys}, &1))

    assert_receive :outbound_fetch
    refute_receive :outbound_fetch, 100
  end

  test "a stale refresh lock is reclaimed rather than wedging refreshes" do
    uri = "https://auth.example.com/jwks-stale-lock"

    # A holder that was killed mid-fetch leaves its lock row behind.
    :ets.insert(@table, {{:refresh_lock, uri}, 0})

    stub_json(200, %{"keys" => @keys})

    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)
    refute :ets.member(@table, {:refresh_lock, uri})
  end

  test "TTL expiry triggers a refetch" do
    uri = "https://auth.example.com/jwks-ttl"
    stub_json(200, %{"keys" => @keys})
    assert {:ok, @keys} = JWKS.fetch_keys(jwks_uri: uri)

    [{^uri, keys, _cached_at}] = :ets.lookup(@table, uri)
    :ets.insert(@table, {uri, keys, 0})

    fresh = [%{"kty" => "RSA", "kid" => "key-fresh", "n" => "ghi", "e" => "AQAB"}]
    stub_json(200, %{"keys" => fresh})

    assert {:ok, ^fresh} = JWKS.fetch_keys(jwks_uri: uri, cache_ttl: 1, refresh_cooldown: 0)
  end

  test "concurrent fetch_keys on one URI is race-safe (ETS cache-write/ensure_table)" do
    uri = "https://auth.example.com/jwks-concurrent"
    stub_json(200, %{"keys" => @keys})

    # Many simultaneous first-fetches all miss the cache and race on
    # ensure_table/0 (check-then-create) and :ets.insert for the same key.
    results =
      1..25
      |> Task.async_stream(fn _ -> JWKS.fetch_keys(jwks_uri: uri) end,
        max_concurrency: 25,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, @keys}, &1))
    # All writers converged on exactly one cached row for the URI.
    assert [{^uri, @keys, _cached_at}] = :ets.lookup(@table, uri)
  end
end

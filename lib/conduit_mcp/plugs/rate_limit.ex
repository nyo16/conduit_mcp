defmodule ConduitMcp.Plugs.RateLimit do
  @moduledoc """
  Rate limiting plug for MCP servers.

  This plug is **completely optional**. If you don't need rate limiting, simply
  omit the `:rate_limit` option from your transport config — no additional
  dependencies are required.

  ## Dependencies

  Rate limiting requires the [`hammer`](https://hex.pm/packages/hammer) package.
  Add it to your `mix.exs` only if you intend to use this plug:

      {:hammer, "~> 7.2"}

  ## How it works

  You define your own Hammer module, supervise it in your application, and pass
  it as the `:backend` option. This gives you full control over the backend
  (`:ets`, `:atomic`), algorithm (`:fix_window`, `:leaky_bucket`, etc.), and
  supervision strategy.

  ## Options

  - `:backend` - **Required when enabled.** A module that implements `hit/3`
    (e.g., a module defined with `use Hammer, backend: :ets`). You must supervise
    this module in your own application supervision tree.
  - `:enabled` - Enable/disable rate limiting (default: `true`)
  - `:scale` - Time window in milliseconds (default: `60_000`)
  - `:limit` - Maximum requests per window (default: `60`)
  - `:key_func` - Function to derive the rate limit key from the connection
    (default: the client's IPv4 address or IPv6 `/64`, see below).
    Signature: `(Plug.Conn.t()) -> String.t()`.
    Pass a remote capture (`&MyApp.RateKeys.http/1`), not an anonymous `fn`:
    `Plug.Router.forward/2` escapes transport init opts at compile time, and
    anonymous functions cannot be escaped.

  ## Setup

  ### 1. Define your Hammer module

      defmodule MyApp.RateLimiter do
        use Hammer, backend: :ets
      end

  ### 2. Add to your supervision tree

      children = [
        {MyApp.RateLimiter, [clean_period: :timer.minutes(1)]}
      ]

  ### 3. Pass as `:backend` in transport config

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP,
              server_module: MyApp.MCPServer,
              rate_limit: [
                backend: MyApp.RateLimiter,
                scale: :timer.seconds(60),
                limit: 100
              ]},
       port: 4001}

  ## Default key

  The default key is `ConduitMcp.Principal.client_bucket/1`, because this plug
  bounds raw connections including unauthenticated ones: the address for an
  IPv4 client, and the `/64` prefix (`"2001:db8:1:2::/64"`) for an IPv6 one.
  One host is typically allocated a whole `/64` and picks the low 64 bits
  itself, so a per-address key would let it rotate addresses for a fresh
  bucket on every request. IPv4-mapped IPv6 addresses (`::ffff:192.0.2.1`)
  count as the embedded IPv4 address.

  To key on the precise address instead — for example when every client
  behind one `/64` is a distinct tenant you trust — pass
  `ConduitMcp.Principal.client_ip/1`:

      rate_limit: [
        backend: MyApp.RateLimiter,
        key_func: &ConduitMcp.Principal.client_ip/1
      ]

  ## Per-user rate limiting

  To bucket by authenticated caller instead, use the canonical principal
  (anonymous callers still fall back to `ConduitMcp.Principal.client_bucket/1`):

      rate_limit: [
        backend: MyApp.RateLimiter,
        limit: 100,
        key_func: &ConduitMcp.Principal.rate_limit_key/1
      ]

  Do not hand-roll `conn.remote_ip |> :inet.ntoa() |> to_string()` in a custom
  key function: `:inet.ntoa/1` returns `{:error, :einval}` for a malformed
  address and `to_string/1` on that raises, killing the request process
  instead of returning 429. `ConduitMcp.Principal.client_ip/1` and
  `ConduitMcp.Principal.client_bucket/1` return `"unknown"` instead.

  ## Without rate limiting

  Simply omit the `:rate_limit` option from your transport config. The `hammer`
  dependency is not required and won't be compiled.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    backend = Keyword.get(opts, :backend)

    if enabled and is_nil(backend) do
      raise ArgumentError,
            "ConduitMcp.Plugs.RateLimit requires a :backend option (a module with hit/3)"
    end

    %{
      enabled: enabled,
      backend: backend,
      scale: Keyword.get(opts, :scale, 60_000),
      limit: Keyword.get(opts, :limit, 60),
      key_func: Keyword.get(opts, :key_func, &__MODULE__.default_key_func/1)
    }
  end

  @impl true
  def call(conn, %{enabled: false}) do
    conn
  end

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
  end

  def call(conn, %{backend: backend, scale: scale, limit: limit, key_func: key_func}) do
    key = key_func.(conn)
    start_time = System.monotonic_time()

    case backend.hit(key, scale, limit) do
      {:allow, count} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:conduit_mcp, :rate_limit, :check],
          %{duration: duration},
          %{key: key, status: :allow, count: count}
        )

        conn

      {:deny, ms_until_next} ->
        duration = System.monotonic_time() - start_time
        # Round up: a client told to wait 1 s after a 1.5 s wait retries
        # early and is denied again. Hammer's token-bucket backend reports
        # sub-second waits, so flooring was observable.
        retry_after = max(div(ms_until_next + 999, 1000), 1)

        :telemetry.execute(
          [:conduit_mcp, :rate_limit, :check],
          %{duration: duration},
          %{key: key, status: :deny, retry_after: retry_after}
        )

        Logger.warning("Rate limit exceeded for key=#{key}")

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", to_string(retry_after))
        |> send_resp(
          429,
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{
              "code" => ConduitMcp.Errors.server_error(),
              "message" => "Rate limit exceeded"
            }
          })
        )
        |> halt()
    end
  end

  @doc false
  # Public, and captured remotely below, because `Transport.Shared.init/2`
  # resolves this plug at `init/1` time and the result is embedded in the
  # router's options. `Plug.Router.forward/2` escapes those options at compile
  # time and a *local* capture cannot be escaped - `forward "/mcp", to:
  # ConduitMcp.Transport.StreamableHTTP, init_opts: [rate_limit: [...]]` failed
  # to compile with "cannot escape #Function<...default_key_func>". Remote
  # captures escape fine.
  #
  # `:inet.ntoa/1` returns `{:error, :einval}` for a malformed remote_ip and
  # `to_string/1` on that raises, killing the request process instead of
  # returning 429. ConduitMcp.Principal.client_bucket/1 handles it.
  def default_key_func(conn) do
    ConduitMcp.Principal.client_bucket(conn)
  end
end

defmodule ConduitMcp.Plugs.RateLimit do
  @moduledoc """
  Rate limiting plug for MCP servers.

  Provides configurable rate limiting using a user-supplied Hammer backend module.
  Mirrors the auth plug pattern — configurable per-transport, wired through
  `conn.private`, skips CORS OPTIONS, halts with JSON-RPC error on rejection,
  emits telemetry.

  ## Options

  - `:backend` - **Required.** A module that implements `hit/3` (e.g., a module
    defined with `use Hammer, backend: :ets`). The user must supervise this module
    in their own application supervision tree.
  - `:enabled` - Enable/disable rate limiting (default: `true`)
  - `:scale` - Time window in milliseconds (default: `60_000`)
  - `:limit` - Maximum requests per window (default: `60`)
  - `:key_func` - Function to derive the rate limit key from the connection
    (default: IP-based). Signature: `(Plug.Conn.t()) -> String.t()`

  ## Examples

  ### Define your Hammer module

      defmodule MyApp.RateLimiter do
        use Hammer, backend: :ets
      end

  ### Add to your supervision tree

      children = [
        {MyApp.RateLimiter, [clean_period: :timer.minutes(1)]}
      ]

  ### Basic IP-based rate limiting

      plug ConduitMcp.Plugs.RateLimit,
        backend: MyApp.RateLimiter,
        scale: :timer.seconds(60),
        limit: 100

  ### Per-user rate limiting

      plug ConduitMcp.Plugs.RateLimit,
        backend: MyApp.RateLimiter,
        limit: 100,
        key_func: fn conn ->
          case conn.assigns[:current_user] do
            %{id: id} -> "user:\#{id}"
            _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
          end
        end

  ### Disabled

      plug ConduitMcp.Plugs.RateLimit, enabled: false
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
      key_func: Keyword.get(opts, :key_func, &default_key_func/1)
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
        retry_after = max(div(ms_until_next, 1000), 1)

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
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{"code" => -32000, "message" => "Rate limit exceeded"}
          })
        )
        |> halt()
    end
  end

  defp default_key_func(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end

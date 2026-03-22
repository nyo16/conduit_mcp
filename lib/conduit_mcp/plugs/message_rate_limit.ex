defmodule ConduitMcp.Plugs.MessageRateLimit do
  @moduledoc """
  Message-level rate limiting plug for MCP servers.

  While the HTTP-level rate limit (`ConduitMcp.Plugs.RateLimit`) limits raw HTTP
  connections, this plug limits the number of MCP **message interactions** (tool
  calls, resource reads, prompt gets) a client can make per time window.

  Think of it as: HTTP rate limit = "how fast can you knock on the door",
  message rate limit = "how many questions can you ask once inside."

  This plug is **completely optional**. If you don't need message-level rate
  limiting, simply omit the `:message_rate_limit` option from your transport
  config — no additional dependencies are required.

  ## Dependencies

  Message rate limiting requires the [`hammer`](https://hex.pm/packages/hammer)
  package. Add it to your `mix.exs` only if you intend to use this plug:

      {:hammer, "~> 7.2"}

  ## How it works

  - Only POST requests are counted (GET/OPTIONS pass through)
  - JSON-RPC notifications (requests without an `id` field) are not counted
  - Specific methods can be excluded (e.g., `"initialize"`, `"ping"`)
  - Keys are prefixed with `"msg:"` to prevent Hammer counter collision when
    both HTTP and message rate limiters share the same backend
  - Authenticated users are tracked by user ID; anonymous users by IP

  ## Options

  - `:backend` - **Required when enabled.** A module that implements `hit/3`
    (e.g., a module defined with `use Hammer, backend: :ets`). You must supervise
    this module in your own application supervision tree.
  - `:enabled` - Enable/disable message rate limiting (default: `true`)
  - `:scale` - Time window in milliseconds (default: `300_000` / 5 minutes)
  - `:limit` - Maximum messages per window (default: `50`)
  - `:key_func` - Function to derive the rate limit key from the connection
    (default: user-aware with `"msg:"` prefix). Signature: `(Plug.Conn.t()) -> String.t()`
  - `:excluded_methods` - List of MCP method names to skip rate limiting for
    (default: `[]`). Example: `["initialize", "ping"]`

  ## Setup

  ### 1. Define your Hammer module

      defmodule MyApp.RateLimiter do
        use Hammer, backend: :ets
      end

  ### 2. Add to your supervision tree

      children = [
        {MyApp.RateLimiter, [clean_period: :timer.minutes(1)]}
      ]

  ### 3. Pass as `:message_rate_limit` in transport config

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP,
              server_module: MyApp.MCPServer,
              rate_limit: [
                backend: MyApp.RateLimiter,
                scale: :timer.seconds(60),
                limit: 100
              ],
              message_rate_limit: [
                backend: MyApp.RateLimiter,
                scale: :timer.minutes(5),
                limit: 50
              ]},
       port: 4001}

  ## Per-user rate limiting

  The default key function already supports per-user rate limiting when the
  `ConduitMcp.Plugs.Auth` plug is in the pipeline. If `conn.assigns[:current_user]`
  is set, it will be used as the key. Otherwise, the client IP is used.

  You can also provide a custom key function:

      message_rate_limit: [
        backend: MyApp.RateLimiter,
        limit: 50,
        key_func: fn conn ->
          "msg:custom:" <> get_custom_key(conn)
        end
      ]

  ## Without message rate limiting

  Simply omit the `:message_rate_limit` option from your transport config.
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
            "ConduitMcp.Plugs.MessageRateLimit requires a :backend option (a module with hit/3)"
    end

    %{
      enabled: enabled,
      backend: backend,
      scale: Keyword.get(opts, :scale, 300_000),
      limit: Keyword.get(opts, :limit, 50),
      key_func: Keyword.get(opts, :key_func, &default_key_func/1),
      excluded_methods: Keyword.get(opts, :excluded_methods, [])
    }
  end

  @impl true
  def call(conn, %{enabled: false}) do
    conn
  end

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
  end

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn
  end

  def call(conn, opts) do
    body_params = conn.body_params

    cond do
      not is_map(body_params) or match?(%Plug.Conn.Unfetched{}, body_params) ->
        conn

      notification?(body_params) ->
        conn

      excluded?(body_params["method"], opts.excluded_methods) ->
        conn

      true ->
        check_rate_limit(conn, opts, body_params)
    end
  end

  defp check_rate_limit(
         conn,
         %{backend: backend, scale: scale, limit: limit, key_func: key_func},
         body_params
       ) do
    key = key_func.(conn)
    method = body_params["method"]
    start_time = System.monotonic_time()

    case backend.hit(key, scale, limit) do
      {:allow, count} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:conduit_mcp, :message_rate_limit, :check],
          %{duration: duration},
          %{key: key, status: :allow, count: count, method: method}
        )

        conn

      {:deny, ms_until_next} ->
        duration = System.monotonic_time() - start_time
        retry_after = max(div(ms_until_next, 1000), 1)

        :telemetry.execute(
          [:conduit_mcp, :message_rate_limit, :check],
          %{duration: duration},
          %{key: key, status: :deny, retry_after: retry_after, method: method}
        )

        Logger.warning("Message rate limit exceeded for key=#{key} method=#{method}")

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", to_string(retry_after))
        |> send_resp(
          429,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{
              "code" => ConduitMcp.Errors.server_error(),
              "message" => "Message rate limit exceeded"
            }
          })
        )
        |> halt()
    end
  end

  defp notification?(body_params) do
    is_map(body_params) and Map.has_key?(body_params, "method") and
      not Map.has_key?(body_params, "id")
  end

  defp excluded?(nil, _excluded_methods), do: false

  defp excluded?(method, excluded_methods) do
    method in excluded_methods
  end

  defp default_key_func(conn) do
    base =
      case conn.assigns[:current_user] do
        %{id: id} -> "user:#{id}"
        user when is_binary(user) -> "user:#{user}"
        _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end

    "msg:" <> base
  end
end

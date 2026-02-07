defmodule ConduitMcp.RateLimiter do
  @moduledoc """
  Rate limiter for ConduitMCP using Hammer.

  Uses `Hammer` with configurable backend and algorithm.

  ## Configuration

  Configure the backend and algorithm in your application config:

      # ETS with fixed window (default)
      config :conduit_mcp, :rate_limit,
        backend: :ets,
        algorithm: :fix_window,
        backend_opts: [clean_period: :timer.minutes(1)]

      # ETS with token bucket
      config :conduit_mcp, :rate_limit,
        backend: :ets,
        algorithm: :token_bucket,
        backend_opts: [clean_period: :timer.minutes(1)]

      # Atomic for single-node high-performance
      config :conduit_mcp, :rate_limit,
        backend: :atomic,
        algorithm: :fix_window,
        backend_opts: [clean_period: :timer.minutes(1)]

  ### Backends

  | Backend | Description |
  |---------|-------------|
  | `:ets` (default) | ETS-based, distributed-friendly |
  | `:atomic` | Erlang atomics, single-node, fastest |

  ### Algorithms

  | Algorithm | Description |
  |-----------|-------------|
  | `:fix_window` (default) | Fixed time windows |
  | `:sliding_window` | Sliding window (ETS only) |
  | `:token_bucket` | Token bucket, burst-tolerant |
  | `:leaky_bucket` | Leaky bucket, smooth rate |
  """

  use Hammer, backend: :ets

  @doc false
  def start_opts do
    config = Application.get_env(:conduit_mcp, :rate_limit, [])
    Keyword.get(config, :backend_opts, clean_period: :timer.minutes(1))
  end

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [start_opts()]},
      type: :worker,
      restart: :permanent
    }
  end
end

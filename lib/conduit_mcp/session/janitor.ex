defmodule ConduitMcp.Session.Janitor do
  @moduledoc """
  Periodically prunes expired sessions from a `ConduitMcp.Session.Store`.

  ETS-backed stores accumulate session entries indefinitely without an
  explicit eviction loop. Without a janitor, every successful `initialize`
  request adds a row to the session table that lives until the BEAM restarts;
  for a public-facing MCP server this is an unbounded memory growth surface.

  Stores backed by systems with native TTL (Redis with `EX`, Mnesia with TTL
  indices, etc.) do not need this janitor.

  ## Usage

  Add the janitor to your application supervision tree:

      children = [
        {ConduitMcp.Session.Janitor,
         store: ConduitMcp.Session.EtsStore,
         ttl: :timer.minutes(30),
         interval: :timer.minutes(1)},
        # ...
      ]

  ## Options

  - `:store` (required) - module implementing `ConduitMcp.Session.Store`
    that defines a `cleanup/1` callback.
  - `:ttl` - maximum session age in milliseconds (default: 30 minutes).
    Sessions whose `created_at` exceeds this age are evicted.
  - `:interval` - interval between cleanup runs in milliseconds
    (default: 1 minute).
  - `:name` - registered process name (default: module name).
  - `:telemetry_event` - event emitted after each run (default
    `[:conduit_mcp, :session, :cleanup]`), with measurements
    `%{removed: count}` and metadata `%{store: store}`.
  - `:noun` - what the swept rows are called in the debug log
    (default `"expired sessions"`).

  The last two exist because `ConduitMcp.Application` reuses this janitor for
  the cancellation table. Without them a consumer's
  `[:conduit_mcp, :session, :cleanup]` handler would receive cancellation
  evictions as session evictions once a minute, and the same count would be
  published under two event names - one of them wrong.
  """

  use GenServer

  require Logger

  @default_ttl :timer.minutes(30)
  @default_interval :timer.minutes(1)
  @default_event [:conduit_mcp, :session, :cleanup]
  @default_noun "expired sessions"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)

    # `function_exported?/3` is false for a module that is merely not loaded
    # yet, which under interactive code loading (dev, test, `mix run`, any
    # release not built with `:embedded`) is the normal state at boot. Without
    # the `ensure_loaded?` the janitor would warn spuriously and then skip the
    # sweep on every tick for the life of the node, leaving the table it was
    # added to bound growing unbounded.
    unless cleanup_exported?(store) do
      Logger.warning(
        "ConduitMcp.Session.Janitor: store #{inspect(store)} does not implement " <>
          "cleanup/1; janitor will idle. Remove this child from your supervision " <>
          "tree or use a store that supports cleanup."
      )
    end

    state = %{
      store: store,
      ttl: Keyword.get(opts, :ttl, @default_ttl),
      interval: Keyword.get(opts, :interval, @default_interval),
      event: Keyword.get(opts, :telemetry_event, @default_event),
      noun: Keyword.get(opts, :noun, @default_noun)
    }

    schedule_cleanup(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    %{store: store, ttl: ttl, event: event, noun: noun} = state

    if cleanup_exported?(store) do
      removed = store.cleanup(ttl)
      count = if is_integer(removed), do: removed, else: 0

      :telemetry.execute(event, %{removed: count}, %{store: store})

      if count > 0 do
        Logger.debug("session janitor removed #{count} #{noun}", store: inspect(store))
      end
    end

    schedule_cleanup(state.interval)
    {:noreply, state}
  end

  defp cleanup_exported?(store) do
    Code.ensure_loaded?(store) and function_exported?(store, :cleanup, 1)
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end

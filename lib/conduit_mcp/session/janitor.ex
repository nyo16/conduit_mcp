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

  - `:store` (required) — module implementing `ConduitMcp.Session.Store`
    that defines a `cleanup/1` callback.
  - `:ttl` — maximum session age in milliseconds (default: 30 minutes).
    Sessions whose `created_at` exceeds this age are evicted.
  - `:interval` — interval between cleanup runs in milliseconds
    (default: 1 minute).
  - `:name` — registered process name (default: module name).

  Emits `[:conduit_mcp, :session, :cleanup]` telemetry on each run with
  metadata `%{store: store, removed: count}`.
  """

  use GenServer

  require Logger

  @default_ttl :timer.minutes(30)
  @default_interval :timer.minutes(1)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    interval = Keyword.get(opts, :interval, @default_interval)

    unless function_exported?(store, :cleanup, 1) do
      Logger.warning(
        "ConduitMcp.Session.Janitor: store #{inspect(store)} does not implement " <>
          "cleanup/1; janitor will idle. Remove this child from your supervision " <>
          "tree or use a store that supports cleanup."
      )
    end

    schedule_cleanup(interval)
    {:ok, %{store: store, ttl: ttl, interval: interval}}
  end

  @impl true
  def handle_info(:cleanup, %{store: store, ttl: ttl, interval: interval} = state) do
    if function_exported?(store, :cleanup, 1) do
      removed = store.cleanup(ttl)
      count = if is_integer(removed), do: removed, else: 0

      :telemetry.execute(
        [:conduit_mcp, :session, :cleanup],
        %{removed: count},
        %{store: store}
      )

      if count > 0 do
        Logger.debug("session janitor removed #{count} expired sessions",
          store: inspect(store)
        )
      end
    end

    schedule_cleanup(interval)
    {:noreply, state}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end

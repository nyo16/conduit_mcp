defmodule ConduitMcp.Tasks.Janitor do
  @moduledoc """
  Periodically prunes terminal-state tasks from `ConduitMcp.Tasks`.

  `ConduitMcp.Tasks` stores task state in a named ETS table (`:conduit_mcp_tasks`)
  that has no eviction loop of its own. The janitor wakes on an interval and
  calls `ConduitMcp.Tasks.cleanup/1` to drop terminal-state entries older
  than the configured TTL.

  `ConduitMcp.Application` already starts one with this module's defaults
  (registered as `ConduitMcp.Tasks.Janitor.Default`; configure or disable it
  with `config :conduit_mcp, :tasks_janitor`). Start this module yourself
  only for a second sweep with other settings. Both sweep the same tasks, so
  the shortest `ttl` wins: to keep terminal tasks longer than one hour, set
  `config :conduit_mcp, :tasks_janitor, ttl: ...` (or `false`); a longer
  `ttl` here alone changes nothing.

  Tasks still in `working` or `input_required` are never evicted by the janitor
  regardless of age — long-running tasks remain available.

  ## Usage

      children = [
        {ConduitMcp.Tasks.Janitor,
         ttl: :timer.hours(1),
         interval: :timer.minutes(5)}
      ]

  ## Options

  - `:ttl` — maximum age in milliseconds for terminal-state tasks
    (default: 1 hour).
  - `:interval` — interval between cleanup runs in milliseconds
    (default: 5 minutes).
  - `:name` — registered process name (default: module name).

  Emits `[:conduit_mcp, :tasks, :cleanup]` telemetry on each run with
  measurements `%{removed: count}` and metadata `%{store: ConduitMcp.Tasks}`.
  """

  use GenServer

  require Logger

  @default_ttl :timer.hours(1)
  @default_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_cleanup(interval)
    {:ok, %{ttl: ttl, interval: interval}}
  end

  @impl true
  def handle_info(:cleanup, %{ttl: ttl, interval: interval} = state) do
    removed = ConduitMcp.Tasks.cleanup(ttl)

    :telemetry.execute(
      [:conduit_mcp, :tasks, :cleanup],
      %{removed: removed},
      %{store: ConduitMcp.Tasks}
    )

    if removed > 0 do
      Logger.debug("tasks janitor removed #{removed} terminal tasks")
    end

    schedule_cleanup(interval)
    {:noreply, state}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end

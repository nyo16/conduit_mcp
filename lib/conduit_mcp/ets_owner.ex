defmodule ConduitMcp.EtsOwner do
  @moduledoc """
  Shared implementation for ConduitMCP's supervised ETS table owners.

  Five subsystems keep state in a `:public`, `:named_table` ETS table that must
  outlive the short-lived Bandit request process that happens to touch it
  first: `ConduitMcp.Session.EtsStore`, `ConduitMcp.Tasks.EtsStore`,
  `ConduitMcp.Cancellation`, `ConduitMcp.Transport.SSE`'s connection counter,
  and `ConduitMcp.OAuth.KeyProvider.JWKS`'s cache. Each has an `Owner` process
  started by `ConduitMcp.Application` whose only job is to create the table and
  then idle, so the table's lifetime is the application's.

  The process holds no state beyond what it needs to re-claim, and answers no
  calls - reads and writes go directly to the `:public` table from the calling
  process. Do not turn any of them into a `handle_call` gateway.

  ## Why the create is not guarded

  `init/1` calls `:ets.new/2` unconditionally. At boot the table does not exist
  and owning it is the entire point; a `:ets.whereis` guard would let an
  earlier `ensure_table/0` keep the table under a short-lived process while the
  Owner stays alive owning nothing, silently defeating the guarantee.

  ## Why losing the race must not raise

  `:ets.new/2` raises `ArgumentError` when the name is already taken. That can
  happen legitimately: if an Owner exits, its table is destroyed, and any
  process calling `ensure_table/0` before the supervisor's restart completes
  becomes the new owner. The most likely racer is long-lived - a janitor tick
  calls `cleanup/1`, which starts with `ensure_table/0` - so the Owner would
  raise on every restart. Three restarts in five seconds take down
  `ConduitMcp.Supervisor`, and with it the consumer's application, over a
  cosmetic ownership question.

  So a lost race logs and retries every #{1_000}ms instead. The retry matters:
  the racer is usually a request or janitor process that exits within seconds,
  freeing the name - a one-shot degrade would idle forever owning nothing while
  the table's lifetime silently became one request's.

  ## Why only *that* ArgumentError is tolerated

  `:ets.new/2` raises the same exception for invalid options, and the exception
  carries no discriminator. Reporting a typo (`:naned_table`) as an ownership
  race would send the operator chasing a race that never happened - in the one
  module whose purpose is to make table ownership diagnosable. `init/1`
  therefore re-raises unless the name really is taken.
  """

  use GenServer

  require Logger

  # `:ets.new/2` options are a mixed list: bare atoms (`:named_table`,
  # `:public`, `:set`) alongside tuples (`{:read_concurrency, true}`). Not
  # `keyword()`, which would make every call site unreachable to dialyzer.
  @type table_opts :: [atom() | tuple()]

  @reclaim_interval 1_000

  @doc """
  Starts a process named `owner` that creates and then owns `table`.
  """
  @spec start_link(module(), atom(), table_opts()) :: GenServer.on_start()
  def start_link(owner, table, table_opts) do
    GenServer.start_link(__MODULE__, {owner, table, table_opts}, name: owner)
  end

  @impl true
  def init({owner, table, table_opts}) do
    state = %{owner: owner, table: table, table_opts: table_opts}

    case claim(state) do
      :ok ->
        {:ok, state}

      :taken ->
        Logger.warning(
          "#{inspect(owner)} could not claim #{inspect(table)}: the name is already " <>
            "taken, so the table belongs to another process and will not survive it. " <>
            "This happens when something called ensure_table/0 between the owner's " <>
            "exit and its supervised restart. Retrying every #{@reclaim_interval}ms."
        )

        Process.send_after(self(), :reclaim, @reclaim_interval)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:reclaim, state) do
    case claim(state) do
      :ok ->
        Logger.info("#{inspect(state.owner)} reclaimed #{inspect(state.table)}")
        {:noreply, state}

      :taken ->
        Process.send_after(self(), :reclaim, @reclaim_interval)
        {:noreply, state}
    end
  end

  @spec claim(map()) :: :ok | :taken
  defp claim(%{table: table, table_opts: table_opts}) do
    :ets.new(table, table_opts)
    :ok
  rescue
    error in ArgumentError ->
      # The name being taken is the only survivable cause; invalid options
      # raise the identical exception, so distinguish them by whether the table
      # actually exists. See "Why only *that* ArgumentError is tolerated".
      if :ets.whereis(table) == :undefined do
        reraise error, __STACKTRACE__
      end

      :taken
  end
end

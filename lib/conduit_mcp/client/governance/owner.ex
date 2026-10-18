defmodule ConduitMcp.Client.Governance.Owner do
  @moduledoc false
  # Owns a client's governance table (`ConduitMcp.Client.Governance`): a
  # child of the client supervisor, started before the connection.
  #
  # The table is `:protected`, a documented exception to the repo's
  # `ConduitMcp.EtsOwner` (`:public`, create-and-idle) convention: grants are
  # authorization state, so no other process may write them, and built
  # schemas decide what validation accepts. Callers read the table directly;
  # writes go through this process with `GenServer.call/2`. That is
  # acceptable here (it is not a read gateway): writes are rare (an
  # "always allow" answer, the first listing, the first use of a schema) and
  # must be serialized, and the process never runs host code.

  use GenServer

  alias ConduitMcp.Client.{Config, Registry}

  @max_schemas 4_096

  @doc false
  def child_spec(%Config{} = config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}}
  end

  @doc false
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config),
    do: GenServer.start_link(__MODULE__, config, name: Registry.via({:governance, config.name}))

  @doc """
  Sends a write to the owner and waits for it. A write that cannot be made
  because the client is stopping is dropped (`:ok`): every write is an
  optimisation or a record of something already decided.
  """
  @spec write(pid(), term()) :: :ok
  def write(owner, op) do
    GenServer.call(owner, op)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(%Config{} = config) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

    :ok =
      Registry.put_value({:governance, config.name}, %{
        table: table,
        settings: config.governance
      })

    {:ok, %{table: table, schemas: 0}}
  end

  @impl GenServer
  def handle_call(
        {:put_grant, {principal, server_id, tool, fingerprint}, expires_at, now},
        _from,
        state
      ) do
    # Expired grants are swept on every write, so the table stays bounded by
    # the grants live at once.
    :ets.select_delete(state.table, [
      {{{:grant, :_, :_, :_, :_}, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])

    :ets.insert(state.table, {{:grant, principal, server_id, tool, fingerprint}, expires_at})
    {:reply, :ok, state}
  end

  def handle_call({:revoke, principal}, _from, state) do
    :ets.match_delete(state.table, {{:grant, principal, :_, :_, :_}, :_})
    {:reply, :ok, state}
  end

  def handle_call(:clear_grants, _from, state) do
    :ets.match_delete(state.table, {{:grant, :_, :_, :_, :_}, :_})
    {:reply, :ok, state}
  end

  def handle_call({:put_baseline, baseline}, _from, state) do
    if :ets.insert_new(state.table, {:baseline}) do
      :ets.insert(
        state.table,
        for({server_id, tool, fp} <- baseline, do: {{:baseline, server_id, tool}, fp})
      )
    end

    {:reply, :ok, state}
  end

  def handle_call({:put_schema, key, built}, _from, state) do
    state =
      if state.schemas >= @max_schemas do
        :ets.match_delete(state.table, {{:schema, :_, :_, :_}, :_})
        %{state | schemas: 0}
      else
        state
      end

    if :ets.insert_new(state.table, {key, built}),
      do: {:reply, :ok, %{state | schemas: state.schemas + 1}},
      else: {:reply, :ok, state}
  end
end

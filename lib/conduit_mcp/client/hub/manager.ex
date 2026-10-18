defmodule ConduitMcp.Client.Hub.Manager do
  @moduledoc false
  # Starts, watches and restarts a hub's servers. Each server is a
  # `ConduitMcp.Client` started `restart: :temporary` under the hub's
  # DynamicSupervisor, so a crash-looping server never consumes that
  # supervisor's restart intensity: this process monitors it and starts it
  # again after `restart_backoff.(attempt)` (jittered, 1 s doubling to at
  # most 30 s by default; ST-8), which is the per-server circuit breaker. A
  # client gives up by itself after 3 restarts of its children in 5 s
  # (its `:one_for_all` supervisor's intensity), and is then started again
  # here. It is never on the request path and never runs hooks or
  # approvers.
  #
  # State lives in the hub table (`ConduitMcp.Client.Hub.Table`), which the
  # hub supervisor created, so it survives a restart of this process: on
  # init it re-monitors the servers that are still running and starts the
  # others. Only this process writes the server rows.

  use GenServer

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Hub.{Config, Table}
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Telemetry

  # A server that ran this long before failing starts its backoff over.
  @stable_ms 60_000

  @doc false
  @spec start_link({Config.t(), :ets.tid()}) :: GenServer.on_start()
  def start_link({%Config{} = config, table}),
    do: GenServer.start_link(__MODULE__, {config, table}, name: via(config.name))

  @doc false
  @spec via(term()) :: GenServer.name()
  def via(hub), do: Registry.via({:hub_manager, hub})

  @impl GenServer
  def init({config, table}) do
    if :ets.insert_new(table, {:initialized, true}) do
      config.servers
      |> Enum.with_index()
      |> Enum.each(fn {{id, client_config}, order} ->
        Table.put_server(table, new_row(id, order, client_config, true))
      end)

      :ets.insert(table, {:next_order, length(config.servers)})
    end

    state = %{
      hub: config.name,
      config: config,
      table: table,
      dynsup: Registry.via({:hub_servers, config.name}),
      backoff: config.restart_backoff,
      monitors: %{},
      timers: %{}
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl GenServer
  def handle_continue(:reconcile, state) do
    state =
      Enum.reduce(Table.servers(state.table), state, fn row, state ->
        case Registry.lookup({:supervisor, row.config.name}) do
          {:ok, pid, _value} -> running(state, row, pid, false)
          :error -> start(state, row)
        end
      end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:add, id, client_config}, _from, state) do
    cond do
      match?({:ok, _row}, Table.server(state.table, id)) ->
        {:reply, :ok, state}

      # ST-8: the cap counts every server the hub holds, running or not.
      Config.stdio?(client_config) and
          not Config.within_stdio_cap?(state.config, stdio_count(state) + 1) ->
        {:reply, {:error, Client.Error.new(:overloaded, :max_stdio_servers)}, state}

      true ->
        order = :ets.update_counter(state.table, :next_order, 1) - 1
        row = new_row(id, order, client_config, false)
        Table.put_server(state.table, row)
        {:reply, :ok, start(state, row)}
    end
  end

  def handle_call({:remove, id}, _from, state) do
    case Table.server(state.table, id) do
      {:ok, row} ->
        state = forget(state, id)
        if is_pid(row.pid), do: DynamicSupervisor.terminate_child(state.dynsup, row.pid)
        Table.delete_server(state.table, id)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, Client.Error.new(:not_found, :unknown_server)}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.monitors, fn {_id, monitor} -> monitor == ref end) do
      {id, _ref} ->
        state = %{state | monitors: Map.delete(state.monitors, id)}
        {:noreply, with_row(state, id, &failed(state, &1, reason))}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:restart, id, token}, state) do
    case Map.fetch(state.timers, id) do
      {:ok, {_timer, ^token}} ->
        state = %{state | timers: Map.delete(state.timers, id)}
        {:noreply, with_row(state, id, &start(state, &1))}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- helpers -------------------------------------------------------------------------

  defp new_row(id, order, client_config, static?) do
    %{
      id: id,
      order: order,
      config: client_config,
      static?: static?,
      state: :starting,
      pid: nil,
      attempts: 0,
      reason: nil,
      since: now()
    }
  end

  defp with_row(state, id, fun) do
    case Table.server(state.table, id) do
      {:ok, row} -> fun.(row)
      :error -> state
    end
  end

  defp stdio_count(state),
    do: Enum.count(Table.servers(state.table), &Config.stdio?(&1.config))

  defp start(state, row) do
    spec = %{
      id: row.config.name,
      start: {Client, :start_link, [row.config]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(state.dynsup, spec) do
      {:ok, pid} -> running(state, row, pid, row.attempts > 0)
      {:error, {:already_started, pid}} -> running(state, row, pid, false)
      {:error, reason} -> failed(state, row, reason)
    end
  end

  defp running(state, row, pid, restarted?) do
    monitor = Process.monitor(pid)
    Table.put_server(state.table, %{row | state: :running, pid: pid, reason: nil, since: now()})
    if restarted?, do: Telemetry.hub_server_restarted(state.hub, row.id, row.attempts)
    %{state | monitors: Map.put(state.monitors, row.id, monitor)}
  end

  defp failed(state, row, reason) do
    attempts =
      if row.state == :running and now() - row.since >= @stable_ms,
        do: 1,
        else: row.attempts + 1

    delay = state.backoff.(attempts)
    token = make_ref()
    timer = Process.send_after(self(), {:restart, row.id, token}, delay)

    Table.put_server(state.table, %{
      row
      | state: :failed,
        pid: nil,
        attempts: attempts,
        reason: Telemetry.reason_tag(reason),
        since: now()
    })

    Telemetry.hub_server_failed(state.hub, row.id, attempts, reason, delay)
    %{state | timers: Map.put(state.timers, row.id, {timer, token})}
  end

  defp forget(state, id) do
    {monitor, monitors} = Map.pop(state.monitors, id)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {timer, timers} = Map.pop(state.timers, id)
    if timer, do: Process.cancel_timer(elem(timer, 0))
    %{state | monitors: monitors, timers: timers}
  end

  defp now, do: System.monotonic_time(:millisecond)
end

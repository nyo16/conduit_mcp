defmodule ConduitMcp.Subscriptions.Admission do
  @moduledoc """
  The node-local bookkeeping behind `:max_listens_per_principal`: which
  `subscriptions/listen` streams of each principal are live, oldest first.
  Started by `ConduitMcp.Application`; streams reach it through
  `ConduitMcp.Subscriptions` (`admit/3`, `leave/2`, `live_listeners/1`).

  A stream is admitted with one `GenServer.call/2`. In that one message the
  process counts the principal's live streams, supersedes the oldest beyond
  the cap - removing them from the live set at once, so they are never
  counted or evicted twice, and sending each
  `{ConduitMcp.Subscriptions, ref, :superseded}` with its own ref - and
  records the caller. Admissions are answered in arrival order, so even a
  burst of concurrent listens of one principal never holds more than the cap
  live (SV-10). A stream that ends removes its entry (`leave/1`, a cast:
  under HTTP/1.1 keep-alive the same process goes on to serve the
  connection's next request, and its next admission queues behind it); a
  stream that dies is dropped on its monitor's `:DOWN`.

  ## Why a process you call

  The library's ETS owners create a table and idle, and must not become
  `handle_call` gateways: their tables are read and written on every
  request, so a single process in front of them would serialize the whole
  server. Admission is the opposite case. It happens once per listen opened,
  not per message; it needs count, evict and record to be one atomic step
  per principal; and the state is small (at most the cap per principal).
  The alternative - a lock around ETS updates, such as `:global.trans/3` -
  retries contended acquisitions with random sleeps of up to seconds, so a
  burst of listens of one principal waited seconds for what this process
  does in microseconds, with no lock and no backoff. The process runs no
  user code: each request is a few map updates and message sends.
  """

  use GenServer

  @typedoc "A live stream: admission order, process, and the ref its messages carry."
  @type listener :: {non_neg_integer(), pid(), reference()}

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Admits the calling process as a stream of `principal_key` tagged `ref`,
  superseding the principal's oldest live streams so that at most `max`
  are live, this one included.
  """
  @spec admit(String.t(), pos_integer(), reference()) :: :ok
  def admit(principal_key, max, ref) when is_integer(max) and max > 0,
    do: GenServer.call(__MODULE__, {:admit, principal_key, max, ref})

  @doc """
  Removes the calling process's streams of `principal_key`. A no-op for a
  process that holds none, or when the admission process is not running.
  """
  @spec leave(String.t()) :: :ok
  def leave(principal_key), do: GenServer.cast(__MODULE__, {:leave, self(), principal_key})

  @doc """
  The live (not superseded) streams of `principal_key`, oldest first.
  """
  @spec live_listeners(String.t()) :: [listener()]
  def live_listeners(principal_key),
    do: GenServer.call(__MODULE__, {:live_listeners, principal_key})

  # --- server -------------------------------------------------------------------

  # `live`: principal key => its live streams, oldest first (at most the cap).
  # `pids`: each admitted process => {its monitor, the principal keys it was
  # admitted under}. A superseded stream stays in `pids` until it leaves or
  # dies; it is only out of `live`.
  @impl true
  def init([]), do: {:ok, %{live: %{}, pids: %{}, seq: 0}}

  @impl true
  def handle_call({:admit, key, max, ref}, {pid, _tag}, state) do
    listeners = Map.get(state.live, key, [])
    {victims, kept} = Enum.split(listeners, max(length(listeners) - max + 1, 0))

    for {_seq, victim, victim_ref} <- victims,
        do: send(victim, {ConduitMcp.Subscriptions, victim_ref, :superseded})

    state = %{
      state
      | live: Map.put(state.live, key, kept ++ [{state.seq, pid, ref}]),
        pids: track(state.pids, pid, key),
        seq: state.seq + 1
    }

    {:reply, :ok, state}
  end

  def handle_call({:live_listeners, key}, _from, state),
    do: {:reply, Map.get(state.live, key, []), state}

  @impl true
  def handle_cast({:leave, pid, key}, state) do
    case state.pids do
      %{^pid => {monitor, keys}} ->
        state = drop_live(state, pid, [key])
        keys = MapSet.delete(keys, key)

        if MapSet.size(keys) == 0 do
          Process.demonitor(monitor, [:flush])
          {:noreply, %{state | pids: Map.delete(state.pids, pid)}}
        else
          {:noreply, %{state | pids: Map.put(state.pids, pid, {monitor, keys})}}
        end

      %{} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {{_monitor, keys}, pids} = Map.pop(state.pids, pid)
    {:noreply, drop_live(%{state | pids: pids}, pid, keys)}
  end

  defp track(pids, pid, key) do
    case pids do
      %{^pid => {monitor, keys}} -> Map.put(pids, pid, {monitor, MapSet.put(keys, key)})
      %{} -> Map.put(pids, pid, {Process.monitor(pid), MapSet.new([key])})
    end
  end

  defp drop_live(state, pid, keys) do
    live =
      Enum.reduce(keys, state.live, fn key, live ->
        case Enum.reject(Map.get(live, key, []), &match?({_seq, ^pid, _ref}, &1)) do
          [] -> Map.delete(live, key)
          listeners -> Map.put(live, key, listeners)
        end
      end)

    %{state | live: live}
  end
end

defmodule ConduitMcp.Client.Hub.Table do
  @moduledoc false
  # The hub's ETS table (`:set`, `:public`, `read_concurrency: true`). The
  # hub supervisor creates it in `init/1` and then only idles, like a
  # `ConduitMcp.EtsOwner`, so the table outlives a restart of the manager and
  # dies with the hub. Callers read and write it directly; nothing is a
  # `handle_call` gateway.
  #
  # Rows:
  #
  #   {:initialized, true}                - the static servers were recorded
  #   {:next_order, n}                    - the order the next added server gets
  #   {{:server, id}, row}                - one server (the manager writes these)
  #   {{:fetch, id}, cache, last_ms, failures} - hub-triggered tool-list fetches (callers)
  #   {{:naming, hash}, key, pairs, report} - memoized exposed names (callers)
  #
  # A server row is `%{id, order, config, static?, state, pid, attempts,
  # reason, since}` with `state` one of `:starting`, `:running` (its client
  # process is up; see the connection state for more) and `:failed`
  # (waiting `restart_backoff` before the next start).

  # Memoized namings kept before the memo is cleared (distinct tool lists,
  # e.g. one per filter function outcome).
  @max_namings 64

  @spec new() :: :ets.tid()
  def new, do: :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

  @spec put_server(:ets.tid(), map()) :: true
  def put_server(table, %{id: id} = row), do: :ets.insert(table, {{:server, id}, row})

  @spec delete_server(:ets.tid(), String.t()) :: true
  def delete_server(table, id) do
    :ets.delete(table, {:fetch, id})
    :ets.delete(table, {:server, id})
  end

  @spec server(:ets.tid(), String.t()) :: {:ok, map()} | :error
  def server(table, id) do
    case :ets.lookup(table, {:server, id}) do
      [{_key, row}] -> {:ok, row}
      [] -> :error
    end
  end

  @doc "Every server row, in hub order."
  @spec servers(:ets.tid()) :: [map()]
  def servers(table) do
    table
    |> :ets.select([{{{:server, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.sort_by(& &1.order)
  end

  # --- fetch bookkeeping (HB-4) ------------------------------------------------------

  # Kept per connection incarnation (its cache table): a restarted client
  # starts with no fetch history, so its first listing is never held back.

  @doc "`{last_attempt_ms, consecutive_failures}` of hub-triggered fetches of `id` on `cache`."
  @spec fetch_state(:ets.tid(), String.t(), :ets.tid()) :: {integer() | nil, non_neg_integer()}
  def fetch_state(table, id, cache) do
    case :ets.lookup(table, {:fetch, id}) do
      [{_key, ^cache, last, failures}] -> {last, failures}
      _none_or_older -> {nil, 0}
    end
  end

  @spec fetch_started(:ets.tid(), String.t(), :ets.tid(), integer()) :: true
  def fetch_started(table, id, cache, now) do
    {_last, failures} = fetch_state(table, id, cache)
    :ets.insert(table, {{:fetch, id}, cache, now, failures})
  end

  @spec fetch_finished(:ets.tid(), String.t(), :ok | :error) :: non_neg_integer()
  def fetch_finished(table, id, :ok) do
    :ets.update_element(table, {:fetch, id}, {4, 0})
    0
  end

  def fetch_finished(table, id, :error),
    do: :ets.update_counter(table, {:fetch, id}, {4, 1}, {{:fetch, id}, nil, 0, 0})

  # --- naming memo ---------------------------------------------------------------------

  @spec naming(:ets.tid(), term()) :: {:ok, list(), map()} | :error
  def naming(table, key) do
    case :ets.lookup(table, {:naming, :erlang.phash2(key)}) do
      [{_hash, ^key, pairs, report}] -> {:ok, pairs, report}
      _miss -> :error
    end
  end

  @spec put_naming(:ets.tid(), term(), list(), map()) :: true
  def put_naming(table, key, pairs, report) do
    if :ets.select_count(table, [{{{:naming, :_}, :_, :_, :_}, [], [true]}]) >= @max_namings,
      do: :ets.match_delete(table, {{:naming, :_}, :_, :_, :_})

    :ets.insert(table, {{:naming, :erlang.phash2(key)}, key, pairs, report})
  end
end

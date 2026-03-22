# Mnesia-backed session store for distributed Erlang clusters.
#
# No external dependencies — Mnesia is built into OTP.
# Sessions auto-replicate across all connected nodes.
#
# Setup (run once, in your application start):
#
#     MyApp.MnesiaSessionStore.setup_table([:node1@host, :node2@host, :node3@host])
#
# Configuration:
#
#     {ConduitMcp.Transport.StreamableHTTP,
#       server_module: MyServer,
#       session: [store: MyApp.MnesiaSessionStore]}
#
defmodule MyApp.MnesiaSessionStore do
  @behaviour ConduitMcp.Session.Store

  @table :mcp_sessions

  @doc """
  Creates the Mnesia table replicated across the given nodes.
  Call this once during application startup or deployment.

      # For a 3-node cluster
      MyApp.MnesiaSessionStore.setup_table([node() | Node.list()])
  """
  def setup_table(nodes \\ [node()]) do
    # Ensure Mnesia schema exists on all nodes
    case :mnesia.create_schema(nodes) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
    end

    # Start Mnesia on all nodes
    :rpc.multicall(nodes, :mnesia, :start, [])

    # Create the table with ram_copies on all nodes (fast, replicated)
    case :mnesia.create_table(@table,
           attributes: [:session_id, :metadata, :created_at],
           ram_copies: nodes,
           type: :set
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, @table}} -> :ok
    end

    # Wait for table to be available
    :mnesia.wait_for_tables([@table], 5000)
  end

  @impl true
  def create(session_id, metadata) do
    record = {
      @table,
      session_id,
      metadata,
      System.system_time(:millisecond)
    }

    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(session_id) do
    case :mnesia.transaction(fn -> :mnesia.read(@table, session_id) end) do
      {:atomic, [{@table, ^session_id, metadata, _created_at}]} ->
        {:ok, metadata}

      {:atomic, []} ->
        {:error, :not_found}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(session_id) do
    :mnesia.transaction(fn -> :mnesia.delete({@table, session_id}) end)
    :ok
  end

  @impl true
  def update(session_id, new_metadata) do
    :mnesia.transaction(fn ->
      case :mnesia.read(@table, session_id) do
        [{@table, ^session_id, existing, created_at}] ->
          merged = Map.merge(existing, new_metadata)
          :mnesia.write({@table, session_id, merged, created_at})

        [] ->
          :mnesia.abort(:not_found)
      end
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, :not_found} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Cleanup sessions older than `ttl_ms` milliseconds.

      MyApp.MnesiaSessionStore.cleanup(:timer.minutes(30))
  """
  def cleanup(ttl_ms) do
    cutoff = System.system_time(:millisecond) - ttl_ms

    :mnesia.transaction(fn ->
      :mnesia.foldl(
        fn {_table, session_id, _metadata, created_at}, acc ->
          if created_at < cutoff do
            :mnesia.delete({@table, session_id})
            acc + 1
          else
            acc
          end
        end,
        0,
        @table
      )
    end)
  end
end

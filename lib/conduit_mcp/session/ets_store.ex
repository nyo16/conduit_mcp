defmodule ConduitMcp.Session.EtsStore do
  @moduledoc """
  Default ETS-based session store. Zero-dependency, works out of the box.

  Sessions are stored in a named ETS table (`:conduit_mcp_sessions`).
  Each session stores the protocol version, creation timestamp, and arbitrary metadata.

  ## TTL Cleanup

  The ETS store supports optional TTL-based cleanup. When configured, expired sessions
  are removed periodically. Configure via the `:ttl` option (default: 30 minutes).

  ## Usage

      # In your transport config
      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        session: [store: ConduitMcp.Session.EtsStore, ttl: :timer.minutes(60)]}
  """

  @behaviour ConduitMcp.Session.Store

  @table :conduit_mcp_sessions

  @doc """
  Ensures the ETS table exists. Called automatically on first use.
  """
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @impl true
  def create(session_id, metadata) do
    ensure_table()

    entry =
      Map.merge(metadata, %{
        "created_at" => System.system_time(:millisecond)
      })

    :ets.insert(@table, {session_id, entry})
    :ok
  end

  @impl true
  def get(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, metadata}] -> {:ok, metadata}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  @impl true
  def update(session_id, new_metadata) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, existing}] ->
        :ets.insert(@table, {session_id, Map.merge(existing, new_metadata)})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Removes sessions older than `ttl_ms` milliseconds.
  """
  def cleanup(ttl_ms) do
    ensure_table()
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {session_id, metadata}, acc ->
        created_at = Map.get(metadata, "created_at", 0)

        if now - created_at > ttl_ms do
          :ets.delete(@table, session_id)
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end
end

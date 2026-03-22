defmodule ConduitMcp.Session.Store do
  @moduledoc """
  Behaviour for pluggable session storage backends.

  ConduitMCP uses sessions to track MCP protocol state per client connection.
  The default implementation uses ETS (`ConduitMcp.Session.EtsStore`), but you
  can implement this behaviour for any storage backend.

  ## Implementing a Custom Store

  ### Redis Example

      defmodule MyApp.RedisSessionStore do
        @behaviour ConduitMcp.Session.Store

        @impl true
        def create(session_id, metadata) do
          data = JSON.encode!(metadata)
          Redix.command(:redix, ["SET", key(session_id), data, "EX", "3600"])
          :ok
        end

        @impl true
        def get(session_id) do
          case Redix.command(:redix, ["GET", key(session_id)]) do
            {:ok, nil} -> {:error, :not_found}
            {:ok, data} -> {:ok, JSON.decode!(data)}
          end
        end

        @impl true
        def delete(session_id) do
          Redix.command(:redix, ["DEL", key(session_id)])
          :ok
        end

        @impl true
        def update(session_id, metadata) do
          case get(session_id) do
            {:ok, existing} ->
              create(session_id, Map.merge(existing, metadata))
            {:error, :not_found} ->
              {:error, :not_found}
          end
        end

        defp key(session_id), do: "mcp:session:\#{session_id}"
      end

  ### Mnesia Example (Distributed Erlang)

      defmodule MyApp.MnesiaSessionStore do
        @behaviour ConduitMcp.Session.Store
        # Uses Mnesia for distributed session replication across nodes
        # Ideal for clustered deployments
      end

  ## Configuration

      # Default (ETS, zero config)
      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        session: [store: ConduitMcp.Session.EtsStore]}

      # Custom store with TTL
      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        session: [store: MyApp.RedisSessionStore, ttl: :timer.minutes(60)]}

      # Disable sessions entirely
      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        session: false}
  """

  @doc """
  Creates a new session with the given ID and metadata.
  """
  @callback create(session_id :: String.t(), metadata :: map()) :: :ok | {:error, term()}

  @doc """
  Retrieves session metadata by ID.
  """
  @callback get(session_id :: String.t()) :: {:ok, map()} | {:error, :not_found}

  @doc """
  Deletes a session by ID.
  """
  @callback delete(session_id :: String.t()) :: :ok

  @doc """
  Updates an existing session's metadata (merges new metadata into existing).
  """
  @callback update(session_id :: String.t(), metadata :: map()) :: :ok | {:error, :not_found}
end

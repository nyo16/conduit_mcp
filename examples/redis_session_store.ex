# Redis-backed session store for multi-node MCP deployments.
#
# Requires: {:redix, "~> 1.5"} in your deps
#
# Configuration:
#
#     # In your application supervisor
#     children = [
#       {Redix, name: :redix, host: "redis-host", port: 6379}
#     ]
#
#     # In your transport config
#     {ConduitMcp.Transport.StreamableHTTP,
#       server_module: MyServer,
#       session: [
#         store: MyApp.RedisSessionStore,
#         ttl: :timer.minutes(30)
#       ]}
#
defmodule MyApp.RedisSessionStore do
  @behaviour ConduitMcp.Session.Store

  @prefix "mcp:session:"
  # 30 minutes in seconds
  @default_ttl 1800

  @impl true
  def create(session_id, metadata) do
    data = Jason.encode!(metadata)
    ttl = Map.get(metadata, "ttl", @default_ttl)

    case Redix.command(:redix, ["SET", key(session_id), data, "EX", to_string(ttl)]) do
      {:ok, "OK"} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(session_id) do
    case Redix.command(:redix, ["GET", key(session_id)]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, data} -> {:ok, Jason.decode!(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(session_id) do
    Redix.command(:redix, ["DEL", key(session_id)])
    :ok
  end

  @impl true
  def update(session_id, new_metadata) do
    case get(session_id) do
      {:ok, existing} ->
        merged = Map.merge(existing, new_metadata)
        create(session_id, merged)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp key(session_id), do: @prefix <> session_id
end

# Multi-Node Session Stores

By default, ConduitMCP uses ETS for session storage — fast but local to each node.
For multi-node deployments, implement the `ConduitMcp.Session.Store` behaviour
with a shared backend.

## Redis

```elixir
# Requires {:redix, "~> 1.5"}

defmodule MyApp.RedisSessionStore do
  @behaviour ConduitMcp.Session.Store

  @prefix "mcp:session:"
  @default_ttl 1800  # 30 minutes

  @impl true
  def create(session_id, metadata) do
    data = JSON.encode!(metadata)
    ttl = Map.get(metadata, "ttl", @default_ttl)
    {:ok, "OK"} = Redix.command(:redix, ["SET", key(session_id), data, "EX", to_string(ttl)])
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
  def update(session_id, new_metadata) do
    case get(session_id) do
      {:ok, existing} -> create(session_id, Map.merge(existing, new_metadata))
      error -> error
    end
  end

  defp key(session_id), do: @prefix <> session_id
end
```

Configuration:

```elixir
{ConduitMcp.Transport.StreamableHTTP,
  server_module: MyServer,
  session: [store: MyApp.RedisSessionStore]}
```

## PostgreSQL (Ecto)

```elixir
# Requires {:ecto_sql, "~> 3.0"} and {:postgrex, "~> 0.19"}

# Migration
defmodule MyApp.Repo.Migrations.CreateMcpSessions do
  use Ecto.Migration

  def change do
    create table(:mcp_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :protocol_version, :string
      add :metadata, :map, default: %{}
      timestamps()
    end
  end
end

# Schema
defmodule MyApp.McpSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "mcp_sessions" do
    field :protocol_version, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:id, :protocol_version, :metadata])
    |> validate_required([:id])
  end
end

# Store
defmodule MyApp.PostgresSessionStore do
  @behaviour ConduitMcp.Session.Store
  @repo MyApp.Repo

  @impl true
  def create(session_id, metadata) do
    attrs = %{id: session_id, protocol_version: metadata["protocol_version"], metadata: metadata}
    {:ok, _} = @repo.insert(MyApp.McpSession.changeset(%MyApp.McpSession{}, attrs))
    :ok
  end

  @impl true
  def get(session_id) do
    case @repo.get(MyApp.McpSession, session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, session.metadata}
    end
  end

  @impl true
  def delete(session_id) do
    if session = @repo.get(MyApp.McpSession, session_id), do: @repo.delete(session)
    :ok
  end

  @impl true
  def update(session_id, new_metadata) do
    case @repo.get(MyApp.McpSession, session_id) do
      nil -> {:error, :not_found}
      session ->
        merged = Map.merge(session.metadata, new_metadata)
        {:ok, _} = @repo.update(MyApp.McpSession.changeset(session, %{metadata: merged}))
        :ok
    end
  end
end
```

## Mnesia (Distributed Erlang)

Zero external dependencies — Mnesia replicates across all connected nodes automatically.

```elixir
defmodule MyApp.MnesiaSessionStore do
  @behaviour ConduitMcp.Session.Store
  @table :mcp_sessions

  def setup_table(nodes \\ [node()]) do
    :mnesia.create_schema(nodes)
    :rpc.multicall(nodes, :mnesia, :start, [])
    :mnesia.create_table(@table,
      attributes: [:session_id, :metadata, :created_at],
      ram_copies: nodes,
      type: :set
    )
    :mnesia.wait_for_tables([@table], 5000)
  end

  @impl true
  def create(session_id, metadata) do
    {:atomic, :ok} = :mnesia.transaction(fn ->
      :mnesia.write({@table, session_id, metadata, System.system_time(:millisecond)})
    end)
    :ok
  end

  @impl true
  def get(session_id) do
    case :mnesia.transaction(fn -> :mnesia.read(@table, session_id) end) do
      {:atomic, [{@table, ^session_id, metadata, _}]} -> {:ok, metadata}
      {:atomic, []} -> {:error, :not_found}
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
          :mnesia.write({@table, session_id, Map.merge(existing, new_metadata), created_at})
        [] ->
          :mnesia.abort(:not_found)
      end
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, :not_found} -> {:error, :not_found}
    end
  end
end
```

## Alternatives

- **Sticky sessions**: Configure your load balancer to route by `Mcp-Session-Id` header. ETS works fine.
- **Disable sessions**: Set `session: false` in transport config for fully stateless mode.

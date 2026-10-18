# Multi-Node Session Stores

> #### Legacy era only {: .info}
>
> Sessions belong to the legacy protocol era (`2025-11-25`, `2025-06-18`).
> Modern (`2026-07-28`) requests never create, require or look up a
> session. See [Multi-node on the modern era](#multi-node-on-the-modern-era)
> for how to run modern clients across nodes.

Sessions are off unless the transport is given a `:session` option. With
`session: []`, ConduitMCP stores sessions in ETS (`ConduitMcp.Session.EtsStore`)
— fast but local to each node. For multi-node deployments, implement the
`ConduitMcp.Session.Store` behaviour with a shared backend and pass it as
`session: [store: MyStore]`.

> **Pruning expired sessions.** Every successful `initialize` adds a session
> row. For `ConduitMcp.Session.EtsStore`, the `:conduit_mcp` application
> already runs a `ConduitMcp.Session.Janitor` (as
> `ConduitMcp.Session.Janitor.Default`, 30-minute TTL). Tune or disable it in
> config:
>
> ```elixir
> config :conduit_mcp, session_janitor: [ttl: :timer.hours(4)]
> config :conduit_mcp, session_janitor: false
> ```
>
> A custom ETS-backed store needs its own janitor in your supervision tree:
>
> ```elixir
> children = [
>   {ConduitMcp.Session.Janitor,
>    store: MyApp.MyEtsSessionStore,
>    ttl: :timer.minutes(30),
>    interval: :timer.minutes(1)}
> ]
> ```
>
> Backends with native TTL (Redis `EX`, etc.) do not need the janitor.

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
- **No sessions**: Omit `:session` (or set `session: false`) for fully stateless mode.

A session records the principal that created it (`ConduitMcp.Principal.id/1`).
A legacy request or `DELETE` that presents it from a different principal is
answered 404, exactly like an unknown session id, so a leaked id can't be
used, used to cancel the owner's requests, or used to end the session.

## Multi-node on the modern era

A modern request carries everything the server needs in its own `_meta`, so
any node can serve any modern request. There is nothing to replicate and
nothing to make sticky. `Mcp-Session-Id` is ignored, except that a modern
request may not present a live session bound to a different principal
(`-32600`, HTTP 400).

### State across tool calls: opaque handles

Without sessions, a server that needs to remember something between calls
hands the client a handle and takes it back as a tool argument. Mint the
handle server-side, make it unguessable, and bind it to the caller:

```elixir
tool "open_cart", "Start a shopping cart" do
  handle fn conn, _params ->
    cart = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ok = MyApp.Carts.create(cart, owner: ConduitMcp.Principal.id(conn))
    json(%{cart: cart})
  end
end

tool "add_item", "Add an item to a cart" do
  param :cart, :string, "Cart handle returned by open_cart", required: true
  param :sku, :string, "SKU", required: true

  handle fn conn, %{"cart" => cart, "sku" => sku} ->
    case MyApp.Carts.add(cart, ConduitMcp.Principal.id(conn), sku) do
      :ok -> text("Added #{sku}")
      {:error, :not_found} -> error("Unknown cart", ConduitMcp.Errors.invalid_params())
    end
  end
end
```

- **Shared storage.** Keep handle state in storage every node can read:
  the database, Redis, Mnesia. The backends above suit it.
- **Owner-scoped lookups.** Look handles up by owner as well as id
  (`ConduitMcp.Principal.id/1`), and answer a foreign handle exactly like an
  unknown one.
- **Expiry.** Give handles a TTL: nothing tells the server when a client is
  done.
- **The handle is a credential.** Keep it out of logs.

### What else to share

| Feature | Across nodes |
|---|---|
| [MRTR](mrtr.md) `requestState` | Travels with the client, so a retry can land on any node. Every node needs the same `:mrtr_keys`. |
| [Subscriptions](subscriptions.md) | Node-local. Broadcast changes on your own PubSub and call `ConduitMcp.notify_*` on every node (below). |
| [Tasks extension](tasks_extension.md) | `ConduitMcp.Ext.Tasks.EtsStore` is single-node. Configure a shared `ConduitMcp.Ext.Tasks.Store`. Status notifications are node-local too. |
| Streamed `tools/call` and cancellation | Stay on the node serving the request: closing the stream cancels the tool on that node. |

A `subscriptions/listen` stream only receives what is published on the node
serving it. Fan changes out with PubSub:

```elixir
# wherever the change happens
Phoenix.PubSub.broadcast(MyApp.PubSub, "mcp", :tools_changed)

# in a GenServer subscribed to "mcp" on every node
def handle_info(:tools_changed, state) do
  ConduitMcp.notify_tools_changed()
  {:noreply, state}
end
```

The full recipe, including `notify_resource_updated/1`, is in
[Subscriptions](subscriptions.md#multi-node).

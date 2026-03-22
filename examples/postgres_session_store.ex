# PostgreSQL-backed session store for multi-node MCP deployments.
#
# Requires: {:ecto_sql, "~> 3.0"} and {:postgrex, "~> 0.19"} in your deps
#
# Migration:
#
#     defmodule MyApp.Repo.Migrations.CreateMcpSessions do
#       use Ecto.Migration
#
#       def change do
#         create table(:mcp_sessions, primary_key: false) do
#           add :id, :string, primary_key: true
#           add :protocol_version, :string
#           add :metadata, :map, default: %{}
#           timestamps()
#         end
#
#         create index(:mcp_sessions, [:inserted_at])
#       end
#     end
#
# Configuration:
#
#     {ConduitMcp.Transport.StreamableHTTP,
#       server_module: MyServer,
#       session: [store: MyApp.PostgresSessionStore]}
#
defmodule MyApp.McpSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "mcp_sessions" do
    field(:protocol_version, :string)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:id, :protocol_version, :metadata])
    |> validate_required([:id])
  end
end

defmodule MyApp.PostgresSessionStore do
  @behaviour ConduitMcp.Session.Store

  import Ecto.Query

  # Set your repo module here
  @repo MyApp.Repo

  @impl true
  def create(session_id, metadata) do
    attrs = %{
      id: session_id,
      protocol_version: Map.get(metadata, "protocol_version"),
      metadata: metadata
    }

    case @repo.insert(MyApp.McpSession.changeset(%MyApp.McpSession{}, attrs)) do
      {:ok, _session} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
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
    case @repo.get(MyApp.McpSession, session_id) do
      nil -> :ok
      session -> @repo.delete(session)
    end

    :ok
  end

  @impl true
  def update(session_id, new_metadata) do
    case @repo.get(MyApp.McpSession, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        merged = Map.merge(session.metadata, new_metadata)
        changeset = MyApp.McpSession.changeset(session, %{metadata: merged})

        case @repo.update(changeset) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Cleanup expired sessions. Call from a periodic task or Oban job.

      MyApp.PostgresSessionStore.cleanup(:timer.minutes(30))
  """
  def cleanup(ttl_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_ms, :millisecond)

    from(s in MyApp.McpSession, where: s.inserted_at < ^cutoff)
    |> @repo.delete_all()
  end
end

defmodule Examples.ObanTasks.Migrator do
  @moduledoc """
  Runs migrations at boot — Oban's own schema plus a tiny `mcp_tasks`
  table for the task store. No `priv/repo/migrations` directory is
  needed; both migrations are defined inline here so the example is
  self-contained.

  Idempotent — safe to run on every boot.
  """

  use GenServer

  require Logger

  alias Examples.ObanTasks.Repo

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :migrate}}
  end

  @impl true
  def handle_continue(:migrate, state) do
    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, &run_migrations/1)
    Logger.info("ObanTasks: migrations up to date at #{Repo.config()[:database]}")
    {:noreply, state}
  end

  defp run_migrations(repo) do
    Ecto.Migrator.run(repo, migrations(), :up, all: true)
    :ok
  end

  defp migrations do
    [
      {1, Examples.ObanTasks.Migrations.CreateObanSchema},
      {2, Examples.ObanTasks.Migrations.CreateMcpTasks}
    ]
  end
end

defmodule Examples.ObanTasks.Migrations.CreateObanSchema do
  @moduledoc false
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end

defmodule Examples.ObanTasks.Migrations.CreateMcpTasks do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:mcp_tasks, primary_key: false) do
      add(:task_id, :string, primary_key: true)
      add(:status, :string, null: false, default: "working")
      add(:oban_job_id, :integer)
      add(:tool, :string)
      add(:args, :map)
      add(:result, :map)
      add(:metadata, :map)
      add(:created_at, :bigint, null: false)

      timestamps()
    end

    create(index(:mcp_tasks, [:status]))
    create(index(:mcp_tasks, [:oban_job_id]))
  end
end

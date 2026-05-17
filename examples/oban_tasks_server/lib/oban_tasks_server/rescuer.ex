defmodule Examples.ObanTasks.Rescuer do
  @moduledoc """
  Boot-time hook that "rescues" jobs left in `executing` state by a
  previous BEAM shutdown.

  Oban's full Postgres engine ships `Oban.Plugins.Lifeline` for this,
  but the SQLite-friendly `Oban.Engines.Lite` does not — so we do it
  ourselves: on app start, every row in `oban_jobs` with `state =
  "executing"` is moved back to `"available"` so the queue picks it up
  again. Without this, a crash mid-render would leave the task stuck
  forever even though the row is durable.

  One-shot: runs `handle_continue/2` then idles. The supervisor keeps
  it alive so a crash report is visible if the migration ordering ever
  changes (e.g., this races with Migrator).
  """

  use GenServer

  require Logger

  alias Examples.ObanTasks.Repo

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :rescue}}

  @impl true
  def handle_continue(:rescue, state) do
    case rescue_executing() do
      {n, _} when n > 0 -> Logger.info("ObanTasks.Rescuer: rescued #{n} executing job(s)")
      _ -> :ok
    end

    {:noreply, state}
  end

  defp rescue_executing do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE oban_jobs
      SET state = 'available',
          attempted_at = NULL,
          attempted_by = '[]',
          attempt = MAX(attempt - 1, 0)
      WHERE state = 'executing'
      """,
      []
    )
    |> case do
      %{num_rows: n} -> {n, nil}
    end
  end
end

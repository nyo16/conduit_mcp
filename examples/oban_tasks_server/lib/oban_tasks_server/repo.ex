defmodule Examples.ObanTasks.Repo do
  @moduledoc """
  Ecto repo backing the example. Uses the SQLite3 adapter so the example
  has no external service dependency — the DB lives in
  `System.tmp_dir!/0` by default (override with `OBAN_SQLITE_PATH`).
  """

  use Ecto.Repo,
    otp_app: :oban_tasks_server,
    adapter: Ecto.Adapters.SQLite3
end

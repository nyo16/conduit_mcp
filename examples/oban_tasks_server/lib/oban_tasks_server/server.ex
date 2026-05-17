defmodule Examples.ObanTasksServer do
  @moduledoc """
  MCP server demonstrating the 2025-11-25 tasks lifecycle backed by Oban
  + SQLite. Each long-running tool returns a task id immediately; the
  durable work runs in an Oban job that updates the task row as it goes.

  Tools:

  - `ping` — synchronous health check.
  - `slow_render` — `task_support: :supported`. Enqueues an Oban job,
    returns the task id, and updates the row through `working` ->
    `completed` as the job runs.

  Subsequent commits add `ask_then_render` and `provide_render_input`
  for the `input_required` lifecycle state.
  """

  use ConduitMcp.Server

  alias Examples.ObanTasks.Worker

  tool "ping", "Sync round-trip — proves the server is alive." do
    handle(fn _conn, _params -> text("pong") end)
  end

  tool "slow_render", "Renders something slowly via an Oban job." do
    task_support(:supported)
    param(:script, :string, "Script source", required: true)
    param(:duration_ms, :integer, "How long to take (ms)", default: 2_000)

    handle(fn _conn, %{"script" => script} = params ->
      duration = Map.get(params, "duration_ms", 2_000)
      task_id = ConduitMcp.Tasks.generate_id()

      {:ok, _} =
        ConduitMcp.Tasks.create(task_id, %{
          "tool" => "slow_render",
          "args" => params
        })

      {:ok, _job} =
        Worker.new(%{
          "task_id" => task_id,
          "tool" => "slow_render",
          "script" => script,
          "duration_ms" => duration
        })
        |> Oban.insert()

      task(
        task_id,
        "Render queued; poll tasks/get for progress, then tasks/result for the final payload."
      )
    end)
  end
end

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

  tool "ask_then_render",
       "Like slow_render, but pauses in input_required until provide_render_input is called." do
    task_support(:supported)
    param(:duration_ms, :integer, "How long to take once input arrives (ms)", default: 1_000)

    handle(fn _conn, params ->
      duration = Map.get(params, "duration_ms", 1_000)
      task_id = ConduitMcp.Tasks.generate_id()

      {:ok, _} =
        ConduitMcp.Tasks.create(task_id, %{
          "tool" => "ask_then_render",
          "args" => params
        })

      {:ok, _job} =
        Worker.new(%{
          "task_id" => task_id,
          "tool" => "ask_then_render",
          "duration_ms" => duration
        })
        |> Oban.insert()

      task(
        task_id,
        "Render queued; the task will land in `input_required` — call `provide_render_input` to resume."
      )
    end)
  end

  tool "provide_render_input", "Provides the input an ask_then_render task is waiting on." do
    param(:task_id, :string, "The id returned by ask_then_render", required: true)
    param(:script, :string, "Free-form script to render", required: true)

    handle(fn _conn, %{"task_id" => task_id, "script" => script} ->
      case ConduitMcp.Tasks.get(task_id) do
        {:ok, %{"status" => "input_required"} = existing} ->
          existing_meta = Map.get(existing, "metadata") || %{}

          {:ok, _} =
            ConduitMcp.Tasks.update(task_id, %{
              "status" => "working",
              "metadata" => Map.put(existing_meta, "input", script)
            })

          text("Input staged for #{task_id}; task will resume on its next attempt.")

        {:ok, %{"status" => status}} ->
          error(%{
            code: -32_000,
            message: "Task #{task_id} is not awaiting input (current status: #{status})."
          })

        {:error, :not_found} ->
          error(%{code: -32_002, message: "Task #{task_id} not found."})
      end
    end)
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

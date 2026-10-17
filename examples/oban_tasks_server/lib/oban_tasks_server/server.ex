defmodule Examples.ObanTasksServer do
  @moduledoc """
  MCP server demonstrating long-running tools backed by Oban + SQLite, on
  both protocol eras:

  - **Modern (`2026-07-28`)** — the tasks extension
    (`io.modelcontextprotocol/tasks`, `ConduitMcp.Ext.Tasks`). A task tool
    returns `{:task, attrs}`; the library checks that the client declared
    the extension, stores the task (`Examples.ObanTasks.ExtStore`), runs
    `:start` (which enqueues the Oban job) and answers `CreateTaskResult`.
    The worker reports through `ConduitMcp.Ext.Tasks`; clients poll
    `tasks/get`, answer input with `tasks/update`, cancel with
    `tasks/cancel`.
  - **Legacy (`2025-11-25`)** — a frozen reference: the tool creates a
    `ConduitMcp.Tasks` row (`Examples.ObanTasks.Store`) and returns its id
    in `_meta.task`; clients use `tasks/get|result|cancel|list` and the
    `provide_render_input` tool.

  Tools:

  - `ping` — synchronous health check.
  - `slow_render` — enqueues an Oban job that renders in chunks, then
    completes the task.
  - `ask_then_render` — pauses in `input_required` until it gets a script.
  - `provide_render_input` — legacy only: stages that script.
  """

  use ConduitMcp.Server

  alias Examples.ObanTasks.Worker

  # Lifetime of a modern task from creation, and the suggested poll rate.
  @task_ttl_ms :timer.hours(1)
  @poll_interval_ms 1_000

  tool "ping", "Sync round-trip — proves the server is alive." do
    handle(fn _conn, _params -> text("pong") end)
  end

  tool "ask_then_render",
       "Like slow_render, but pauses in input_required until it is given a script." do
    task_support(:supported)
    param(:duration_ms, :integer, "How long to take once input arrives (ms)", default: 1_000)

    handle(fn conn, params ->
      job_args = %{
        "tool" => "ask_then_render",
        "duration_ms" => Map.get(params, "duration_ms", 1_000)
      }

      if modern?(conn) do
        modern_task(job_args, "Render queued; the task will ask for a script.")
      else
        legacy_task(
          job_args,
          params,
          "Render queued; the task will land in `input_required` — call `provide_render_input` to resume."
        )
      end
    end)
  end

  # Legacy only: on the modern path the client answers the task's
  # inputRequests with tasks/update instead.
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

    handle(fn conn, %{"script" => script} = params ->
      job_args = %{
        "tool" => "slow_render",
        "script" => script,
        "duration_ms" => Map.get(params, "duration_ms", 2_000)
      }

      if modern?(conn) do
        modern_task(job_args, "Render queued.")
      else
        legacy_task(
          job_args,
          params,
          "Render queued; poll tasks/get for progress, then tasks/result for the final payload."
        )
      end
    end)
  end

  defp modern?(conn), do: match?(%ConduitMcp.Ctx{era: :modern}, ConduitMcp.Ctx.from_conn(conn))

  # The task is stored before `:start` runs, so the job can never see a
  # missing task; the request then answers CreateTaskResult.
  defp modern_task(job_args, status_message) do
    {:task,
     ttl_ms: @task_ttl_ms,
     poll_interval_ms: @poll_interval_ms,
     status_message: status_message,
     start: fn task_id ->
       {:ok, _job} =
         job_args
         |> Map.merge(%{"task_id" => task_id, "era" => "modern"})
         |> Worker.new()
         |> Oban.insert()
     end}
  end

  # Frozen 2025-11-25 flow: create the ConduitMcp.Tasks row, enqueue, return
  # the id in `_meta.task`.
  defp legacy_task(job_args, params, message) do
    task_id = ConduitMcp.Tasks.generate_id()

    {:ok, _} =
      ConduitMcp.Tasks.create(task_id, %{"tool" => job_args["tool"], "args" => params})

    {:ok, _job} = job_args |> Map.put("task_id", task_id) |> Worker.new() |> Oban.insert()

    task(task_id, message)
  end
end

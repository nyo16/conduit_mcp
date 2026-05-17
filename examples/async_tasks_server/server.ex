defmodule Examples.AsyncTasksServer do
  @moduledoc """
  Example MCP server demonstrating long-running tools using the MCP
  spec 2025-11-25 tasks lifecycle.

  Two tools:

  - `quick_echo` — synchronous, executes immediately.
  - `slow_render` — `task_support: :supported`, spawns work on a
    `Task.Supervisor`, returns a task id, and updates the task as
    work progresses. The client polls `tasks/get` for progress and
    calls `tasks/result` once `status == "completed"`.

  ## Task lifecycle

  1. Client calls `tools/call` with name `slow_render`.
  2. Server returns immediately with `_meta.task.id` and the
     supervised worker continues in the background.
  3. Client periodically calls `tasks/get` (or `tasks/list`) to read
     status — `"working"` → `"completed"` / `"failed"` / `"cancelled"`.
  4. Client calls `tasks/result` to retrieve the final payload.
  5. Optional: client can `tasks/cancel` mid-flight, which sets the
     task's status to `"cancelled"` so the worker can poll it via
     `ConduitMcp.Cancellation` or by reading the task state and
     cooperatively abort.

  ## Running

  In `application.ex` (this directory) we start a `Task.Supervisor`
  alongside Bandit. The supervisor name is `Examples.AsyncTasks.Workers`.

      iex -S mix run -e "Examples.AsyncTasks.Application.start(:normal, [])"

  Then try the flow with curl:

      # Start a long-running task
      curl -s -X POST http://localhost:4040/ -H 'Content-Type: application/json' -d '{
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "slow_render", "arguments": {"script": "scene 1"}}
      }'

      # Poll status
      curl -s -X POST http://localhost:4040/ -H 'Content-Type: application/json' -d '{
        "jsonrpc": "2.0", "id": 2, "method": "tasks/get",
        "params": {"taskId": "<task_id-from-prev-response>"}
      }'

      # Once status is "completed", fetch the result
      curl -s -X POST http://localhost:4040/ -H 'Content-Type: application/json' -d '{
        "jsonrpc": "2.0", "id": 3, "method": "tasks/result",
        "params": {"taskId": "<task_id>"}
      }'
  """

  use ConduitMcp.Server

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Tasks

  tool "quick_echo", "Returns the input synchronously" do
    title("Quick Echo")
    param(:message, :string, "Message to echo", required: true)

    handle(fn _conn, %{"message" => msg} ->
      text(msg)
    end)
  end

  tool "slow_render", "Renders something slowly" do
    title("Slow Render")
    task_support(:supported)

    param(:script, :string, "Script source", required: true)
    param(:duration_ms, :integer, "How long to take (ms)", default: 2_000)

    output_schema(%{
      "type" => "object",
      "properties" => %{
        "frames" => %{"type" => "integer"},
        "script" => %{"type" => "string"}
      },
      "required" => ["frames", "script"]
    })

    handle(fn _conn, %{"script" => script} = params ->
      duration = Map.get(params, "duration_ms", 2_000)
      task_id = Tasks.generate_id()

      {:ok, _} =
        Tasks.create(task_id, %{
          "tool" => "slow_render",
          "args" => params
        })

      Task.Supervisor.start_child(Examples.AsyncTasks.Workers, fn ->
        do_render(task_id, script, duration)
      end)

      task(task_id, "Render started; poll tasks/get for progress")
    end)
  end

  # Simulates a long-running render. Polls the cancellation state and the
  # task's own status so the client can abort via `tasks/cancel`.
  defp do_render(task_id, script, duration_ms) do
    chunk = max(div(duration_ms, 10), 50)
    deadline = System.monotonic_time(:millisecond) + duration_ms

    Stream.repeatedly(fn -> System.monotonic_time(:millisecond) end)
    |> Stream.take_while(fn now ->
      cond do
        Cancellation.cancelled?(task_id) ->
          Tasks.update(task_id, %{"status" => "cancelled"})
          false

        match?({:ok, %{"status" => "cancelled"}}, Tasks.get(task_id)) ->
          false

        now >= deadline ->
          false

        true ->
          true
      end
    end)
    |> Stream.each(fn _ -> Process.sleep(chunk) end)
    |> Stream.run()

    case Tasks.get(task_id) do
      {:ok, %{"status" => "cancelled"}} ->
        :ok

      {:ok, _} ->
        Tasks.update(task_id, %{
          "status" => "completed",
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => "Render finished"}
            ],
            "structuredContent" => %{
              "frames" => div(duration_ms, 16),
              "script" => script
            }
          }
        })

        :ok
    end
  rescue
    error ->
      Tasks.update(task_id, %{
        "status" => "failed",
        "error" => %{"message" => Exception.message(error)}
      })
  end
end

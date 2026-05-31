defmodule Examples.ObanTasks.Worker do
  @moduledoc """
  Oban worker that drives long-running MCP tools.

  ## Patterns followed

  - JSON args are string-keyed (Oban serializes args as JSON).
  - No `try/rescue` wrapping — exceptions bubble. A telemetry handler in
    `Examples.ObanTasks.Telemetry` listens for `[:oban, :job, :exception]`
    and writes `status: "failed"` to the corresponding task row so the
    MCP wire view reflects reality.
  - Cooperative cancellation is checked at each chunk boundary against
    both `ConduitMcp.Cancellation` (notifications/cancelled) *and* the
    persisted task status (tasks/cancel), so either path stops the
    worker promptly.
  - `input_required` is implemented with `{:snooze, _}` per the
    oban-thinking guidance: the worker writes `input_required`, snoozes
    for a few seconds, and re-checks `metadata.input` on its next
    attempt.
  """

  use Oban.Worker,
    queue: :mcp_tasks,
    max_attempts: 3,
    unique: [period: 300, keys: [:task_id]]

  alias ConduitMcp.{Cancellation, Tasks}

  @chunks 10
  @snooze_secs 5
  # Cap on client-supplied duration so a single render can't sleep forever.
  @max_duration_ms 60_000

  # Bound how long any single attempt may run. Oban.Engines.Lite defaults to
  # :infinity, so without this a long/adversarial render holds a queue slot.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        attempt: attempt,
        args: %{"task_id" => task_id, "tool" => tool} = args
      }) do
    # Stamp the row with the running job id on the first attempt only so the
    # Store can use Oban.cancel_job/1 from the cancel/1 callback. Tolerate a
    # vanished row (deleted/cancelled mid-flight) rather than crashing.
    if attempt == 1, do: Tasks.update(task_id, %{"oban_job_id" => job_id})

    case tool do
      "slow_render" -> render(task_id, args)
      "ask_then_render" -> ask_then_render(task_id, args)
      other -> {:cancel, "unknown tool: #{other}"}
    end
  end

  # --- slow_render: straightforward long-running tool ---

  defp render(task_id, %{"duration_ms" => requested}) do
    total = min(requested, @max_duration_ms)
    chunk_ms = max(div(total, @chunks), 50)

    Enum.reduce_while(1..@chunks, :ok, fn step, _ ->
      cond do
        cancelled?(task_id) ->
          {:halt, {:cancel, "cancelled by client"}}

        true ->
          _ = Tasks.update(task_id, %{"progress" => round(step / @chunks * 100)})
          Process.sleep(chunk_ms)
          {:cont, :ok}
      end
    end)
    |> finalize(task_id, fn ->
      %{
        "content" => [
          %{"type" => "text", "text" => "Render completed in #{total}ms (task #{task_id})."}
        ]
      }
    end)
  end

  # --- ask_then_render: pauses with input_required until input is staged ---

  defp ask_then_render(task_id, args) do
    case Tasks.get(task_id) do
      {:ok, %{"metadata" => %{"input" => input}}} when is_binary(input) and input != "" ->
        # Input was staged via provide_render_input. Continue with it.
        render(task_id, Map.put(args, "duration_ms", args["duration_ms"] || 1_000))

      {:ok, task} ->
        if cancelled?(task_id) do
          {:cancel, "cancelled while waiting for input"}
        else
          # First attempt (or input still missing) — record the elicitation
          # schema and snooze. provide_render_input flips status back to
          # "working" with metadata.input set, and Oban retries this job.
          existing_meta = Map.get(task, "metadata") || %{}

          _ =
            Tasks.update(task_id, %{
              "status" => "input_required",
              "metadata" =>
                Map.merge(existing_meta, %{
                  "elicit" => %{
                    "schema" => %{
                      "type" => "object",
                      "required" => ["script"],
                      "properties" => %{
                        "script" => %{
                          "type" => "string",
                          "description" =>
                            "Free-form script text. Call provide_render_input with this task_id to resume."
                        }
                      }
                    }
                  }
                })
            })

          {:snooze, @snooze_secs}
        end

      {:error, :not_found} ->
        {:cancel, "task row missing"}
    end
  end

  # --- helpers ---

  defp finalize({:cancel, _reason} = c, task_id, _result_fun) do
    _ = Tasks.update(task_id, %{"status" => "cancelled"})
    c
  end

  defp finalize(_, task_id, result_fun) do
    _ = Tasks.update(task_id, %{"status" => "completed", "result" => result_fun.()})
    :ok
  end

  # A task is cancelled if either:
  #   - the notifications/cancelled cooperative channel says so, or
  #   - the persisted row's status was flipped to "cancelled" by
  #     tasks/cancel (which also calls Oban.cancel_job/1 — but the job
  #     may already be executing when that lands, so we double-check).
  defp cancelled?(task_id) do
    Cancellation.cancelled?(task_id) or
      match?({:ok, %{"status" => "cancelled"}}, Tasks.get(task_id))
  end
end

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
    for a few seconds, and re-checks for the input on its next attempt.

  ## Two eras

  Jobs enqueued for a modern (`2026-07-28`) client carry `"era" =>
  "modern"` and report through `ConduitMcp.Ext.Tasks` (`progress/2`,
  `complete/2`, `require_input/3`, `cancelled?/1`); input arrives from the
  client's `tasks/update` in the task's `input_responses`. Other jobs are
  the frozen legacy (`2025-11-25`) flow over `ConduitMcp.Tasks`.
  """

  use Oban.Worker,
    queue: :mcp_tasks,
    max_attempts: 3,
    unique: [period: 300, keys: [:task_id]]

  alias ConduitMcp.{Cancellation, MRTR, Tasks}
  alias ConduitMcp.Ext.Tasks, as: ExtTasks

  @chunks 10
  @snooze_secs 5
  # Cap on client-supplied duration so a single render can't sleep forever.
  @max_duration_ms 60_000
  # Fallback when the client-supplied duration isn't a usable non-negative
  # integer (args arrive as JSON, so don't assume a clean value).
  @default_duration_ms 1_000

  # Bound how long any single attempt may run. Oban.Engines.Lite defaults to
  # :infinity, so without this a long/adversarial render holds a queue slot.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"era" => "modern", "task_id" => task_id, "tool" => tool} = args}) do
    case tool do
      "slow_render" -> modern_render(task_id, args)
      "ask_then_render" -> modern_ask_then_render(task_id, args)
      other -> {:cancel, "unknown tool: #{other}"}
    end
  end

  # Legacy (2025-11-25, frozen reference): ConduitMcp.Tasks rows.
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

  # --- modern (tasks extension) ---

  defp modern_render(task_id, %{"duration_ms" => requested} = args) do
    total = clamp_duration(requested)
    chunk_ms = max(div(total, @chunks), 50)

    Enum.reduce_while(1..@chunks, :ok, fn step, _ ->
      # tasks/cancel is cooperative: it marks the task cancelled and the
      # worker stops at the next chunk. An expired (janitor-evicted) task
      # answers :not_found to every call, so stop then too.
      if ExtTasks.cancelled?(task_id) do
        {:halt, {:cancel, "cancelled by client"}}
      else
        case ExtTasks.progress(task_id, "Rendering: #{round(step / @chunks * 100)}%") do
          :ok ->
            Process.sleep(chunk_ms)
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:cancel, "task gone: #{inspect(reason)}"}}
        end
      end
    end)
    |> case do
      :ok ->
        result = %{
          "content" => [
            %{
              "type" => "text",
              "text" => "Render of #{inspect(args["script"])} completed in #{total}ms."
            }
          ]
        }

        _ = ExtTasks.complete(task_id, result)
        :ok

      cancel ->
        cancel
    end
  end

  defp modern_ask_then_render(task_id, args) do
    case ExtTasks.status(task_id) do
      {:ok, %{status: "cancelled"}} ->
        {:cancel, "cancelled while waiting for input"}

      {:ok, %{input_responses: %{"script" => response}}} ->
        resume_with(task_id, args, response)

      {:ok, %{status: "input_required"}} ->
        # Not answered yet (or only partially): look again later.
        {:snooze, @snooze_secs}

      {:ok, %{status: "working"}} ->
        # First attempt: ask the client. It sees the request in tasks/get
        # and answers with tasks/update; the task returns to working once
        # every key is answered.
        :ok =
          ExtTasks.require_input(
            task_id,
            %{"script" => MRTR.elicit("What should be rendered?", script_schema())},
            status_message: "Waiting for a script"
          )

        {:snooze, @snooze_secs}

      {:ok, _terminal} ->
        :ok

      {:error, :not_found} ->
        {:cancel, "task expired"}
    end
  end

  defp resume_with(task_id, args, %{"action" => "accept", "content" => %{"script" => script}})
       when is_binary(script) do
    args = Map.merge(args, %{"script" => script, "duration_ms" => args["duration_ms"] || 1_000})
    modern_render(task_id, args)
  end

  defp resume_with(task_id, _args, _declined_or_malformed) do
    _ =
      ExtTasks.complete(task_id, %{
        "content" => [%{"type" => "text", "text" => "Render declined."}],
        "isError" => true
      })

    :ok
  end

  defp script_schema do
    %{
      "type" => "object",
      "required" => ["script"],
      "properties" => %{"script" => %{"type" => "string", "description" => "Free-form script"}}
    }
  end

  # --- slow_render: straightforward long-running tool ---

  defp render(task_id, %{"duration_ms" => requested}) do
    total = clamp_duration(requested)
    chunk_ms = max(div(total, @chunks), 50)

    Enum.reduce_while(1..@chunks, :ok, fn step, _ ->
      if cancelled?(task_id) do
        {:halt, {:cancel, "cancelled by client"}}
      else
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

          # Snooze does NOT consume a retry: Oban's snooze_job/3 (Lite delegates
          # to Basic) increments max_attempts alongside the attempt, so the
          # input_required wait is effectively unbounded by max_attempts: 3 —
          # that limit only governs genuine failures. (Verified vs oban 2.22.1.)
          {:snooze, @snooze_secs}
        end

      {:error, :not_found} ->
        {:cancel, "task row missing"}
    end
  end

  # --- helpers ---

  # Defensive: `duration_ms` is a validated :integer param on the happy path,
  # but worker args come back from JSON in the DB, so a manually-enqueued or
  # malformed job could carry a non-integer. Clamp to a usable non-negative
  # integer so `div/2` and `Process.sleep/1` never receive a bad value.
  defp clamp_duration(ms) when is_integer(ms) and ms >= 0, do: min(ms, @max_duration_ms)
  defp clamp_duration(_other), do: @default_duration_ms

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

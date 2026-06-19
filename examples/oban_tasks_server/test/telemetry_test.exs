defmodule Examples.ObanTasks.TelemetryTest do
  @moduledoc """
  Focused unit test for the Oban exception → MCP task-failure bridge.

  Drives `Examples.ObanTasks.Telemetry.handle_event/4` directly (no HTTP
  server, no real Oban job), so it runs in the default `mix test` pass.

  Guards the W1 fix: at `[:oban, :job, :exception]` time the job is still
  mid-execution, so `job.state` is `"executing"` and the old
  `job.state in ~w(discarded retryable)` guard never fired — a permanently
  failing task stayed `"working"` forever. The handler must now mark the task
  `"failed"` on the *final* attempt and leave it untouched on earlier attempts
  so Oban can still retry.
  """

  use ExUnit.Case, async: false

  alias ConduitMcp.Tasks
  alias Examples.ObanTasks.Telemetry

  setup do
    task_id = "tel-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Tasks.create(task_id, %{"tool" => "slow_render"})
    on_exit(fn -> Tasks.delete(task_id) end)
    %{task_id: task_id}
  end

  defp raise_on_attempt(task_id, attempt, max_attempts) do
    # `state: "executing"` mirrors reality — Oban has not transitioned the row
    # to discarded/retryable yet when this event fires. The fixed handler must
    # ignore state and key off the attempt count alone.
    job = %{
      args: %{"task_id" => task_id},
      attempt: attempt,
      max_attempts: max_attempts,
      state: "executing"
    }

    Telemetry.handle_event(
      [:oban, :job, :exception],
      %{},
      %{job: job, reason: %RuntimeError{message: "boom"}},
      nil
    )
  end

  test "marks the task failed on the final attempt", %{task_id: task_id} do
    assert {:ok, %{"status" => "working"}} = Tasks.get(task_id)

    assert :ok = raise_on_attempt(task_id, 3, 3)

    assert {:ok, %{"status" => "failed"} = task} = Tasks.get(task_id)
    assert get_in(task, ["metadata", "error", "message"]) == "boom"
  end

  test "leaves the task working on a non-final attempt so Oban retries", %{task_id: task_id} do
    assert :ok = raise_on_attempt(task_id, 1, 3)

    assert {:ok, %{"status" => "working"}} = Tasks.get(task_id)
  end
end

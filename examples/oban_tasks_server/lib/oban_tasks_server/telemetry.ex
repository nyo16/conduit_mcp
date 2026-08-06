defmodule Examples.ObanTasks.Telemetry do
  @moduledoc """
  Bridges Oban's job-exception telemetry into the MCP task store.

  When a worker raises (or is force-killed past `max_attempts`), Oban
  emits `[:oban, :job, :exception]`. This module attaches a handler
  that marks the corresponding `mcp_tasks` row as `"failed"` with an
  error description, so `tasks/get` and `tasks/result` reflect the
  actual outcome without the worker needing a try/rescue.
  """

  require Logger

  alias ConduitMcp.Tasks

  @handler_id "examples-oban-tasks-failure-handler"

  def attach do
    :telemetry.attach(
      @handler_id,
      [:oban, :job, :exception],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(
        [:oban, :job, :exception],
        _measurements,
        %{job: %{args: %{"task_id" => task_id}} = job, reason: reason},
        _config
      ) do
    # At `[:oban, :job, :exception]` time the job is still mid-execution, so
    # `job.state` is `"executing"` (the discarded/retryable transition happens
    # *after* this event). Gate purely on the attempt count: mark "failed" only
    # on the final attempt so earlier raises fall through and Oban can retry.
    if job.attempt >= job.max_attempts do
      msg = format_reason(reason)

      Tasks.update(task_id, %{
        "status" => "failed",
        "error" => %{"message" => msg}
      })

      Logger.warning("ObanTasks: task #{task_id} failed permanently: #{msg}")
    end

    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  defp format_reason(%{__struct__: _} = exception),
    do: Exception.message(exception)

  defp format_reason(other) when is_binary(other), do: other
  defp format_reason(other), do: inspect(other)
end

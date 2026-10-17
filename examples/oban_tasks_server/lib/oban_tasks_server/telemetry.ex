defmodule Examples.ObanTasks.Telemetry do
  @moduledoc """
  Bridges Oban's job-exception telemetry into the MCP task store.

  When a worker raises (or is force-killed past `max_attempts`), Oban
  emits `[:oban, :job, :exception]`. This module attaches a handler
  that marks the corresponding task as `"failed"` — a legacy `mcp_tasks`
  row, or (for a modern job) the `ConduitMcp.Ext.Tasks` task with a
  `-32603` error — so `tasks/get` reflects the actual outcome without the
  worker needing a try/rescue.
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
      mark_failed(job.args, task_id, msg)
    end

    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  # A modern task id is a bearer token: keep it out of the log.
  defp mark_failed(%{"era" => "modern"}, task_id, msg) do
    _ = ConduitMcp.Ext.Tasks.fail(task_id, {-32_603, "Internal error"}, status_message: msg)
    Logger.warning("ObanTasks: an extension task failed permanently: #{msg}")
  end

  defp mark_failed(_args, task_id, msg) do
    Tasks.update(task_id, %{
      "status" => "failed",
      "error" => %{"message" => msg}
    })

    Logger.warning("ObanTasks: task #{task_id} failed permanently: #{msg}")
  end

  defp format_reason(%{__struct__: _} = exception),
    do: Exception.message(exception)

  defp format_reason(other) when is_binary(other), do: other
  defp format_reason(other), do: inspect(other)
end

defmodule ConduitMcp.Client.Connection.TaskWatch do
  @moduledoc false

  # A caller awaiting a server task (`ConduitMcp.Client.await_task/3`) polls
  # it from its own process. If that process dies, nobody would ever cancel
  # the task, so the caller registers it here: the connection monitors the
  # caller and, on its `:DOWN`, sends `tasks/cancel` itself (fire and
  # forget; the answer is dropped). A caller that finishes unregisters.

  alias ConduitMcp.Client.Connection.Data

  @tasks_extension %{"io.modelcontextprotocol/tasks" => %{}}

  @doc "Monitors `pid` and cancels `task_id` if it dies."
  @spec watch(pid(), String.t(), Data.t()) :: Data.t()
  def watch(pid, task_id, data) do
    ref = Process.monitor(pid)
    %{data | watches: Map.put(data.watches, ref, {pid, task_id})}
  end

  @doc "Forgets the watch of `pid` on `task_id`."
  @spec unwatch(pid(), String.t(), Data.t()) :: Data.t()
  def unwatch(pid, task_id, data) do
    {gone, kept} = Enum.split_with(data.watches, fn {_ref, watch} -> watch == {pid, task_id} end)
    Enum.each(gone, fn {ref, _watch} -> Process.demonitor(ref, [:flush]) end)
    %{data | watches: Map.new(kept)}
  end

  @doc "A watched caller died: cancel its task. `:unknown` when `ref` is not a watch."
  @spec down(reference(), atom(), Data.t()) :: Data.t() | :unknown
  def down(ref, state, data) do
    case Map.pop(data.watches, ref) do
      {nil, _watches} -> :unknown
      {{_pid, task_id}, watches} -> cancel(task_id, state, %{data | watches: watches})
    end
  end

  defp cancel(task_id, :ready, data) do
    {id, data} = Data.take_id(data)
    info = if data.era == :modern, do: %{extensions: @tasks_extension}, else: %{}

    case Data.send_request(data, id, "tasks/cancel", %{"taskId" => task_id}, info, nil, []) do
      {:ok, _handle, data} -> %{data | internal: Map.put(data.internal, id, :task_cancel)}
      {:error, _reason, data} -> data
    end
  end

  # Not connected: the task cannot be reached now.
  defp cancel(_task_id, _state, data), do: data
end

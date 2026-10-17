defmodule ConduitMcp.Ext.Tasks.ListenNotifier do
  @moduledoc """
  The default `ConduitMcp.Ext.Tasks.Notifier` (experimental, unstable):
  delivers every task change as `notifications/tasks` to the
  `subscriptions/listen` streams of this node that asked for the task
  with the `taskIds` filter (`ConduitMcp.Subscriptions.Filter`).

  The notification's params are the full task state,
  `ConduitMcp.Ext.Tasks.to_wire/1` — what `tasks/get` would answer at that
  moment.

  A change reaches **only** streams whose principal owns the task (SV-1):
  it is published to the topic `{:task, owner, task_id}`, and a stream
  registers under that topic with its own `ConduitMcp.Principal.id/1`, the
  owner identity `tasks/get` checks. A stream of another principal is never
  sent the change, even if it names the task id; a task owned by `nil`
  (created without authentication) reaches only unauthenticated streams.

  Delivery is node-local, like the rest of `ConduitMcp.Subscriptions`. A
  custom notifier replaces this one; call `task_changed/1` from it to keep
  listen delivery:

      defmodule MyApp.TaskNotifier do
        @behaviour ConduitMcp.Ext.Tasks.Notifier

        @impl true
        def task_changed(task) do
          ConduitMcp.Ext.Tasks.ListenNotifier.task_changed(task)
          MyApp.Workers.wake(task.task_id)
        end
      end
  """

  @behaviour ConduitMcp.Ext.Tasks.Notifier

  alias ConduitMcp.Ext.Tasks
  alias ConduitMcp.Subscriptions

  @impl true
  def task_changed(%{task_id: task_id, owner: owner} = task) do
    Subscriptions.publish(
      Subscriptions.task_topic(owner, task_id),
      ConduitMcp.Protocol.notification("notifications/tasks", Tasks.to_wire(task))
    )
  end
end

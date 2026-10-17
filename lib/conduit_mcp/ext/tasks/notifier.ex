defmodule ConduitMcp.Ext.Tasks.Notifier do
  @moduledoc """
  Hook called after every `ConduitMcp.Ext.Tasks` state change
  (experimental, unstable).

  Configure one with `config :conduit_mcp, :ext_tasks, notifier: MyNotifier`.
  `c:task_changed/1` runs in the process that made the change (a request
  process or the task's worker) right after the store write; an exception
  is logged and swallowed, so a notifier cannot fail a request or a worker.

  This is the seam for `notifications/tasks`: delivering a change over
  `subscriptions/listen` streams belongs to the subscriptions subsystem,
  which must deliver a record only to streams whose principal is the
  record's `owner` (the same owner check as `tasks/get`). A notifier can
  also wake a worker waiting on `tasks/update` input.
  `ConduitMcp.Ext.Tasks.to_wire/1` builds the notification's task state.
  """

  @doc "Called with the record as stored after a change."
  @callback task_changed(ConduitMcp.Ext.Tasks.Store.task()) :: term()
end

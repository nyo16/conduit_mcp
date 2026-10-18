defmodule ConduitMcp.Ext.Tasks.Notifier do
  @moduledoc """
  Hook called after every `ConduitMcp.Ext.Tasks` state change
  (experimental, unstable).

  The default is `ConduitMcp.Ext.Tasks.ListenNotifier`, which delivers
  `notifications/tasks` over `subscriptions/listen` to the task owner's
  streams. Configure another with
  `config :conduit_mcp, :ext_tasks, notifier: MyNotifier` (it replaces the
  default; call `ConduitMcp.Ext.Tasks.ListenNotifier.task_changed/1` from it
  to keep listen delivery), or `notifier: nil` for none.

  `c:task_changed/1` runs in the process that made the change (a request
  process or the task's worker) right after the store write; an exception
  is logged and swallowed, so a notifier cannot fail a request or a worker.

  A notifier that delivers a change to clients must deliver it only to the
  record's `owner` (the same owner check as `tasks/get`). A notifier can
  also wake a worker waiting on `tasks/update` input.
  `ConduitMcp.Ext.Tasks.to_wire/1` builds the notification's task state.
  """

  @doc "Called with the record as stored after a change."
  @callback task_changed(ConduitMcp.Ext.Tasks.Store.task()) :: term()
end

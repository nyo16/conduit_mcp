defmodule ConduitMcp.Subscriptions do
  @moduledoc """
  The node-local registry behind `subscriptions/listen` (protocol
  `2026-07-28`), and the dispatch of change notifications to it.

  A modern client opens a long-lived notification stream by POSTing
  `subscriptions/listen` with a `notifications` filter
  (`ConduitMcp.Subscriptions.Filter`). The request process serving that
  stream registers itself here under one **topic** per notification type it
  agreed to deliver, then relays whatever is published to those topics as
  Server-Sent Events until the client or the server closes the stream. The
  server pushes with the public API on `ConduitMcp`:

      ConduitMcp.notify_tools_changed()
      ConduitMcp.notify_prompts_changed()
      ConduitMcp.notify_resources_changed()
      ConduitMcp.notify_resource_updated("file:///project/config.json")

  ## Topics

  | Topic | Filter field | Notification |
  |---|---|---|
  | `:tools` | `toolsListChanged` | `notifications/tools/list_changed` |
  | `:prompts` | `promptsListChanged` | `notifications/prompts/list_changed` |
  | `:resources` | `resourcesListChanged` | `notifications/resources/list_changed` |
  | `{:resource, uri}` | `resourceSubscriptions` | `notifications/resources/updated` |
  | `{:task, owner, task_id}` | `taskIds` | `notifications/tasks` |

  A resource topic matches its URI exactly: `notify_resource_updated/1` for
  `"file:///a/b"` does not reach a stream subscribed to `"file:///a"`.

  A task topic carries the task's owner (`ConduitMcp.Principal.id/1`, `nil`
  when unauthenticated), and a stream subscribes under its own principal's
  id, so a task's changes reach only its owner's streams (SV-1). They are
  published by `ConduitMcp.Ext.Tasks.ListenNotifier`, the default notifier
  of `ConduitMcp.Ext.Tasks`.

  ## Node-local

  The registry is a `Registry` started under `ConduitMcp.Supervisor`
  (duplicate keys), so a notification reaches only the streams served by
  the node that published it. On a cluster, broadcast the change on your own
  PubSub and call the `ConduitMcp.notify_*` function on every node:

      # wherever the change happens
      Phoenix.PubSub.broadcast(MyApp.PubSub, "mcp", :tools_changed)

      # in a process subscribed to "mcp" on every node
      def handle_info(:tools_changed, state) do
        ConduitMcp.notify_tools_changed()
        {:noreply, state}
      end

  ## Lifecycle and bounds

  Registry entries belong to the stream's process: a stream that ends
  unregisters them, and the registry drops the entries of a process that
  dies (it is linked to every registrant), so a killed stream leaks nothing.
  The same holds for its entry in `ConduitMcp.Subscriptions.Admission`, which
  monitors every admitted stream.

  Each stream is bounded by the transport (see
  `ConduitMcp.Transport.StreamableHTTP`): at most `:max_listens_per_principal`
  live streams per principal (default 4), the shared `:max_streams` cap (503 when full), `:max_stream_lifetime`,
  the bearer token's `exp`, and `:listen_idle_timeout`. A filter may name at
  most 1 000 resource URIs (`ConduitMcp.Subscriptions.Filter`).

  The per-principal cap is never answered 429: a listen that would exceed it
  is admitted and the principal's **oldest** stream is superseded - it ends
  with `notifications/cancelled` for its listen id, then the graceful-closure
  result, then closes (telemetry `subscription.stop` reason `:superseded`).
  A client that went away is only noticed on the stream's next write, so a
  client opening one listen per run (e.g. the MCP Inspector CLI) would
  otherwise be locked out by its own dead streams. Admission and eviction
  are one step of `ConduitMcp.Subscriptions.Admission`, a node-local process
  that answers admissions in arrival order, so even a burst of concurrent
  listens never holds more than the cap live at once; superseded streams
  still writing their teardown are not counted (each also holds a
  `:max_streams` slot until it closes). One principal still never holds more
  than the cap (SV-10), and another principal's streams are never evicted.
  """

  alias ConduitMcp.Notifications
  alias ConduitMcp.Subscriptions.Admission

  @typedoc "What a stream subscribes to; see the Topics table."
  @type topic ::
          :tools
          | :prompts
          | :resources
          | {:resource, String.t()}
          | {:task, String.t() | nil, String.t()}

  @doc """
  The child spec of the registry, started by `ConduitMcp.Application`.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Supervisor.child_spec({Registry, keys: :duplicate, name: __MODULE__}, id: __MODULE__)
  end

  @doc """
  Sends `notifications/tools/list_changed` to every local stream subscribed
  to `toolsListChanged`. See `ConduitMcp.notify_tools_changed/0`.
  """
  @spec notify_tools_changed() :: :ok
  def notify_tools_changed,
    do: publish(:tools, Notifications.tool_list_changed_notification())

  @doc """
  Sends `notifications/prompts/list_changed` to every local stream subscribed
  to `promptsListChanged`. See `ConduitMcp.notify_prompts_changed/0`.
  """
  @spec notify_prompts_changed() :: :ok
  def notify_prompts_changed,
    do: publish(:prompts, Notifications.prompt_list_changed_notification())

  @doc """
  Sends `notifications/resources/list_changed` to every local stream
  subscribed to `resourcesListChanged`. See
  `ConduitMcp.notify_resources_changed/0`.
  """
  @spec notify_resources_changed() :: :ok
  def notify_resources_changed,
    do: publish(:resources, Notifications.resource_list_changed_notification())

  @doc """
  Sends `notifications/resources/updated` for `uri` to every local stream
  whose `resourceSubscriptions` named exactly `uri`. See
  `ConduitMcp.notify_resource_updated/1`.
  """
  @spec notify_resource_updated(String.t()) :: :ok
  def notify_resource_updated(uri) when is_binary(uri),
    do: publish({:resource, uri}, Notifications.resource_updated_notification(uri))

  @doc """
  Delivers `notification` — a complete JSON-RPC notification map, such as a
  `ConduitMcp.Notifications` builder returns — to every local stream
  subscribed to `topic`.

  The stream adds `_meta["io.modelcontextprotocol/subscriptionId"]` itself.
  Delivery is a message send per stream: this returns once every stream has
  been sent the notification, not once each has written it.
  """
  @spec publish(term(), map()) :: :ok
  def publish(topic, notification) when is_map(notification) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, ref} <- entries, do: send(pid, {__MODULE__, ref, notification})
    end)
  end

  @doc """
  The pids of the local streams subscribed to `topic`. For introspection and
  tests; the order is unspecified.
  """
  @spec subscribers(term()) :: [pid()]
  def subscribers(topic) do
    for {pid, _ref} <- Registry.lookup(__MODULE__, topic), do: pid
  end

  @doc """
  The topic of `task_id`'s changes for streams of the principal `owner`
  (`ConduitMcp.Principal.id/1`; `nil` when unauthenticated).
  """
  @spec task_topic(String.t() | nil, String.t()) :: topic()
  def task_topic(owner, task_id), do: {:task, owner, task_id}

  # --- stream-side registration (ConduitMcp.Subscriptions.Stream) -----------

  @doc false
  # Admits the calling process as one more stream of `principal_key`, tagged
  # `ref`, keeping at most `max` live streams per principal: when the
  # principal is already at `max`, its oldest live streams are superseded -
  # each is sent `{ConduitMcp.Subscriptions, ref, :superseded}` (its own
  # ref, so the stream loop matches it and `flush/1` drops a late one) and
  # ends with the server-initiated teardown.
  #
  # The bookkeeping lives in `ConduitMcp.Subscriptions.Admission`, which
  # answers admissions one at a time: the live count never exceeds `max`,
  # even during a burst. A superseded stream leaves the live set at once, so
  # it is not counted, nor evicted, a second time while it writes its
  # teardown.
  @spec admit(String.t(), pos_integer(), reference()) :: :ok
  defdelegate admit(principal_key, max, ref), to: Admission

  @doc false
  # The not-yet-superseded streams of `principal_key`, as `{seq, pid, ref}`,
  # oldest first.
  @spec live_listeners(String.t()) :: [Admission.listener()]
  defdelegate live_listeners(principal_key), to: Admission

  @doc false
  # Subscribes the calling process to `topics`; what `publish/2` sends it is
  # tagged with `ref`.
  @spec subscribe([topic()], reference()) :: :ok
  def subscribe(topics, ref) do
    Enum.each(topics, fn topic -> {:ok, _owner} = Registry.register(__MODULE__, topic, ref) end)
  end

  @doc false
  # Undoes `subscribe/2` and `admit/3` for the calling process. Needed even
  # though the registry and `Admission` clean up after a dead process: under
  # HTTP/1.1 keep-alive the same process goes on to serve the connection's
  # next request.
  @spec leave([topic()], String.t()) :: :ok
  def leave(topics, principal_key) do
    :ok = Admission.leave(principal_key)
    Enum.each(topics, &Registry.unregister(__MODULE__, &1))
  end
end

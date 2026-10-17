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

  Each stream is bounded by the transport (see
  `ConduitMcp.Transport.StreamableHTTP`): at most `:max_listens_per_principal`
  concurrent streams per principal (default 4; the next is answered HTTP
  429), the shared `:max_streams` cap (503 when full), `:max_stream_lifetime`,
  the bearer token's `exp`, and `:listen_idle_timeout`. A filter may name at
  most 1 000 resource URIs (`ConduitMcp.Subscriptions.Filter`).
  """

  alias ConduitMcp.Notifications

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
  # Admits the calling process as one more stream of `principal_key`, at
  # most `max` at once. Insert-then-count, as `SSEStream.acquire_slot/3`: each
  # racer counts its own entry, so two at the boundary can both be refused
  # but no interleaving admits more than `max`. A dead stream's entry is
  # dropped by the registry when its exit is processed, so it can only
  # briefly over-count - refusing rather than over-admitting.
  @spec admit(String.t(), pos_integer()) :: boolean()
  def admit(principal_key, max) do
    key = listener_key(principal_key)
    {:ok, _owner} = Registry.register(__MODULE__, key, nil)

    if length(Registry.lookup(__MODULE__, key)) <= max do
      true
    else
      Registry.unregister(__MODULE__, key)
      false
    end
  end

  @doc false
  # Subscribes the calling process to `topics`; what `publish/2` sends it is
  # tagged with `ref`.
  @spec subscribe([topic()], reference()) :: :ok
  def subscribe(topics, ref) do
    Enum.each(topics, fn topic -> {:ok, _owner} = Registry.register(__MODULE__, topic, ref) end)
  end

  @doc false
  # Undoes `subscribe/2` and `admit/2` for the calling process. Needed even
  # though the registry cleans up after a dead process: under HTTP/1.1
  # keep-alive the same process goes on to serve the connection's next
  # request.
  @spec leave([topic()], String.t()) :: :ok
  def leave(topics, principal_key) do
    Enum.each([listener_key(principal_key) | topics], &Registry.unregister(__MODULE__, &1))
  end

  @doc false
  @spec listener_key(String.t()) :: {:listener, String.t()}
  def listener_key(principal_key), do: {:listener, principal_key}
end

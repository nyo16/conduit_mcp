defmodule ConduitMcp.Subscriptions.Filter do
  @moduledoc """
  The `notifications` filter of a `subscriptions/listen` request
  (`SubscriptionFilter`), reduced to the subset this server honours.

  `parse/3` turns the request's `params` into a `t:t/0`:

    * `:ack` — the `notifications` object of
      `notifications/subscriptions/acknowledged`: only the fields honoured,
      each with the value honoured;
    * `:topics` — the `ConduitMcp.Subscriptions` topics the stream registers
      under;
    * `:kinds` — the honoured fields as atoms, for telemetry (never URIs).

  ## Fields

    * `toolsListChanged`, `promptsListChanged`, `resourcesListChanged` — a
      boolean. `true` is honoured when the server advertises the matching
      capability (`ConduitMcp.Capabilities.build/2`): an Endpoint without
      prompts omits `promptsListChanged` from the acknowledgment, as the
      specification asks. `false` subscribes to nothing.
    * `resourceSubscriptions` — a list of at most
      #{1_000} URI strings. Each is authorized like `resources/read` (the
      resource's `scope`); a URI the caller may not read is dropped from the
      acknowledgment silently, exactly as if it had not been requested, so
      the acknowledgment reveals nothing beyond what the caller may read.
      Duplicates are collapsed; an empty result omits the field.
    * `taskIds` — only while `ConduitMcp.Ext.Tasks` is enabled (otherwise an
      unknown field): a list of at most #{1_000} task ids for
      `notifications/tasks`. The request must declare the
      `io.modelcontextprotocol/tasks` extension in its client capabilities
      (`-32021` with `data.requiredCapabilities` otherwise, as the extension
      requires). Each id is kept only if the task exists and is owned by the
      caller (`ConduitMcp.Principal.id/1`, the owner check of `tasks/get`);
      any other id is dropped silently, so a foreign id and an unknown one
      look the same. The stream then receives a task's changes only while
      its principal is the task's owner (SV-1): the topic is keyed by owner.
      Duplicates are collapsed; an empty result omits the field.

  A field of the wrong type, a `notifications` that is not an object, or
  more than #{1_000} URIs or task ids is `-32602`. Unknown fields (a newer
  revision's, or an extension's this server does not enable) are not
  honoured and are omitted from the acknowledgment.
  """

  alias ConduitMcp.Capabilities
  alias ConduitMcp.Ctx
  alias ConduitMcp.Errors
  alias ConduitMcp.Ext.Tasks
  alias ConduitMcp.Handler.ExtTasks
  alias ConduitMcp.Handler.Resources
  alias ConduitMcp.Principal
  alias ConduitMcp.Subscriptions

  @max_resource_subscriptions 1_000
  @max_task_ids 1_000

  # Filter field => how it is honoured. A new filter field (an extension's,
  # such as `taskIds`) is one entry here plus a `honour/5` clause.
  @fields [
    {"toolsListChanged", :tools_list_changed},
    {"promptsListChanged", :prompts_list_changed},
    {"resourcesListChanged", :resources_list_changed},
    {"resourceSubscriptions", :resource_subscriptions},
    {"taskIds", :task_ids}
  ]

  @list_changed %{
    tools_list_changed: {"tools", :tools},
    prompts_list_changed: {"prompts", :prompts},
    resources_list_changed: {"resources", :resources}
  }

  defstruct ack: %{}, topics: [], kinds: []

  @typedoc "An honoured filter; see the moduledoc."
  @type t :: %__MODULE__{
          ack: %{optional(String.t()) => boolean() | [String.t()]},
          topics: [ConduitMcp.Subscriptions.topic()],
          kinds: [atom()]
        }

  @doc """
  The most URIs one `resourceSubscriptions` may name (#{@max_resource_subscriptions}).
  """
  @spec max_resource_subscriptions() :: pos_integer()
  def max_resource_subscriptions, do: @max_resource_subscriptions

  @doc """
  Parses the `params` of a `subscriptions/listen` request for
  `server_module`, authorizing resource URIs against `conn`.
  """
  @spec parse(map(), module(), Plug.Conn.t() | map()) ::
          {:ok, t()} | {:error, integer(), String.t(), map() | nil}
  def parse(%{"notifications" => filter}, server_module, conn) when is_map(filter) do
    capabilities = Capabilities.build(server_module, era: :modern)

    Enum.reduce_while(@fields, {:ok, %__MODULE__{}}, fn {field, kind}, {:ok, acc} ->
      case honour(kind, Map.fetch(filter, field), capabilities, server_module, conn) do
        :skip ->
          {:cont, {:ok, acc}}

        {:ok, value, topics} ->
          {:cont,
           {:ok,
            %{
              acc
              | ack: Map.put(acc.ack, field, value),
                topics: acc.topics ++ topics,
                kinds: acc.kinds ++ [kind]
            }}}

        {:error, message} ->
          {:halt, {:error, Errors.invalid_params(), message, nil}}

        {:error, _code, _message, _data} = error ->
          {:halt, error}
      end
    end)
  end

  def parse(_params, _server_module, _conn),
    do: {:error, Errors.invalid_params(), "notifications must be an object", nil}

  defp honour(_kind, :error, _capabilities, _server_module, _conn), do: :skip

  defp honour(kind, {:ok, value}, capabilities, _server_module, _conn)
       when is_map_key(@list_changed, kind) do
    {capability, topic} = Map.fetch!(@list_changed, kind)

    cond do
      not is_boolean(value) -> {:error, "notifications.#{field(kind)} must be a boolean"}
      value and Map.has_key?(capabilities, capability) -> {:ok, true, [topic]}
      true -> :skip
    end
  end

  defp honour(:resource_subscriptions, {:ok, uris}, capabilities, server_module, conn) do
    cond do
      not is_list(uris) ->
        {:error, "notifications.resourceSubscriptions must be an array of strings"}

      length(uris) > @max_resource_subscriptions ->
        {:error,
         "notifications.resourceSubscriptions names more than " <>
           "#{@max_resource_subscriptions} URIs"}

      not Enum.all?(uris, &is_binary/1) ->
        {:error, "notifications.resourceSubscriptions must be an array of strings"}

      not Map.has_key?(capabilities, "resources") ->
        :skip

      true ->
        uris
        |> Enum.uniq()
        |> Enum.filter(&(Resources.authorize(&1, server_module, conn) == :ok))
        |> case do
          [] -> :skip
          allowed -> {:ok, allowed, Enum.map(allowed, &{:resource, &1})}
        end
    end
  end

  defp honour(:task_ids, {:ok, ids}, _capabilities, _server_module, conn) do
    cond do
      not Tasks.enabled?() ->
        :skip

      not is_list(ids) or not Enum.all?(ids, &is_binary/1) ->
        {:error, "notifications.taskIds must be an array of strings"}

      length(ids) > @max_task_ids ->
        {:error, "notifications.taskIds names more than #{@max_task_ids} tasks"}

      ids == [] ->
        :skip

      not ExtTasks.declared?(Ctx.from_conn(conn)) ->
        ExtTasks.missing_capability()

      true ->
        owner = Principal.id(conn)

        ids
        |> Enum.uniq()
        |> Enum.filter(&match?({:ok, _task}, Tasks.get(&1, owner)))
        |> case do
          [] -> :skip
          owned -> {:ok, owned, Enum.map(owned, &Subscriptions.task_topic(owner, &1))}
        end
    end
  end

  defp field(kind), do: Enum.find_value(@fields, fn {field, k} -> if k == kind, do: field end)
end

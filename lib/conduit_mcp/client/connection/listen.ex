defmodule ConduitMcp.Client.Connection.Listen do
  @moduledoc false

  # Change notifications and resource subscriptions, for both eras and every
  # transport.
  #
  # The connection keeps one desired set of resource URIs
  # (`ConduitMcp.Client.subscribe/2`), which survives reconnects.
  #
  # Legacy: `resources/subscribe` / `resources/unsubscribe` requests (the
  # caller is answered with the server's answer), re-sent for every URI each
  # time a session becomes ready - after a reconnect or a session renewal.
  # List-changed notifications arrive unasked (on the GET stream over HTTP).
  #
  # Modern: a `subscriptions/listen` request whose `notifications` filter is
  # the union of
  #
  #   * `toolsListChanged` / `promptsListChanged` / `resourcesListChanged`,
  #     for each kind the server advertises `listChanged` for, once the client
  #     has a consumer for it: the kind's list is cached, or a process is
  #     subscribed with `subscribe_notifications/2`, or the handler takes
  #     notifications;
  #   * `resourceSubscriptions`: the desired URIs.
  #
  # The listen is a request the connection sends itself (`wire_opts`
  # `listen: true`; HTTP sends it on its own stream with an idle timeout
  # instead of a deadline). Its first message is
  # `notifications/subscriptions/acknowledged` with the honoured subset; a
  # `subscribe/2` caller is answered then (`:ok` when its URI was honoured).
  # Every notification of a listen carries `_meta` `subscriptionId` = the
  # listen's id: notifications are routed only for a live listen, with that
  # key removed; one naming another id is dropped (stdio demultiplexes this
  # way). A filter change is make-before-break: the new listen is opened,
  # and the old one cancelled once the new one is acknowledged (HTTP closes
  # its stream, stdio sends `notifications/cancelled`). At most four listens
  # exist at once (HT-9).
  #
  # When the active listen ends - the server's graceful result, or a drop -
  # it is reopened after `backoff.(attempt)`; a drop also marks every cached
  # list stale, since notifications may have been missed. A listen answered
  # with a JSON-RPC error (a server without the method) is not retried until
  # the next handshake. A reconnect forgets every listen; becoming ready
  # opens them again (stdio's MUST re-send).

  require Logger

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Error

  @subscription_id "io.modelcontextprotocol/subscriptionId"
  @acknowledged "notifications/subscriptions/acknowledged"
  @max_listens 4

  @list_changed [
    {"tools", "toolsListChanged", [:tools]},
    {"prompts", "promptsListChanged", [:prompts]},
    {"resources", "resourcesListChanged", [:resources, :resource_templates]}
  ]

  @type result :: {Data.t(), [:gen_statem.action()]}

  @doc "The listen state of a new connection (`Data`'s `:listen`)."
  @spec new() :: map()
  def new,
    do: %{subs: MapSet.new(), listens: %{}, active: nil, waiters: [], attempt: 0, off?: false}

  defp put(data, changes), do: %{data | listen: Map.merge(data.listen, Map.new(changes))}

  @doc "The most listens one connection keeps open at once."
  @spec max_listens() :: pos_integer()
  def max_listens, do: @max_listens

  # --- lifecycle -------------------------------------------------------------

  @doc "The connection just became ready: re-apply the subscriptions."
  @spec on_ready(Data.t()) :: result()
  def on_ready(%Data{era: :legacy} = data), do: {resubscribe(data), []}
  def on_ready(data), do: sync(data, :ready)

  @doc """
  The connection lost its session (reconnect, close): every listen is gone
  with the transport; callers still waiting are answered and their change
  undone.
  """
  @spec reset(Data.t(), Error.t()) :: result()
  def reset(data, %Error{} = error) do
    data = fail_waiters(data, data.listen.waiters, error)

    {put(data, listens: %{}, active: nil, waiters: [], off?: false),
     [{{:timeout, :listen}, :cancel}]}
  end

  @doc "The reopen timer fired."
  @spec timer(Data.t(), atom()) :: result()
  def timer(data, state), do: sync(data, state)

  # --- the modern filter ---------------------------------------------------------

  @doc """
  Opens a listen when the wanted filter differs from the active one (the
  old one is closed once the new one is acknowledged), closes every listen
  when nothing is wanted. Only in a ready modern connection.
  """
  @spec sync(Data.t(), atom()) :: result()
  def sync(%Data{era: :modern, listen: %{off?: false}} = data, :ready) do
    want = filter(data)
    pending? = Enum.any?(data.listen.listens, fn {_id, listen} -> listen.status == :pending end)
    active = data.listen.active && Map.get(data.listen.listens, data.listen.active)

    cond do
      want == %{} -> {close_all(data), []}
      pending? -> {data, []}
      active != nil and active.filter == want -> {settle(data, active.filter, active.acked), []}
      map_size(data.listen.listens) >= @max_listens -> {data, []}
      true -> open(want, data)
    end
  end

  def sync(data, _state), do: {data, []}

  @doc "The filter the connection wants now (empty: no listen)."
  @spec filter(Data.t()) :: map()
  def filter(%Data{server: %{capabilities: caps}} = data) do
    consumer? = map_size(data.subscribers) > 0 or data.notifier != nil

    flags =
      for {capability, key, kinds} <- @list_changed,
          list_changed?(caps, capability),
          consumer? or Enum.any?(kinds, &Cache.cached?(data.cache, &1)),
          into: %{},
          do: {key, true}

    case Enum.sort(MapSet.to_list(data.listen.subs)) do
      [] -> flags
      uris -> Map.put(flags, "resourceSubscriptions", uris)
    end
  end

  def filter(_data), do: %{}

  defp list_changed?(caps, capability) do
    case caps do
      %{^capability => %{"listChanged" => true}} -> true
      _other -> false
    end
  end

  defp open(want, data) do
    {id, data} = Data.take_id(data)
    params = %{"notifications" => want}

    case Data.send_request(data, id, "subscriptions/listen", params, %{}, nil, listen: true) do
      {:ok, _handle, data} ->
        listen = %{filter: want, status: :pending, acked: nil}

        data = %{data | internal: Map.put(data.internal, id, :listen)}
        {put(data, listens: Map.put(data.listen.listens, id, listen)), []}

      {:error, reason, data} ->
        Logger.debug("MCP client could not open subscriptions/listen", reason: tag(reason))
        reopen_later(data)
    end
  end

  defp close_all(data) do
    data =
      Enum.reduce(data.listen.listens, data, fn {id, _listen}, data -> cancel(data, id) end)

    settle(put(data, listens: %{}, active: nil), %{})
  end

  defp cancel(data, id) do
    data = Data.cancel(data, id, nil, :replaced)
    %{data | internal: Map.delete(data.internal, id)}
  end

  # --- notifications ---------------------------------------------------------------

  @doc """
  A server notification, before routing: `{:route, params, data, actions}`
  (with a live listen's `subscriptionId` removed) or `{:handled, data,
  actions}` (an acknowledgment, a listen's own cancellation, or a message
  of a listen that is gone).
  """
  @spec notification(String.t(), map(), Data.t(), atom()) ::
          {:route, map(), Data.t(), list()} | {:handled, Data.t(), list()}
  def notification(method, %{"_meta" => %{@subscription_id => id} = meta} = params, data, state) do
    case Map.fetch(data.listen.listens, id) do
      {:ok, _listen} when method == @acknowledged ->
        {data, actions} = acknowledged(id, params, data, state)
        {:handled, data, actions}

      # The server ending a listen: its result follows.
      {:ok, _listen} when method == "notifications/cancelled" ->
        {:handled, data, []}

      {:ok, _listen} ->
        meta = Map.delete(meta, @subscription_id)

        params =
          if meta == %{}, do: Map.delete(params, "_meta"), else: %{params | "_meta" => meta}

        {:route, params, data, []}

      :error ->
        {:handled, data, []}
    end
  end

  def notification(_method, params, data, _state), do: {:route, params, data, []}

  defp acknowledged(id, params, data, state) do
    acked =
      case params do
        %{"notifications" => %{} = honoured} -> honoured
        _other -> %{}
      end

    listen = %{Map.fetch!(data.listen.listens, id) | status: :active, acked: acked}
    data = put(data, listens: Map.put(data.listen.listens, id, listen), attempt: 0)

    # Make-before-break: the old listen goes only now.
    data =
      case data.listen.active do
        nil -> data
        ^id -> data
        old -> data |> cancel(old) |> put(listens: Map.delete(data.listen.listens, old))
      end

    data = put(data, active: id)
    data = settle(data, listen.filter, acked)
    sync(data, state)
  end

  # Answers the callers whose change `filter` (as acknowledged) carries.
  defp settle(data, filter, acked \\ nil) do
    requested = Map.get(filter, "resourceSubscriptions", [])
    honoured = if acked, do: List.wrap(acked["resourceSubscriptions"]), else: requested

    {done, waiting} =
      Enum.split_with(data.listen.waiters, fn
        {_mref, :subscribe, uri} -> uri in requested
        {_mref, :unsubscribe, uri} -> uri not in requested
      end)

    data =
      Enum.reduce(done, put(data, waiters: waiting), fn
        {mref, :subscribe, uri} = waiter, data ->
          if uri in honoured do
            Requests.reply(mref, :ok)
            data
          else
            fail_waiters(data, [waiter], Error.new(:protocol, :subscription_not_acknowledged))
          end

        {mref, :unsubscribe, _uri}, data ->
          Requests.reply(mref, :ok)
          data
      end)

    data
  end

  # --- endings -----------------------------------------------------------------------

  @doc """
  Listen `id` ended: `{:response, message}` (the server's result, or a
  JSON-RPC error) or `{:error, reason}` (the stream dropped or failed).
  """
  @spec ended(pos_integer(), {:response, map()} | {:error, term()}, Data.t()) :: result()
  def ended(id, outcome, data) do
    data = %{data | internal: Map.delete(data.internal, id)}

    case Map.pop(data.listen.listens, id) do
      {nil, _listens} ->
        {data, []}

      {listen, listens} ->
        data = put(data, listens: listens)
        current? = data.listen.active == id or listen.status == :pending
        data = if data.listen.active == id, do: put(data, active: nil), else: data

        if current?, do: after_end(listen, outcome, data), else: {data, []}
    end
  end

  # A server that answers listen with an error does not support it: stop
  # until the next handshake.
  defp after_end(listen, {:response, %{"error" => error}}, data) do
    Logger.debug("MCP server refused subscriptions/listen", code: inspect(error["code"]))
    error = Error.from_rpc_error(error)

    data =
      if listen.status == :pending, do: fail_waiters(data, data.listen.waiters, error), else: data

    {put(data, off?: true), []}
  end

  # Graceful end (server shutdown, idle, token expiry): reopen.
  defp after_end(_listen, {:response, _message}, data), do: reopen_later(data)

  # A drop: notifications may have been missed.
  defp after_end(listen, {:error, reason}, data) do
    Cache.mark_all_stale(data.cache)

    data =
      if listen.status == :pending,
        do: fail_waiters(data, data.listen.waiters, Error.new(:transport, tag(reason))),
        else: data

    reopen_later(data)
  end

  defp tag(%Error{reason: reason}) when is_atom(reason) and reason != nil, do: reason
  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp tag(_reason), do: :listen_failed

  defp reopen_later(data) do
    attempt = data.listen.attempt + 1
    delay = data.config.backoff.(attempt)
    {put(data, attempt: attempt), [{{:timeout, :listen}, delay, nil}]}
  end

  # --- resource subscriptions -----------------------------------------------------------

  @doc """
  `ConduitMcp.Client.subscribe/2` (`op` `:subscribe`) or `unsubscribe/2`
  (`:unsubscribe`) in a ready connection. The caller (`mref`) is answered
  when the server confirms.
  """
  @spec change(:subscribe | :unsubscribe, String.t(), reference(), Data.t()) :: result()
  def change(op, uri, mref, %Data{era: :legacy} = data), do: legacy_change(op, uri, mref, data)

  def change(op, uri, mref, data) do
    subs = apply_op(data.listen.subs, op, uri)
    waiters = [{mref, op, uri} | data.listen.waiters]
    data = put(data, subs: subs, waiters: waiters)

    if data.listen.off? do
      {fail_waiters(data, [{mref, op, uri}], Error.new(:protocol, :listen_not_supported)), []}
    else
      sync(data, :ready)
    end
  end

  defp apply_op(subs, :subscribe, uri), do: MapSet.put(subs, uri)
  defp apply_op(subs, :unsubscribe, uri), do: MapSet.delete(subs, uri)

  defp undo(subs, :subscribe, uri), do: MapSet.delete(subs, uri)
  defp undo(subs, :unsubscribe, uri), do: MapSet.put(subs, uri)

  defp fail_waiters(data, waiters, error) do
    Enum.reduce(waiters, data, fn {mref, op, uri} = waiter, data ->
      Requests.reply(mref, {:error, error})

      put(data,
        subs: undo(data.listen.subs, op, uri),
        waiters: List.delete(data.listen.waiters, waiter)
      )
    end)
  end

  defp legacy_change(op, uri, mref, data) do
    subscribed? = MapSet.member?(data.listen.subs, uri)

    cond do
      op == :subscribe and subscribed? ->
        Requests.reply(mref, :ok)
        {data, []}

      op == :unsubscribe and not subscribed? ->
        Requests.reply(mref, :ok)
        {data, []}

      not legacy_subscribe?(data) ->
        Requests.reply(mref, {:error, Error.new(:protocol, :subscriptions_not_supported)})
        {data, []}

      true ->
        method = if op == :subscribe, do: "resources/subscribe", else: "resources/unsubscribe"
        legacy_send(data, method, uri, {:resource, op, mref, uri})
    end
  end

  defp legacy_subscribe?(%Data{
         server: %{capabilities: %{"resources" => %{"subscribe" => true}}}
       }),
       do: true

  defp legacy_subscribe?(_data), do: false

  defp legacy_send(data, method, uri, purpose) do
    {id, data} = Data.take_id(data)

    case Data.send_request(data, id, method, %{"uri" => uri}, %{}, nil, []) do
      {:ok, _handle, data} ->
        {%{data | internal: Map.put(data.internal, id, purpose)}, []}

      {:error, reason, data} ->
        reply_purpose(purpose, {:error, Error.new(:transport, reason)})
        {data, []}
    end
  end

  # Every desired URI again, for a new legacy session (fire and forget).
  defp resubscribe(data) do
    if legacy_subscribe?(data) do
      Enum.reduce(data.listen.subs, data, fn uri, data ->
        {data, []} = legacy_send(data, "resources/subscribe", uri, :resubscribe)
        data
      end)
    else
      data
    end
  end

  @doc """
  The outcome of a legacy `resources/(un)subscribe` the connection sent for
  `purpose`: `{:response, message}` or `{:error, reason}`.
  """
  @spec legacy_done(term(), {:response, map()} | {:error, term()}, Data.t()) :: Data.t()
  def legacy_done({:resource, op, _mref, uri} = purpose, {:response, %{"result" => _}}, data) do
    reply_purpose(purpose, :ok)
    put(data, subs: apply_op(data.listen.subs, op, uri))
  end

  def legacy_done(purpose, {:response, %{"error" => error}}, data) do
    reply_purpose(purpose, {:error, Error.from_rpc_error(error)})
    data
  end

  def legacy_done(purpose, {:response, _invalid}, data) do
    reply_purpose(purpose, {:error, Error.new(:protocol, :invalid_response)})
    data
  end

  def legacy_done(purpose, {:error, %Error{} = error}, data) do
    reply_purpose(purpose, {:error, error})
    data
  end

  def legacy_done(purpose, {:error, reason}, data) do
    reply_purpose(purpose, {:error, Error.new(:transport, reason)})
    data
  end

  defp reply_purpose({:resource, _op, mref, _uri}, reply), do: Requests.reply(mref, reply)
  defp reply_purpose(:resubscribe, _reply), do: :ok
end

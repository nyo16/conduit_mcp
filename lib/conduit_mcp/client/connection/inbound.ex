defmodule ConduitMcp.Client.Connection.Inbound do
  @moduledoc false

  # What the server sends on its own: notifications (progress routing,
  # `list_changed` coalescing, fan-out to subscribers) and legacy
  # server-to-client requests. Nothing here runs user code: subscribers get
  # messages, and handler callbacks never run in the connection.

  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Protocol

  @list_changed [
    "notifications/tools/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/list_changed"
  ]

  # A burst of one `list_changed` kind inside this window reaches subscribers
  # at most twice: once at its start, once at its end.
  @window_ms 250

  @doc "The coalescing window of `list_changed` notifications, in ms."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "A server notification."
  @spec notification(term(), term(), Data.t()) :: Requests.result()
  def notification(method, params, data) do
    Telemetry.notification(Data.telemetry(data), method)
    params = if is_map(params), do: params, else: %{}
    route(method, params, data)
  end

  defp route("notifications/progress", params, data), do: Requests.progress(params, data)

  # Cancels a server-to-client request; none runs inside the connection.
  defp route("notifications/cancelled", _params, data), do: {data, []}

  defp route(method, params, data) when method in @list_changed do
    case Map.get(data.coalesce, method) do
      nil ->
        fan_out(data, method, params)
        {put_coalesce(data, method, :quiet), [window(method)]}

      _quiet_or_again ->
        {put_coalesce(data, method, {:again, params}), []}
    end
  end

  defp route(method, params, data) when is_binary(method) do
    fan_out(data, method, params)
    {data, []}
  end

  defp route(_method, _params, data), do: {data, []}

  @doc """
  The coalescing window of `method` ended: one trailing notification if any
  arrived during it (and a new window), else the burst is over.
  """
  @spec window_end(String.t(), Data.t()) :: Requests.result()
  def window_end(method, data) do
    case Map.get(data.coalesce, method) do
      {:again, params} ->
        fan_out(data, method, params)
        {put_coalesce(data, method, :quiet), [window(method)]}

      _quiet ->
        {%{data | coalesce: Map.delete(data.coalesce, method)}, []}
    end
  end

  defp put_coalesce(data, method, value),
    do: %{data | coalesce: Map.put(data.coalesce, method, value)}

  defp window(method), do: {{:timeout, {:list_changed, method}}, @window_ms, nil}

  defp fan_out(data, method, params) do
    for {_ref, pid} <- data.subscribers,
        do: send(pid, {:mcp_notification, data.name, method, params})

    :ok
  end

  @doc "Adds `pid` to the notification subscribers (idempotent)."
  @spec subscribe(pid(), Data.t()) :: Data.t()
  def subscribe(pid, data) do
    if pid in Map.values(data.subscribers) do
      data
    else
      %{data | subscribers: Map.put(data.subscribers, Process.monitor(pid), pid)}
    end
  end

  @doc "Removes `pid` from the notification subscribers."
  @spec unsubscribe(pid(), Data.t()) :: Data.t()
  def unsubscribe(pid, data) do
    {gone, kept} = Enum.split_with(data.subscribers, fn {_ref, sub} -> sub == pid end)
    Enum.each(gone, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
    %{data | subscribers: Map.new(kept)}
  end

  @doc "A monitored subscriber exited. `:unknown` when `ref` is not one."
  @spec subscriber_down(reference(), Data.t()) :: Data.t() | :unknown
  def subscriber_down(ref, data) do
    case Map.pop(data.subscribers, ref) do
      {nil, _subscribers} -> :unknown
      {_pid, subscribers} -> %{data | subscribers: subscribers}
    end
  end

  @doc """
  A legacy server-to-client request: `ping` is answered `{}`; any other
  method is answered `-32601`.
  """
  @spec server_request(term(), term(), Data.t()) :: Data.t()
  def server_request(id, %{"method" => "ping"}, data),
    do: Data.respond(data, Protocol.success_response(id, %{}))

  def server_request(id, message, data) do
    method = if is_map(message), do: Map.get(message, "method")

    Data.respond(
      data,
      Protocol.error_response(
        id,
        Protocol.method_not_found(),
        "Method not found: #{ConduitMcp.Reflect.text(method, 64)}"
      )
    )
  end
end

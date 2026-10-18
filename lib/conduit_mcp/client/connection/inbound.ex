defmodule ConduitMcp.Client.Connection.Inbound do
  @moduledoc false

  # What the server sends on its own: notifications (progress routing,
  # cancellation of server requests, `list_changed` coalescing and cache
  # refresh, log entries sanitized and rate limited, fan-out to subscribers
  # and to the handler's notifier). Nothing here runs user code: subscribers
  # get messages, and handler callbacks never run in the connection.

  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Notifier
  alias ConduitMcp.Client.Connection.Refresh
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Connection.ServerRequests
  alias ConduitMcp.Client.RateLimit
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Reflect

  @list_changed [
    "notifications/tools/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/list_changed"
  ]

  # A burst of one `list_changed` kind inside this window reaches subscribers
  # at most twice: once at its start, once at its end.
  @window_ms 250

  # `notifications/message` (TL-3): the RFC 5424 levels; anything else is
  # reported as "info". Strings in `logger` and `data` go through
  # `ConduitMcp.Reflect.text/2` (no control, bidi or line-separator
  # characters, clamped), and `data` is cut below a nesting depth.
  @log_levels ~w(debug info notice warning error critical alert emergency)
  @log_default_level "info"
  @log_max_chars 4_096
  @log_max_logger_chars 200
  @log_max_depth 16

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

  # Cancels a legacy server-to-client request whose handler is running.
  defp route("notifications/cancelled", params, data), do: ServerRequests.cancelled(params, data)

  defp route("notifications/message", params, data) do
    case RateLimit.check(data.log.limiter) do
      :ok -> fan_out(data, "notifications/message", sanitize_log(params))
      :rate_limited -> Telemetry.log_dropped(Data.telemetry(data))
    end

    {data, []}
  end

  defp route(method, params, data) when method in @list_changed do
    case Map.get(data.coalesce, method) do
      nil ->
        data = deliver_list_changed(data, method, params)
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
        data = deliver_list_changed(data, method, params)
        {put_coalesce(data, method, :quiet), [window(method)]}

      _quiet ->
        {%{data | coalesce: Map.delete(data.coalesce, method)}, []}
    end
  end

  # Each delivered `list_changed` also invalidates (and refreshes) the cache.
  defp deliver_list_changed(data, method, params) do
    fan_out(data, method, params)
    Refresh.list_changed(method, data)
  end

  defp put_coalesce(data, method, value),
    do: %{data | coalesce: Map.put(data.coalesce, method, value)}

  defp window(method), do: {{:timeout, {:list_changed, method}}, @window_ms, nil}

  defp sanitize_log(params) do
    %{"level" => log_level(Map.get(params, "level"))}
    |> put_sanitized(
      "logger",
      Map.get(params, "logger"),
      &Reflect.text(&1, @log_max_logger_chars)
    )
    |> put_sanitized("data", Map.get(params, "data"), &log_data(&1, @log_max_depth))
  end

  defp log_level(level) when is_binary(level) do
    level = level |> Reflect.text(16) |> String.downcase()
    if level in @log_levels, do: level, else: @log_default_level
  end

  defp log_level(_level), do: @log_default_level

  defp put_sanitized(map, _key, nil, _fun), do: map
  defp put_sanitized(map, key, value, fun), do: Map.put(map, key, fun.(value))

  defp log_data(_value, 0), do: nil
  defp log_data(value, _depth) when is_binary(value), do: Reflect.text(value, @log_max_chars)

  defp log_data(value, depth) when is_map(value),
    do: Map.new(value, fn {k, v} -> {log_key(k), log_data(v, depth - 1)} end)

  defp log_data(value, depth) when is_list(value), do: Enum.map(value, &log_data(&1, depth - 1))
  defp log_data(value, _depth) when is_number(value) or is_boolean(value), do: value
  defp log_data(_value, _depth), do: nil

  defp log_key(key), do: Reflect.text(key, @log_max_logger_chars)

  defp fan_out(data, method, params) do
    for {_ref, pid} <- data.subscribers,
        do: send(pid, {:mcp_notification, data.config.name, method, params})

    Notifier.notify(data.notifier, method, params, data.era)
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
end

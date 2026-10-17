defmodule ConduitMcp.Client.Connection.ServerRequests do
  @moduledoc false

  # Legacy server-to-client requests. The connection only decides and
  # routes; the `ConduitMcp.Client.Handler` callback runs in a task under the
  # client's `Task.Supervisor` (`ConduitMcp.Client.Input.answer/3`), and the
  # answer comes back here to be sent through `transport.respond/2`.
  #
  #   * `ping` is answered `{}` at once.
  #   * A method whose capability the client did not declare gets `-32601`.
  #   * Beyond `:max_server_requests` running at once: `-32000` (busy).
  #   * The task is killed after `:handler_timeout` (per method) and the
  #     server gets `-32603`; a crash also answers `-32603`.
  #   * A server `notifications/cancelled` for the request kills the task and
  #     nothing is sent.
  #   * While it runs, the deadline of the related client request is paused
  #     (`ConduitMcp.Client.Connection.Requests.pause/2`). A transport that
  #     cannot tell the related request (stdio) gives `nil`; the request is
  #     then attributed to the one call in flight, if exactly one is.
  #
  # Reconnecting kills every handler task without answering: the transport
  # that carried the requests is gone.

  alias ConduitMcp.Client.Connection.Data
  alias ConduitMcp.Client.Connection.Requests
  alias ConduitMcp.Client.Input
  alias ConduitMcp.Protocol
  alias ConduitMcp.Reflect

  @server_error ConduitMcp.Errors.server_error()
  @internal_error ConduitMcp.Errors.internal_error()
  @method_not_found ConduitMcp.Errors.method_not_found()
  @invalid_request ConduitMcp.Errors.invalid_request()

  @doc "A `{:server_request, id, message, related}` transport event."
  @spec start(term(), term(), term(), Data.t()) :: Requests.result()
  def start(id, %{"method" => "ping"}, _related, data),
    do: {Data.respond(data, Protocol.success_response(id, %{})), []}

  def start(id, message, related, data) do
    method = if is_map(message), do: Map.get(message, "method")

    cond do
      not declared?(method, data) ->
        {error(data, id, @method_not_found, "Method not found: #{Reflect.text(method, 64)}"), []}

      Map.has_key?(data.server_requests, id) ->
        {error(data, id, @invalid_request, "Duplicate request id"), []}

      map_size(data.server_requests) >= data.config.max_server_requests ->
        {error(data, id, @server_error, "Client busy: too many server requests"), []}

      true ->
        spawn_handler(id, method, Map.get(message, "params"), related, data)
    end
  end

  defp declared?(method, data) do
    case Input.capability(method) do
      {:ok, capability} -> Map.has_key?(Data.client_capabilities(data, :legacy), capability)
      :error -> false
    end
  end

  defp spawn_handler(id, method, params, related, data) do
    related = attribute(related, data)

    env =
      Input.env(data.input, %{
        client: data.config.name,
        server_id: data.config.server_id,
        era: data.era || :legacy,
        assigns: (related && Requests.assigns(data, related)) || data.input.assigns,
        related_request_id: related,
        idle?: related == nil and map_size(data.pending) == 0,
        origin: data.config.elicitation[:origin] || data.origin
      })

    task = Task.Supervisor.async_nolink(data.task_sup, Input, :answer, [method, params, env])

    entry = %{ref: task.ref, pid: task.pid, related: related}
    data = %{data | server_requests: Map.put(data.server_requests, id, entry)}

    {data, actions} = Requests.pause(data, related)
    timeout = Input.timeout(method, data.config.handler_timeout)
    {data, [{{:timeout, {:server_request, id}}, timeout, id} | actions]}
  end

  defp attribute(nil, %Data{pending: pending}) when map_size(pending) == 1,
    do: pending |> Map.keys() |> hd()

  defp attribute(related, _data), do: related

  @doc "The handler task of server request `id` answered."
  @spec reply(term(), reference(), term(), Data.t()) :: Requests.result()
  def reply(id, ref, answer, data) do
    Process.demonitor(ref, [:flush])

    finish(id, data, fn data ->
      case answer do
        {:ok, result} ->
          Data.respond(data, Protocol.success_response(id, result))

        {:error, %{"code" => code, "message" => message} = error} ->
          Data.respond(data, Protocol.error_response(id, code, message, error["data"]))
      end
    end)
  end

  @doc "The handler task of server request `id` exited without answering."
  @spec down(term(), Data.t()) :: Requests.result()
  def down(id, data),
    do: finish(id, data, &error(&1, id, @internal_error, "Client handler failed"))

  @doc "`:handler_timeout` passed for server request `id`."
  @spec timeout(term(), Data.t()) :: Requests.result()
  def timeout(id, data) do
    case Map.fetch(data.server_requests, id) do
      {:ok, entry} ->
        kill(data, entry)
        finish(id, data, &error(&1, id, @internal_error, "Client handler timed out"))

      :error ->
        {data, []}
    end
  end

  @doc "A server `notifications/cancelled`: kill the handler, answer nothing."
  @spec cancelled(map(), Data.t()) :: Requests.result()
  def cancelled(%{"requestId" => id}, data) do
    case Map.fetch(data.server_requests, id) do
      {:ok, entry} ->
        kill(data, entry)
        finish(id, data, & &1)

      :error ->
        {data, []}
    end
  end

  def cancelled(_params, data), do: {data, []}

  @doc "Kills every handler task without answering (the transport is gone)."
  @spec stop_all(Data.t()) :: {Data.t(), [:gen_statem.action()]}
  def stop_all(data) do
    actions =
      for {id, entry} <- data.server_requests do
        kill(data, entry)
        cancel_timer(id)
      end

    {%{data | server_requests: %{}}, actions}
  end

  defp kill(data, entry) do
    _ = Task.Supervisor.terminate_child(data.task_sup, entry.pid)
    Process.demonitor(entry.ref, [:flush])
    :ok
  end

  defp finish(id, data, respond) do
    {entry, server_requests} = Map.pop(data.server_requests, id)
    data = respond.(%{data | server_requests: server_requests})
    {data, actions} = Requests.resume(data, entry.related)
    {data, [cancel_timer(id) | actions]}
  end

  defp error(data, id, code, message),
    do: Data.respond(data, Protocol.error_response(id, code, message))

  defp cancel_timer(id), do: {{:timeout, {:server_request, id}}, :cancel}
end

defmodule ConduitMcp.Client.Transport.InProcess do
  @moduledoc """
  A `ConduitMcp.Client.Transport` that serves requests from a server module
  in the same VM, for tests and development.

      {ConduitMcp.Client,
       name: :local,
       transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.MCPServer}}

  Each request runs `ConduitMcp.Handler.dispatch/3` against the server
  module, which classifies its era (`ConduitMcp.Era.classify/2`) exactly as
  the HTTP transports do, in its own task under the client's
  `Task.Supervisor`; the result comes back to the connection as a
  transport event. The server module (`dsl: false`, DSL or
  `ConduitMcp.Endpoint`) is the one you would mount behind
  `ConduitMcp.Transport.StreamableHTTP`; no HTTP stack, socket or optional
  dependency is involved.

  There are no sessions and no HTTP headers, so plugs (authentication, rate
  limiting, `ConduitMcp.Plugs.HeaderValidation`) do not run. Give the
  server a caller identity with `:principal` instead.

  Cancelling a request terminates its task. The server never sends
  server-to-client requests over this transport.

  ## Options

    * `:server` (required) - the server module.
    * `:assigns` - `conn.assigns` for every request (default `%{}`).
    * `:principal` - a `ConduitMcp.Principal` map put on every request's
      conn with `ConduitMcp.Principal.put/2` (default: none).
    * `:remote_ip` - the conn's `remote_ip` (default `{127, 0, 0, 1}`).
    * `:server_name`, `:server_version`, `:instructions` - as for
      `ConduitMcp.Transport.StreamableHTTP` (an Endpoint's `:name` and
      `:version` are used when unset).
  """

  @behaviour ConduitMcp.Client.Transport

  alias ConduitMcp.Handler
  alias ConduitMcp.Principal
  alias ConduitMcp.Protocol
  alias ConduitMcp.Transport.Shared

  @schema NimbleOptions.new!(
            server: [type: :atom, required: true],
            assigns: [type: :map, default: %{}],
            principal: [type: {:or, [:map, nil]}, default: nil],
            remote_ip: [type: :any, default: {127, 0, 0, 1}],
            server_name: [type: {:or, [:string, nil]}, default: nil],
            server_version: [type: {:or, [:string, nil]}, default: nil],
            instructions: [type: {:or, [:string, nil]}, default: nil]
          )

  @impl true
  def kind, do: :in_process

  @impl true
  def init(opts, %{owner: owner, task_sup: task_sup}) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         :ok <- check_server(opts[:server]) do
      {:ok,
       %{
         server: opts[:server],
         conn: build_conn(opts),
         owner: owner,
         task_sup: task_sup,
         ref: make_ref(),
         # task monitor ref => request id (or :notification)
         tasks: %{}
       }}
    end
  end

  defp check_server(server) do
    if Code.ensure_loaded?(server) and function_exported?(server, :handle_list_tools, 1),
      do: :ok,
      else: {:error, {:not_a_server_module, server}}
  end

  defp build_conn(opts) do
    endpoint = Shared.endpoint_config(opts[:server])

    conn = %Plug.Conn{
      remote_ip: opts[:remote_ip],
      assigns: opts[:assigns],
      private: %{
        server_module: opts[:server],
        server_name: opts[:server_name] || Keyword.get(endpoint, :name),
        server_version: opts[:server_version] || Keyword.get(endpoint, :version),
        instructions: opts[:instructions]
      }
    }

    case opts[:principal] do
      nil -> conn
      principal -> Principal.put(conn, principal)
    end
  end

  @impl true
  def connect(state) do
    send(state.owner, {__MODULE__, state.ref, :connected})
    {:ok, state}
  end

  @impl true
  def request(state, %{"id" => id} = message, _reply_to, _wire_opts) do
    task = run(state, message)
    {:ok, task.pid, %{state | tasks: Map.put(state.tasks, task.ref, {id, task.pid})}}
  end

  @impl true
  def notify(state, message) do
    task = run(state, message)
    {:ok, %{state | tasks: Map.put(state.tasks, task.ref, {:notification, task.pid})}}
  end

  defp run(%{server: server, conn: conn, task_sup: task_sup}, message),
    do: Task.Supervisor.async_nolink(task_sup, fn -> Handler.dispatch(message, server, conn) end)

  @impl true
  def cancel(state, id, _handle, _reason) do
    case Enum.find(state.tasks, fn {_ref, {task_id, _pid}} -> task_id == id end) do
      {ref, {_id, pid}} ->
        stop_task(state.task_sup, ref, pid)
        {:ok, %{state | tasks: Map.delete(state.tasks, ref)}}

      nil ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info({__MODULE__, ref, :connected}, %{ref: ref} = state),
    do: {:ok, [{:connected, %{}}], state}

  def handle_info({ref, reply}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {{id, _pid}, tasks} = Map.pop(tasks, ref)
    {:ok, reply_events(id, reply), %{state | tasks: tasks}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {{id, _pid}, tasks} = Map.pop(tasks, ref)

    events =
      if id == :notification, do: [], else: [{:exchange_done, id, {:error, :server_exited}}]

    {:ok, events, %{state | tasks: tasks}}
  end

  def handle_info(_message, _state), do: :unknown

  defp reply_events(:notification, _reply), do: []
  defp reply_events(id, {:reply, response}), do: [{:response, id, response}]

  defp reply_events(id, {:stream, _spec}),
    do: [
      {:response, id,
       Protocol.error_response(
         id,
         Protocol.method_not_found(),
         "Method not found: needs a streaming transport"
       )}
    ]

  defp reply_events(id, :noreply), do: [{:exchange_done, id, {:error, :no_response}}]

  @impl true
  def close(state, _reason) do
    Enum.each(state.tasks, fn {ref, {_id, pid}} -> stop_task(state.task_sup, ref, pid) end)
  end

  defp stop_task(task_sup, ref, pid) do
    Process.demonitor(ref, [:flush])
    _ = Task.Supervisor.terminate_child(task_sup, pid)
    :ok
  end
end

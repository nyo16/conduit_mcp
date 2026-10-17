defmodule ConduitMcp.Test.Client.FakeTransport do
  @moduledoc """
  A `ConduitMcp.Client.Transport` driven by the test process, which plays
  the server.

  Every callback sends `{:fake_transport, connection_pid, call}` to the
  `:test_pid` option, where `call` is one of:

    * `{:init, opts}`, `:connect`, `{:close, reason}`
    * `{:request, message, wire_opts}` - `message` is the JSON-RPC request
    * `{:notify, message}`, `{:respond, message}`
    * `{:cancel, id, handle, reason}`
    * `{:set_session, %{era: era, version: version}}`

  The test answers with `push/2`, which injects one transport event
  (`{:connected, info}`, `{:response, id, message}`,
  `{:notification, method, params}`, `{:closed, reason}`, ...) into the
  connection. `kind/0` is `:stdio`, so era probing follows the stdio rules.

  ## Options

    * `:test_pid` (required) - receives the reports.
    * `:auto_connect` - report `{:connected, %{}}` right after `connect/1`
      (default `false`).
  """

  @behaviour ConduitMcp.Client.Transport

  @impl true
  def kind, do: :stdio

  @impl true
  def init(opts, %{owner: owner}) do
    state = %{
      test_pid: Keyword.fetch!(opts, :test_pid),
      owner: owner,
      auto_connect: Keyword.get(opts, :auto_connect, false),
      # Kept so crash-report redaction is observable (`format_status/1`).
      opts: opts
    }

    report(state, {:init, Keyword.delete(opts, :test_pid)})
    {:ok, state}
  end

  @impl true
  def connect(state) do
    report(state, :connect)
    if state.auto_connect, do: send(state.owner, {__MODULE__, :event, {:connected, %{}}})
    {:ok, state}
  end

  @impl true
  def request(state, message, _reply_to, wire_opts) do
    report(state, {:request, message, wire_opts})
    {:ok, {:fake_handle, message["id"]}, state}
  end

  @impl true
  def notify(state, message) do
    report(state, {:notify, message})
    {:ok, state}
  end

  @impl true
  def respond(state, message) do
    report(state, {:respond, message})
    {:ok, state}
  end

  @impl true
  def cancel(state, id, handle, reason) do
    report(state, {:cancel, id, handle, reason})
    {:ok, state}
  end

  @impl true
  def set_session(state, session) do
    report(state, {:set_session, session})
    state
  end

  @impl true
  def handle_info({__MODULE__, :event, event}, state), do: {:ok, [event], state}
  def handle_info(_message, _state), do: :unknown

  @impl true
  def close(state, reason) do
    report(state, {:close, reason})
    :ok
  end

  @doc "Injects transport `event` into the connection `conn` (a pid)."
  def push(conn, event) when is_pid(conn), do: send(conn, {__MODULE__, :event, event})

  defp report(state, call), do: send(state.test_pid, {:fake_transport, state.owner, call})
end

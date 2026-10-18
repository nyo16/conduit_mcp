defmodule ConduitMcp.Test.Client.Harness do
  @moduledoc """
  Helpers for client tests where the test process plays the server through
  `ConduitMcp.Test.Client.FakeTransport`. Import it in an `async: true` test
  module; every helper runs in the test process.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.TelemetryTestHelper
  alias ConduitMcp.Test.Client.FakeTransport

  @modern "2026-07-28"
  @legacy "2025-11-25"

  @doc "Starts a client on the fake transport; returns the connection pid."
  def start_client(name, opts \\ []) do
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])
    {transport, opts} = Keyword.pop(opts, :transport, FakeTransport)

    defaults = [
      name: name,
      transport: {transport, [test_pid: self()] ++ transport_opts},
      backoff: fn _attempt -> 0 end
    ]

    start_supervised!({Client, Keyword.merge(defaults, opts)})
    assert_receive {:fake_transport, conn, :connect}
    conn
  end

  @doc "A modern `server/discover` result advertising `capabilities`."
  def discover_result(capabilities \\ %{"tools" => %{"listChanged" => true}}) do
    %{
      "resultType" => "complete",
      "supportedVersions" => [@modern],
      "capabilities" => capabilities,
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "fake", "version" => "1.0"}
      }
    }
  end

  @doc "Connects and answers the modern handshake."
  def ready_modern(name, conn, capabilities \\ %{"tools" => %{"listChanged" => true}}) do
    FakeTransport.push(conn, {:connected, %{}})
    {id, _message, _opts} = expect_request(conn, "server/discover")
    reply(conn, id, discover_result(capabilities))
    assert :ok = Client.await_ready(name)
  end

  @doc "Connects and answers the legacy handshake."
  def ready_legacy(name, conn, capabilities \\ %{"tools" => %{}}) do
    FakeTransport.push(conn, {:connected, %{}})
    {id, _message, _opts} = expect_request(conn, "initialize")

    reply(conn, id, %{
      "protocolVersion" => @legacy,
      "capabilities" => capabilities,
      "serverInfo" => %{"name" => "old", "version" => "0.1"}
    })

    assert_receive {:fake_transport, ^conn, {:notify, %{"method" => "notifications/initialized"}}}
    assert :ok = Client.await_ready(name)
  end

  @doc "Answers request `id` with `result`."
  def reply(conn, id, result) do
    FakeTransport.push(
      conn,
      {:response, id, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
    )
  end

  @doc "Answers request `id` with a JSON-RPC error."
  def reply_error(conn, id, code, message \\ "nope") do
    error = %{"code" => code, "message" => message}
    FakeTransport.push(conn, {:response, id, %{"jsonrpc" => "2.0", "id" => id, "error" => error}})
  end

  @doc "Waits for a request with `method`; returns `{id, message, wire_opts}`."
  def expect_request(conn, method, timeout \\ 1_000) do
    assert_receive {:fake_transport, ^conn,
                    {:request, %{"method" => ^method, "id" => id} = message, wire_opts}},
                   timeout

    {id, message, wire_opts}
  end

  @doc "Attaches telemetry for `events` emitted for client `name` (any process)."
  def attach(name, events),
    do: TelemetryTestHelper.attach_event_handlers(self(), events, match: %{client: name})

  @doc "The connection's state data."
  def state(conn) do
    {_state, data} = :sys.get_state(conn)
    data
  end

  @doc """
  Retries a check until it holds, for at most 2 s (a deadline rather than
  an attempt count, so a loaded runner that schedules the other process
  late does not fail the test). Sleeps 5 ms between attempts so the
  poller does not hold a scheduler the awaited process needs.
  """
  def eventually(fun, timeout_ms \\ 2_000),
    do: eventually_until(fun, System.monotonic_time(:millisecond) + timeout_ms)

  defp eventually_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never held")

      true ->
        receive do
        after
          5 -> :ok
        end

        eventually_until(fun, deadline)
    end
  end

  @doc """
  Waits until `hub` reports each of `ids` `:ready` (`ConduitMcp.Client.Hub.status/1`).

  A server's client can be ready before the hub's manager has recorded it
  as running (the record is written once `start_child` returns), and
  `Hub.list_tools/2` and `Hub.call_tool/4` only use running servers, so
  waiting on `ConduitMcp.Client.await_ready/2` alone races the manager.
  """
  def await_hub_ready(hub, ids, timeout_ms \\ 5_000) do
    eventually(
      fn ->
        {:ok, statuses} = ConduitMcp.Client.Hub.status(hub)
        ready = for %{id: id, state: :ready} <- statuses, do: id
        Enum.all?(ids, &(&1 in ready))
      end,
      timeout_ms
    )
  end

  @doc "Nothing outlives a test: no pending request, monitor, server request or task."
  def assert_no_leaks(name, conn) do
    data = state(conn)
    assert data.pending == %{}
    assert data.refs == %{}
    assert data.server_requests == %{}
    assert data.refreshes == %{}

    {:ok, task_sup, _value} = Registry.lookup({:task_sup, name})

    for pid <- Task.Supervisor.children(task_sup) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    assert Task.Supervisor.children(task_sup) == []
  end
end

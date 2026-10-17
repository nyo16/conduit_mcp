defmodule ConduitMcp.Test.Client.HTTPServers do
  @moduledoc """
  Real HTTP servers for the Streamable HTTP client tests: Bandit on port 0
  (`ip: :loopback`) serving a plug, plus this library's own server modules
  (`HTTPDslServer`, `HTTPEndpointServer`) with tools the integration tests
  need. Call the helpers from the test process (`start_supervised!/1`).

  Tools reach the test process through `register_test/0`: the test passes
  the returned key as the `"test"` argument and the tool looks the pid up.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  @doc "Starts Bandit on a free loopback port serving `plug`; returns `http://127.0.0.1:port/`."
  def serve(plug) do
    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: plug, port: 0, ip: :loopback, startup_log: false},
          id: make_ref()
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/"
  end

  @doc """
  Serves `server_module` with `ConduitMcp.Transport.StreamableHTTP`. The
  server notices a client that went away only when a write fails, so
  keep-alives come every 50 ms: an open listen or streamed response ends
  promptly when the test stops the client, instead of holding Bandit's
  shutdown.
  """
  def serve_mcp(server_module, opts \\ []) do
    defaults = [server_module: server_module, allowed_origins: "*", keep_alive_interval: 50]
    serve({ConduitMcp.Transport.StreamableHTTP, Keyword.merge(defaults, opts)})
  end

  @doc "A key under which a tool finds the calling test's pid."
  def register_test do
    key = "test-#{System.unique_integer([:positive])}"
    :persistent_term.put({__MODULE__, key}, self())
    on_exit(fn -> :persistent_term.erase({__MODULE__, key}) end)
    key
  end

  @doc "The pid registered under `key`."
  def test_pid(key), do: :persistent_term.get({__MODULE__, key})
end

defmodule ConduitMcp.Test.Client.HTTPDslServer do
  @moduledoc "A DSL server for the HTTP client integration tests."
  use ConduitMcp.Server

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Test.Client.HTTPServers

  tool "echo", "Echoes the message" do
    param(:message, :string, "Message", required: true)
    handle(fn _conn, %{"message" => message} -> text(message) end)
  end

  tool "region", "Echoes the region, mirrored into Mcp-Param-Region" do
    param(:region, :string, "Region", required: true, header: "Region")
    handle(fn _conn, %{"region" => region} -> text("region: " <> region) end)
  end

  tool "approve", "Answers after the user approves" do
    handle(fn conn, _params ->
      case conn.assigns[:mcp_input] do
        nil ->
          {:input_required,
           %{
             "ok" =>
               ConduitMcp.MRTR.elicit("Approve?", %{"type" => "object", "properties" => %{}})
           }, %{"step" => 1}}

        %{state: %{"step" => 1}, responses: %{"ok" => %{"action" => action}}} ->
          text("approval: " <> action)
      end
    end)
  end

  tool "progress", "Reports progress twice" do
    handle(fn conn, _params ->
      ConduitMcp.Progress.report(conn, 1, total: 2, message: "half")
      ConduitMcp.Progress.report(conn, 2, total: 2)
      text("done")
    end)
  end

  tool "slow", "Runs until cancelled, telling the test" do
    param(:test, :string, "Test key", required: true)

    handle(fn conn, %{"test" => key} ->
      test = HTTPServers.test_pid(key)
      send(test, {:slow_started, self()})
      wait_cancelled(conn, test)
    end)
  end

  resource "test://resource1" do
    description("Static resource")
    mime_type("text/plain")
    read(fn _conn, _params, _opts -> raw_resource("Test content", "text/plain") end)
  end

  defp wait_cancelled(conn, test) do
    if Cancellation.cancelled?(conn) do
      send(test, {:slow_saw_cancel, self()})
      text("cancelled")
    else
      receive do
      after
        5 -> wait_cancelled(conn, test)
      end
    end
  end
end

defmodule ConduitMcp.Test.Client.HTTPEchoTool do
  @moduledoc false
  use ConduitMcp.Component, type: :tool, name: "echo", description: "Echo back the input"

  schema do
    field(:message, :string, "Message", required: true)
  end

  @impl true
  def execute(%{message: msg}, _conn), do: text(msg)
end

defmodule ConduitMcp.Test.Client.HTTPEndpointServer do
  @moduledoc "An Endpoint server for the HTTP client integration tests."
  use ConduitMcp.Endpoint, name: "HTTP Endpoint", version: "1.0.0"

  component(ConduitMcp.Test.Client.HTTPEchoTool)
end

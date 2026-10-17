defmodule ConduitMcp.Client.HTTPIntegrationTest do
  # The client end to end over real sockets: `ConduitMcp.Client.Transport.
  # StreamableHTTP` (Finch) against this library's own
  # `ConduitMcp.Transport.StreamableHTTP` on Bandit port 0, in both eras.
  #
  # `async: false`: the listen test publishes through the node-wide
  # `ConduitMcp.Subscriptions` registry, which every open listen sees.
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.HTTPDslServer
  alias ConduitMcp.Test.Client.HTTPEndpointServer
  alias ConduitMcp.Test.Client.HTTPServers

  defmodule Approver do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "accept", "content" => %{}}}
  end

  setup do
    previous = Application.get_env(:conduit_mcp, :mrtr_keys)
    Application.put_env(:conduit_mcp, :mrtr_keys, [{"it", :crypto.strong_rand_bytes(32)}])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:conduit_mcp, :mrtr_keys, previous),
        else: Application.delete_env(:conduit_mcp, :mrtr_keys)
    end)
  end

  defp start_client(url, opts) do
    name = {__MODULE__, make_ref()}
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])

    start_supervised!(
      {Client,
       Keyword.merge(
         [
           name: name,
           transport: {StreamableHTTP, [url: url] ++ transport_opts},
           backoff: fn _attempt -> 0 end
         ],
         opts
       )}
    )

    name
  end

  defp ready(url, opts \\ []) do
    name = start_client(url, opts)
    assert :ok = Client.await_ready(name, 5_000)
    name
  end

  defp connection(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    conn
  end

  defp assert_no_leaks(name) do
    {_state, data} = :sys.get_state(connection(name))
    assert data.pending == %{}
    assert data.tstate.exchanges == %{}
  end

  @servers [
    {"manual (dsl: false)", ConduitMcp.TestServer},
    {"DSL", HTTPDslServer},
    {"Endpoint", HTTPEndpointServer}
  ]

  for {label, server} <- @servers, protocol <- [:auto, :modern, :legacy] do
    @server server
    @protocol protocol

    test "#{label} server over HTTP, protocol: #{inspect(protocol)}" do
      url = HTTPServers.serve_mcp(@server, session: [])
      name = ready(url, protocol: @protocol)
      era = if @protocol == :legacy, do: :legacy, else: :modern
      assert {:ok, ^era} = Client.era(name)
      assert :ok = Client.ping(name)

      assert {:ok, %{tools: tools, next_cursor: nil}} = Client.list_tools(name)
      assert %Tool{} = Enum.find(tools, &(&1.name == "echo"))

      assert {:ok, %ToolResult{is_error: false, content: [%{"text" => "hi"}]}} =
               Client.call_tool(name, "echo", %{"message" => "hi"})

      assert_no_leaks(name)
    end
  end

  test "modern discover reports the server and the origin" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url)

    assert {:ok, %{era: :modern, version: "2026-07-28", capabilities: caps}} =
             Client.server_info(name)

    assert is_map(caps["tools"])
  end

  test "Mcp-Param-* headers come from the cached tool and the final arguments" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url)
    assert {:ok, _tools} = Client.list_all_tools(name)

    assert {:ok, %ToolResult{content: [%{"text" => "region: eu-west"}]}} =
             Client.call_tool(name, "region", %{"region" => "eu-west"})

    # Atom keys and a value that needs the base64 sentinel.
    assert {:ok, %ToolResult{content: [%{"text" => "region: ünïcode"}]}} =
             Client.call_tool(name, "region", %{region: "ünïcode"})
  end

  test "a call made before the tools are cached refreshes them on -32020 and retries once" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url)

    assert {:ok, %ToolResult{content: [%{"text" => "region: ap"}]}} =
             Client.call_tool(name, "region", %{"region" => "ap"})
  end

  test "MRTR against a DSL tool answering input_required" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url, handler: Approver)

    assert {:ok, %ToolResult{content: [%{"text" => "approval: accept"}]}} =
             Client.call_tool(name, "approve", %{})
  end

  test "progress notifications stream to on_progress" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url)
    test = self()

    assert {:ok, %ToolResult{content: [%{"text" => "done"}]}} =
             Client.call_tool(name, "progress", %{}, on_progress: &send(test, {:progress, &1}))

    assert_received {:progress, %{"progress" => 1, "total" => 2, "message" => "half"}}
    assert_received {:progress, %{"progress" => 2}}
  end

  test "listen: notify_tools_changed refreshes the cached tools" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url)
    :ok = Client.subscribe_notifications(name)
    assert {:ok, _tools} = Client.list_all_tools(name)

    {_state, data} = :sys.get_state(connection(name))
    assert data.listen.active != nil or map_size(data.listen.listens) > 0
    wait_for_ack(name)

    ConduitMcp.notify_tools_changed()
    assert_receive {:mcp_notification, ^name, "notifications/tools/list_changed", params}, 2_000
    refute Map.has_key?(params, "_meta")
  end

  defp wait_for_ack(name, tries \\ 100) do
    {_state, data} = :sys.get_state(connection(name))

    cond do
      data.listen.active != nil ->
        :ok

      tries == 0 ->
        flunk("listen never acknowledged")

      true ->
        receive do
        after
          10 -> wait_for_ack(name, tries - 1)
        end
    end
  end

  test "modern subscribe/2: the listen filter carries the URI and updates arrive" do
    url = HTTPServers.serve_mcp(HTTPDslServer)
    name = ready(url)
    :ok = Client.subscribe_notifications(name)

    assert :ok = Client.subscribe(name, "test://resource1")
    {_state, data} = :sys.get_state(connection(name))
    active = Map.fetch!(data.listen.listens, data.listen.active)
    assert active.acked["resourceSubscriptions"] == ["test://resource1"]
    assert map_size(data.listen.listens) == 1

    ConduitMcp.notify_resource_updated("test://resource1")

    assert_receive {:mcp_notification, ^name, "notifications/resources/updated",
                    %{"uri" => "test://resource1"}},
                   2_000

    assert :ok = Client.unsubscribe(name, "test://resource1")
  end

  test "a bearer token is sent on every request; without it the server's 401 closes the client" do
    url = HTTPServers.serve_mcp(HTTPDslServer, auth: [strategy: :bearer_token, token: "t0k"])

    for protocol <- [:modern, :legacy] do
      name =
        ready(url,
          protocol: protocol,
          transport_opts: [auth: {:bearer, ConduitMcp.Client.Secret.new("t0k")}]
        )

      assert {:ok, %ToolResult{content: [%{"text" => "ok"}]}} =
               Client.call_tool(name, "echo", %{"message" => "ok"})
    end

    name = start_client(url, [])

    assert {:error, %Error{kind: :closed, data: %Error{kind: :auth}}} =
             Client.await_ready(name, 5_000)
  end

  test "legacy: initialize, session id, DELETE on close ends the server session" do
    url = HTTPServers.serve_mcp(HTTPDslServer, session: [])
    name = ready(url, protocol: :legacy)

    {_state, data} = :sys.get_state(connection(name))
    assert %ConduitMcp.Client.Secret{} = session = data.tstate.session
    sid = ConduitMcp.Client.Secret.expose(session)
    assert {:ok, _} = ConduitMcp.Session.EtsStore.get(sid)

    assert :ok = Client.close(name)
    assert {:error, _} = ConduitMcp.Session.EtsStore.get(sid)
  end

  test "cancel on timeout closes the stream: the slow tool sees the cancellation" do
    url = HTTPServers.serve_mcp(HTTPDslServer, keep_alive_interval: 20)
    name = ready(url)
    key = HTTPServers.register_test()

    assert {:error, %Error{kind: :timeout}} =
             Client.call_tool(name, "slow", %{"test" => key},
               timeout: 300,
               on_progress: fn _ -> :ok end
             )

    assert_receive {:slow_started, tool}, 1_000
    assert_receive {:slow_saw_cancel, ^tool}, 2_000
    assert_no_leaks(name)
  end
end

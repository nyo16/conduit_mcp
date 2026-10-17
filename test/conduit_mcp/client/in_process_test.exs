defmodule ConduitMcp.Client.InProcessTest do
  # The client end to end against this library's own server modules, in both
  # protocol eras, over `ConduitMcp.Client.Transport.InProcess`.
  use ExUnit.Case, async: true

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Prompt
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Resource
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.InProcess

  defmodule DslServer do
    use ConduitMcp.Server, instructions: "Use the echo tool."

    tool "echo", "Echo back the input" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => msg} -> text(msg) end)
    end

    tool "explode", "Always reports a failure" do
      handle(fn _conn, _params -> execution_error("it broke") end)
    end

    tool "whoami", "Reports the caller" do
      handle(fn conn, _params ->
        text("#{conn.assigns[:tenant]}:#{ConduitMcp.Principal.id(conn)}")
      end)
    end

    tool "block", "Never returns" do
      handle(fn conn, _params ->
        send(conn.assigns[:test_pid], {:tool_running, self()})

        receive do
          :never -> text("unreachable")
        end
      end)
    end

    resource "test://resource1" do
      description("Static resource")
      mime_type("text/plain")
      read(fn _conn, _params, _opts -> raw_resource("Test content", "text/plain") end)
    end

    prompt "greeting", "A greeting prompt" do
      arg(:name, :string, "Name")
      get(fn _conn, args -> [user("Hello, #{args["name"] || "World"}!")] end)
    end

    # The DSL generates no `handle_complete/3`, so the server defines it.
    def handle_complete(_conn, %{"type" => "ref/prompt", "name" => "greeting"}, argument) do
      values = Enum.filter(~w(Ada Alan Grace), &String.starts_with?(&1, argument["value"]))

      {:ok,
       %{"completion" => %{"values" => values, "total" => length(values), "hasMore" => false}}}
    end
  end

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, name: "echo", description: "Echo back the input"

    schema do
      field(:message, :string, "Message", required: true)
    end

    @impl true
    def execute(%{message: msg}, _conn), do: text(msg)
  end

  defmodule ExplodeTool do
    use ConduitMcp.Component, type: :tool, name: "explode", description: "Always fails"

    @impl true
    def execute(_params, _conn), do: execution_error("it broke")
  end

  defmodule StaticResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "test://resource1",
      description: "Static resource",
      mime_type: "text/plain"

    @impl true
    def execute(_params, _conn),
      do: {:ok, %{"contents" => [%{"uri" => "test://resource1", "text" => "Test content"}]}}
  end

  defmodule GreetingPrompt do
    use ConduitMcp.Component, type: :prompt, name: "greeting", description: "A greeting prompt"

    schema do
      field(:name, :string, "Name")
    end

    @impl true
    def execute(params, _conn) do
      {:ok,
       %{
         "messages" => [
           %{
             "role" => "user",
             "content" => %{"type" => "text", "text" => "Hello, #{params[:name] || "World"}!"}
           }
         ]
       }}
    end
  end

  defmodule EndpointServer do
    use ConduitMcp.Endpoint, name: "In-process Endpoint", version: "1.2.3"

    component(EchoTool)
    component(ExplodeTool)
    component(StaticResource)
    component(GreetingPrompt)
  end

  defp start_client(server, opts \\ []) do
    name = {__MODULE__, make_ref()}
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])

    start_supervised!(
      {Client,
       Keyword.merge(
         [name: name, transport: {InProcess, [server: server] ++ transport_opts}],
         opts
       )}
    )

    assert :ok = Client.await_ready(name)
    name
  end

  defp assert_no_leaks(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {_state, data} = :sys.get_state(conn)
    assert data.pending == %{}

    {:ok, task_sup, _value} = Registry.lookup({:task_sup, name})

    for pid <- Task.Supervisor.children(task_sup) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    assert Task.Supervisor.children(task_sup) == []
  end

  @servers [
    {"manual (dsl: false)", ConduitMcp.TestServer},
    {"DSL", DslServer},
    {"Endpoint", EndpointServer}
  ]

  for {label, server} <- @servers, protocol <- [:modern, :legacy, :auto] do
    @server server
    @protocol protocol

    test "#{label} server, protocol: #{inspect(protocol)}" do
      name = start_client(@server, protocol: @protocol)
      era = if @protocol == :legacy, do: :legacy, else: :modern
      assert {:ok, ^era} = Client.era(name)
      assert :ok = Client.ping(name)

      assert {:ok, %{tools: tools, next_cursor: nil}} = Client.list_tools(name)
      assert %Tool{server_id: server_id} = Enum.find(tools, &(&1.name == "echo"))
      assert server_id == inspect(name)

      assert {:ok, %ToolResult{is_error: false, content: [%{"text" => "hi"}]}} =
               Client.call_tool(name, "echo", %{"message" => "hi"})

      assert_tool_failure(@server, name)

      assert {:ok, %{resources: [%Resource{uri: "test://resource1"} | _]}} =
               Client.list_resources(name)

      assert {:ok, %{"contents" => [content | _]}} =
               Client.read_resource(name, "test://resource1")

      assert content["text"] == "Test content"

      assert {:ok, %{prompts: prompts}} = Client.list_prompts(name)
      assert Enum.any?(prompts, &match?(%Prompt{name: "greeting"}, &1))

      assert {:ok, %{"messages" => [%{"content" => %{"text" => "Hello, Ada!"}} | _]}} =
               Client.get_prompt(name, "greeting", %{name: "Ada"})

      assert {:ok, %{"completion" => %{"values" => values}}} =
               Client.complete(name, {:prompt, "greeting"}, {"name", "A"})

      if @server == DslServer, do: assert(values == ["Ada", "Alan"]), else: assert(values == [])

      assert_no_leaks(name)
    end
  end

  # `ConduitMcp.TestServer` has no tool reporting `isError`: its "fail" tool
  # answers with a JSON-RPC error, which is a protocol error to the client.
  defp assert_tool_failure(ConduitMcp.TestServer, name) do
    assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, -32_000}}} =
             Client.call_tool(name, "fail")
  end

  defp assert_tool_failure(_server, name) do
    assert {:ok, %ToolResult{is_error: true, content: [%{"text" => "it broke"}]}} =
             Client.call_tool(name, "explode")
  end

  test "modern server info carries the server's instructions and identity" do
    name = start_client(EndpointServer)

    assert {:ok, %{era: :modern, version: "2026-07-28", server_info: info}} =
             Client.server_info(name)

    assert %{name: "In-process Endpoint", version: "1.2.3"} = info

    name = start_client(DslServer)
    assert {:ok, %{instructions: "Use the echo tool."}} = Client.server_info(name)
  end

  test "an unknown tool is a protocol error in both eras" do
    for protocol <- [:modern, :legacy] do
      name = start_client(DslServer, protocol: protocol)

      assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, _code}}} =
               Client.call_tool(name, "nope")
    end
  end

  test "the configured assigns and principal reach the server" do
    name =
      start_client(DslServer,
        transport_opts: [assigns: %{tenant: "acme"}, principal: %{id: "user-1"}]
      )

    assert {:ok, %ToolResult{content: [%{"text" => "acme:user-1"}]}} =
             Client.call_tool(name, "whoami")
  end

  test "a cancelled request's task is terminated" do
    name = start_client(DslServer, transport_opts: [assigns: %{test_pid: self()}])

    assert {:error, %Error{kind: :timeout}} = Client.call_tool(name, "block", %{}, timeout: 50)
    assert_received {:tool_running, tool}
    ref = Process.monitor(tool)
    assert_receive {:DOWN, ^ref, :process, ^tool, _reason}
    assert_no_leaks(name)
  end

  test "async_call_tool runs under the client's task supervisor" do
    name = start_client(DslServer)
    task = Client.async_call_tool(name, "echo", %{"message" => "later"})

    {:ok, task_sup, _value} = Registry.lookup({:task_sup, name})
    assert task.pid in Task.Supervisor.children(task_sup)

    assert {:ok, %ToolResult{content: [%{"text" => "later"}]}} = Task.await(task)
    assert_no_leaks(name)
  end

  test "an invalid transport option fails the start" do
    name = {__MODULE__, make_ref()}

    assert {:error, _reason} =
             start_supervised(
               {Client, name: name, transport: {InProcess, server: NotAModule.Anywhere}}
             )
  end
end

defmodule ConduitMcp.Client.TasksTest do
  # The task requestor. Modern shapes are pinned from the tasks extension
  # (io.modelcontextprotocol/tasks, 2026-07-28): `resultType: "task"`
  # CreateTaskResult, `tasks/get` DetailedTask, `tasks/update`
  # inputResponses, `tasks/cancel`. Legacy shapes are 2025-11-25
  # task augmentation (`params.task`, `CreateTaskResult.task`).
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Task, as: ClientTask
  alias ConduitMcp.Client.ToolResult

  @ext "io.modelcontextprotocol/tasks"
  @task_id "786512e2-9e0d-44bd-8f29-789f320fe840"

  defmodule Answerer do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(params, ctx) do
      send(ctx.assigns.test_pid, {:elicitation, params})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
    end
  end

  setup do
    {:ok, name: {__MODULE__, make_ref()}}
  end

  defp task(status, extra \\ %{}) do
    Map.merge(
      %{
        "taskId" => @task_id,
        "status" => status,
        "createdAt" => "2025-11-25T10:30:00Z",
        "lastUpdatedAt" => "2025-11-25T10:40:00Z",
        "ttlMs" => 60_000,
        "pollIntervalMs" => 20
      },
      extra
    )
  end

  defp created(extra \\ %{}), do: Map.put(task("working", extra), "resultType", "task")
  defp detailed(status, extra \\ %{}), do: Map.put(task(status, extra), "resultType", "complete")

  defp caps(message), do: message["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]

  defp no_leaks(name, conn) do
    assert_no_leaks(name, conn)
    assert state(conn).watches == %{}
  end

  describe "modern (tasks extension)" do
    test "the extension is declared only when task: is used", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}) end)
      {id, message, _} = expect_request(conn, "tools/call")
      refute Map.has_key?(caps(message), "extensions")
      reply(conn, id, %{"content" => []})
      assert {:ok, %ToolResult{}} = Task.await(task)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}, task: :return) end)
      {id, message, _} = expect_request(conn, "tools/call")
      assert caps(message)["extensions"] == %{@ext => %{}}
      reply(conn, id, created(%{"statusMessage" => "in progress"}))

      assert {:ok,
              %ClientTask{
                id: @task_id,
                status: :working,
                status_message: "in progress",
                ttl_ms: 60_000,
                poll_interval_ms: 20,
                era: :modern
              } = created_task} = Task.await(task)

      assert ClientTask.terminal?(created_task) == false

      task = Task.async(fn -> Client.get_task(name, created_task) end)
      {id, message, _} = expect_request(conn, "tasks/get")
      assert message["params"]["taskId"] == @task_id
      assert caps(message)["extensions"] == %{@ext => %{}}
      reply(conn, id, detailed("working"))
      assert {:ok, %ClientTask{status: :working}} = Task.await(task)

      task = Task.async(fn -> Client.cancel_task(name, created_task) end)
      {id, message, _} = expect_request(conn, "tasks/cancel")
      assert message["params"]["taskId"] == @task_id
      reply(conn, id, %{"resultType" => "complete"})
      assert :ok = Task.await(task)

      no_leaks(name, conn)
    end

    test "a task result without task: is invalid", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}) end)
      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, created())

      assert {:error, %Error{kind: :protocol, reason: {:unknown_result_type, "task"}}} =
               Task.await(task)

      no_leaks(name, conn)
    end

    test "await polls, answers input once with tasks/update, and returns the result",
         %{name: name} do
      conn = start_client(name, handler: Answerer, assigns: %{test_pid: self()})
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "hello", %{}, task: :await) end)
      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, created())

      {id, _, _} = expect_request(conn, "tasks/get")
      reply(conn, id, detailed("working"))

      elicit = %{
        "method" => "elicitation/create",
        "params" => %{
          "mode" => "form",
          "message" => "Please enter your name.",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        }
      }

      {id, _, _} = expect_request(conn, "tasks/get")
      reply(conn, id, detailed("input_required", %{"inputRequests" => %{"name" => elicit}}))
      assert_receive {:elicitation, %{"message" => "Please enter your name."}}

      {id, update, _} = expect_request(conn, "tasks/update")
      assert caps(update)["extensions"] == %{@ext => %{}}

      assert update["params"]["taskId"] == @task_id

      assert update["params"]["inputResponses"] == %{
               "name" => %{"action" => "accept", "content" => %{"name" => "Ada"}}
             }

      reply(conn, id, %{"resultType" => "complete"})

      # The server has not processed the answer yet: the same key again.
      {id, _, _} = expect_request(conn, "tasks/get")
      reply(conn, id, detailed("input_required", %{"inputRequests" => %{"name" => elicit}}))

      {id, _, _} = expect_request(conn, "tasks/get")
      refute_received {:fake_transport, ^conn, {:request, %{"method" => "tasks/update"}, _}}
      refute_received {:elicitation, _}

      result = %{"content" => [%{"type" => "text", "text" => "Hello, Ada!"}], "isError" => false}
      reply(conn, id, detailed("completed", %{"result" => result}))

      assert {:ok, %ToolResult{content: [%{"text" => "Hello, Ada!"}], is_error: false}} =
               Task.await(task)

      no_leaks(name, conn)
    end

    test "a failed task is its JSON-RPC error", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}, task: :await) end)
      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, created())
      {id, _, _} = expect_request(conn, "tasks/get")
      error = %{"code" => -32_603, "message" => "boom"}
      reply(conn, id, detailed("failed", %{"error" => error}))

      assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, -32_603}}} = Task.await(task)
      no_leaks(name, conn)
    end

    test "a server answering directly gives the plain result", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}, task: :await) end)
      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, %{"content" => [%{"type" => "text", "text" => "now"}]})
      assert {:ok, %ToolResult{content: [%{"text" => "now"}]}} = Task.await(task)
      no_leaks(name, conn)
    end

    test "the await deadline cancels the task", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      task =
        Task.async(fn -> Client.call_tool(name, "t", %{}, task: :await, timeout: 100) end)

      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, created(%{"pollIntervalMs" => 5_000}))

      {id, message, _} = expect_request(conn, "tasks/cancel")
      assert message["params"]["taskId"] == @task_id
      reply(conn, id, %{"resultType" => "complete"})

      assert {:error, %Error{kind: :timeout, reason: :task_deadline}} = Task.await(task)
      no_leaks(name, conn)
    end

    test "an awaiting caller that dies gets its task cancelled by the connection",
         %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      caller = spawn(fn -> Client.call_tool(name, "t", %{}, task: :await, timeout: 60_000) end)
      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, created(%{"pollIntervalMs" => 30_000}))
      eventually(fn -> map_size(state(conn).watches) == 1 end)

      Process.exit(caller, :kill)
      {id, message, _} = expect_request(conn, "tasks/cancel")
      assert message["params"]["taskId"] == @task_id
      assert caps(message)["extensions"] == %{@ext => %{}}
      reply(conn, id, %{"resultType" => "complete"})

      eventually(fn -> state(conn).internal == %{} end)
      no_leaks(name, conn)
    end
  end

  test "a dead caller's unanswered tasks/cancel is cancelled at the request timeout",
       %{name: name} do
    conn = start_client(name, request_timeout: 200)
    ready_modern(name, conn)

    caller =
      spawn(fn -> Client.call_tool(name, "t", %{}, task: :await, timeout: 60_000) end)

    {id, _, _} = expect_request(conn, "tools/call")
    reply(conn, id, created(%{"pollIntervalMs" => 30_000}))
    eventually(fn -> map_size(state(conn).watches) == 1 end)

    Process.exit(caller, :kill)
    {id, _message, _} = expect_request(conn, "tasks/cancel")
    assert_receive {:fake_transport, ^conn, {:cancel, ^id, _handle, :timeout}}, 1_000
    assert state(conn).internal == %{}
    no_leaks(name, conn)
  end

  describe "legacy (task augmentation)" do
    @server_caps %{"tools" => %{}, "tasks" => %{"requests" => %{"tools" => %{"call" => %{}}}}}

    defp tool_def(name, support) do
      base = %{"name" => name, "inputSchema" => %{"type" => "object"}}
      if support, do: Map.put(base, "execution", %{"taskSupport" => support}), else: base
    end

    defp list_tools(conn) do
      {id, _, _} = expect_request(conn, "tools/list")

      reply(conn, id, %{
        "tools" => [
          tool_def("long", "required"),
          tool_def("maybe", "optional"),
          tool_def("never", "forbidden"),
          tool_def("plain", nil)
        ]
      })
    end

    test "a required tool is augmented and awaited without task:", %{name: name} do
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn, @server_caps)

      task = Task.async(fn -> Client.call_tool(name, "long", %{"n" => 1}) end)
      list_tools(conn)

      {id, call, _} = expect_request(conn, "tools/call")
      assert call["params"]["task"] == %{}
      assert call["params"]["arguments"] == %{"n" => 1}
      legacy_task = task("working") |> Map.delete("pollIntervalMs") |> Map.put("pollInterval", 20)
      reply(conn, id, %{"task" => legacy_task})

      {id, get, _} = expect_request(conn, "tasks/get")
      assert get["params"] == %{"taskId" => @task_id}
      reply(conn, id, Map.put(task("working"), "pollInterval", 20))

      # This library's legacy server wraps the task.
      {id, _, _} = expect_request(conn, "tasks/get")
      reply(conn, id, %{"task" => task("completed")})

      {id, result_request, _} = expect_request(conn, "tasks/result")
      assert result_request["params"] == %{"taskId" => @task_id}
      reply(conn, id, %{"content" => [%{"type" => "text", "text" => "done"}]})

      assert {:ok, %ToolResult{content: [%{"text" => "done"}]}} = Task.await(task)
      no_leaks(name, conn)
    end

    test "optional is augmented only with task:, forbidden and absent never",
         %{name: name} do
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn, @server_caps)

      task =
        Task.async(fn -> Client.call_tool(name, "maybe", %{}, task: :return, task_ttl: 5) end)

      list_tools(conn)
      {id, call, _} = expect_request(conn, "tools/call")
      assert call["params"]["task"] == %{"ttl" => 5}
      reply(conn, id, %{"task" => task("working")})
      assert {:ok, %ClientTask{era: :legacy, status: :working}} = Task.await(task)

      for {tool, opts} <- [{"maybe", []}, {"never", [task: :await]}, {"plain", [task: :return]}] do
        task = Task.async(fn -> Client.call_tool(name, tool, %{}, opts) end)
        {id, call, _} = expect_request(conn, "tools/call")
        refute Map.has_key?(call["params"], "task"), tool
        reply(conn, id, %{"content" => []})
        assert {:ok, %ToolResult{}} = Task.await(task)
      end

      no_leaks(name, conn)
    end

    test "a server without tasks.requests.tools.call is never augmented", %{name: name} do
      conn = start_client(name, protocol: :legacy)
      ready_legacy(name, conn, %{"tools" => %{}})

      task = Task.async(fn -> Client.call_tool(name, "long", %{}, task: :await) end)
      {id, call, _} = expect_request(conn, "tools/call")
      refute Map.has_key?(call["params"], "task")
      reply(conn, id, %{"content" => []})
      assert {:ok, %ToolResult{}} = Task.await(task)
      no_leaks(name, conn)
    end
  end
end

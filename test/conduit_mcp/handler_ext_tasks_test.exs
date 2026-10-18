defmodule ConduitMcp.HandlerExtTasksTest do
  # async: false — toggles the global :ext_tasks application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Ext.Tasks
  alias ConduitMcp.Handler
  alias ConduitMcp.Principal
  alias ConduitMcp.Protocol.Modern
  alias ConduitMcp.Test.McpSchema

  # Shapes pinned to the extension's own schema, vendored from
  # https://github.com/modelcontextprotocol/ext-tasks (schema/2026-07-28);
  # spec: https://modelcontextprotocol.io/extensions/tasks
  @ext_schema "ext-tasks-2026-07-28"
  @version "2026-07-28"
  @ext %{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}
  @schema %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}

  defmodule TaskServer do
    use ConduitMcp.Server

    tool "build", "Runs as a task" do
      handle(fn _conn, _params ->
        test_pid = Process.whereis(:ext_tasks_test)

        {:task,
         ttl_ms: 60_000,
         poll_interval_ms: 500,
         status_message: "Queued",
         start: fn task_id -> send(test_pid, {:started, task_id}) end}
      end)
    end

    tool "raising_start", "Its start function raises" do
      handle(fn _conn, _params -> {:task, start: fn _id -> raise "boom" end} end)
    end

    tool "bad_attrs", "Returns unknown attrs" do
      handle(fn _conn, _params -> {:task, nope: 1} end)
    end

    resource "doc://x" do
      read(fn _conn, _params, _opts -> {:task, []} end)
    end
  end

  setup do
    Process.register(self(), :ext_tasks_test)
    previous = Application.fetch_env(:conduit_mcp, :ext_tasks)
    Application.put_env(:conduit_mcp, :ext_tasks, true)
    start_supervised!(Tasks.EtsStore.Owner)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:conduit_mcp, :ext_tasks, value)
        :error -> Application.delete_env(:conduit_mcp, :ext_tasks)
      end
    end)
  end

  defp request(method, params, capabilities \\ @ext) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => capabilities
    }

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp as(principal_id),
    do: Principal.put(conn(:post, "/", ""), %{id: principal_id, strategy: :custom})

  defp dispatch(request, conn \\ as("alice")) do
    assert {:reply, response} = Handler.dispatch(request, TaskServer, conn)
    response
  end

  defp start_build(conn \\ as("alice")) do
    response = dispatch(request("tools/call", %{"name" => "build"}), conn)
    assert %{"result" => %{"resultType" => "task", "taskId" => task_id}} = response
    assert_received {:started, ^task_id}
    {task_id, response}
  end

  defp get(task_id, conn \\ as("alice")),
    do: dispatch(request("tasks/get", %{"taskId" => task_id}), conn)

  describe "tools/call returning {:task, attrs}" do
    test "answers CreateTaskResult once the task is stored; :start runs with its id" do
      {task_id, response} = start_build()
      result = response["result"]

      assert :ok == McpSchema.validate(@ext_schema, "CreateTaskResult", result)
      assert Modern.http_status(response) == 200

      assert %{
               "status" => "working",
               "statusMessage" => "Queued",
               "ttlMs" => 60_000,
               "pollIntervalMs" => 500
             } = result

      refute Map.has_key?(result, "cacheScope")
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(result["createdAt"])
      # 32 random bytes, url-safe Base64 without padding.
      assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(task_id, padding: false)
      assert {:ok, %{status: "working", owner: "alice"}} = Tasks.status(task_id)
    end

    test "without the extension declared: -32021 with requiredCapabilities, HTTP 400" do
      response = dispatch(request("tools/call", %{"name" => "build"}, %{}))

      assert %{
               "error" => %{
                 "code" => -32_021,
                 "data" => %{"requiredCapabilities" => @ext}
               }
             } = response

      assert Modern.http_status(response) == 400
      refute_received {:started, _}
    end

    test "when the extension is disabled: -32603 and a log line" do
      Application.put_env(:conduit_mcp, :ext_tasks, false)

      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => -32_603}} =
                   dispatch(request("tools/call", %{"name" => "build"}))
        end)

      assert log =~ "tasks extension is disabled"
    end

    test "a raising :start fails the task with -32603" do
      log =
        capture_log(fn ->
          %{"result" => %{"resultType" => "task", "taskId" => task_id}} =
            dispatch(request("tools/call", %{"name" => "raising_start"}))

          assert %{"result" => %{"status" => "failed", "error" => %{"code" => -32_603}}} =
                   get(task_id)
        end)

      assert log =~ "boom"
    end

    test "invalid attrs are -32603 and logged" do
      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => -32_603}} =
                   dispatch(request("tools/call", %{"name" => "bad_attrs"}))
        end)

      assert log =~ "invalid attrs"
    end

    test "from resources/read: -32603" do
      capture_log(fn ->
        assert %{"error" => %{"code" => -32_603}} =
                 dispatch(request("resources/read", %{"uri" => "doc://x"}))
      end)
    end

    test "on the legacy era: -32603 with a clear message" do
      legacy = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "build"}
      }

      capture_log(fn ->
        assert %{"error" => %{"code" => -32_603, "message" => message}} = dispatch(legacy)
        assert message =~ "2026-07-28"
      end)
    end
  end

  describe "tasks/get" do
    test "returns the current state to the owner" do
      {task_id, _} = start_build()
      %{"result" => result} = get(task_id)

      assert :ok == McpSchema.validate(@ext_schema, "GetTaskResult", result)
      assert %{"resultType" => "complete", "taskId" => ^task_id, "status" => "working"} = result
      assert result["ttlMs"] == 60_000
      refute Map.has_key?(result, "cacheScope")
    end

    test "another principal (or none) gets the same not-found as an unknown id" do
      {task_id, _} = start_build()

      unknown = get(Tasks.new_id())
      other = get(task_id, as("mallory"))
      anonymous = get(task_id, conn(:post, "/", ""))

      assert %{"error" => %{"code" => -32_602, "message" => message}} = unknown
      refute message =~ task_id
      assert other == unknown
      assert anonymous == unknown
    end

    test "terminal states embed result or error" do
      {done, _} = start_build()
      {failed, _} = start_build()
      tool_result = %{"content" => [%{"type" => "text", "text" => "ok"}], "isError" => false}

      assert :ok = Tasks.complete(done, tool_result)
      assert :ok = Tasks.fail(failed, {-32_000, "upstream down"})

      %{"result" => completed} = get(done)
      %{"result" => failure} = get(failed)

      assert :ok == McpSchema.validate(@ext_schema, "GetTaskResult", completed)
      assert :ok == McpSchema.validate(@ext_schema, "GetTaskResult", failure)
      assert %{"status" => "completed", "result" => ^tool_result} = completed

      assert %{
               "status" => "failed",
               "statusMessage" => "upstream down",
               "error" => %{"code" => -32_000, "message" => "upstream down"}
             } = failure

      # Terminal is final.
      assert {:error, :terminal} = Tasks.complete(failed, tool_result)
    end

    test "requires the extension in the request's capabilities" do
      {task_id, _} = start_build()
      response = dispatch(request("tasks/get", %{"taskId" => task_id}, %{}))

      assert %{"error" => %{"code" => -32_021}} = response
      assert Modern.http_status(response) == 400
    end
  end

  describe "tasks/update" do
    test "partial answers keep input_required; the last one returns to working" do
      {task_id, _} = start_build()

      requests = %{
        "a" => ConduitMcp.MRTR.elicit("First?", @schema),
        "b" => ConduitMcp.MRTR.elicit("Second?", @schema)
      }

      assert :ok = Tasks.require_input(task_id, requests)

      %{"result" => waiting} = get(task_id)
      assert :ok == McpSchema.validate(@ext_schema, "GetTaskResult", waiting)
      assert %{"status" => "input_required", "inputRequests" => ^requests} = waiting

      update = fn responses ->
        dispatch(request("tasks/update", %{"taskId" => task_id, "inputResponses" => responses}))
      end

      answer = %{"action" => "accept", "content" => %{"ok" => true}}

      # An unknown key is ignored; a partial answer leaves the rest outstanding.
      assert %{"result" => ack} = update.(%{"a" => answer, "zzz" => answer})
      assert :ok == McpSchema.validate(@ext_schema, "UpdateTaskResult", ack)
      assert Map.delete(ack, "_meta") == %{"resultType" => "complete"}

      assert %{"result" => %{"status" => "input_required", "inputRequests" => outstanding}} =
               get(task_id)

      assert Map.keys(outstanding) == ["b"]

      assert %{"result" => %{"resultType" => "complete"}} = update.(%{"b" => answer, "a" => %{}})
      assert %{"result" => %{"status" => "working"} = working} = get(task_id)
      refute Map.has_key?(working, "inputRequests")

      # The worker sees every answer; an already-answered key was not replaced.
      assert {:ok, %{input_responses: %{"a" => ^answer, "b" => ^answer}}} =
               Tasks.status(task_id)

      # Keys are unique over the task's lifetime.
      assert {:error, {:duplicate_keys, ["a"]}} =
               Tasks.require_input(task_id, %{"a" => requests["a"]})
    end

    test "another principal's update is not-found and changes nothing" do
      {task_id, _} = start_build()
      :ok = Tasks.require_input(task_id, %{"a" => ConduitMcp.MRTR.elicit("?", @schema)})

      assert %{"error" => %{"code" => -32_602}} =
               dispatch(
                 request("tasks/update", %{"taskId" => task_id, "inputResponses" => %{"a" => %{}}}),
                 as("mallory")
               )

      assert {:ok, %{status: "input_required", input_responses: %{}}} = Tasks.status(task_id)
    end

    test "inputResponses must be an object" do
      {task_id, _} = start_build()

      assert %{"error" => %{"code" => -32_602}} =
               dispatch(request("tasks/update", %{"taskId" => task_id, "inputResponses" => []}))
    end
  end

  describe "tasks/cancel" do
    test "acks, cancels a non-terminal task, and leaves a terminal one alone" do
      {task_id, _} = start_build()

      assert %{"result" => ack} = dispatch(request("tasks/cancel", %{"taskId" => task_id}))
      assert :ok == McpSchema.validate(@ext_schema, "CancelTaskResult", ack)
      assert Tasks.cancelled?(task_id)
      assert %{"result" => %{"status" => "cancelled"}} = get(task_id)
      assert {:error, :terminal} = Tasks.complete(task_id, %{"content" => []})

      {done, _} = start_build()
      :ok = Tasks.complete(done, %{"content" => []})
      assert %{"result" => _} = dispatch(request("tasks/cancel", %{"taskId" => done}))
      assert {:ok, %{status: "completed"}} = Tasks.status(done)
    end

    test "another principal's cancel is not-found" do
      {task_id, _} = start_build()

      assert %{"error" => %{"code" => -32_602}} =
               dispatch(request("tasks/cancel", %{"taskId" => task_id}), as("mallory"))

      refute Tasks.cancelled?(task_id)
    end
  end

  describe "routing and discovery" do
    test "tasks/* are routed only while the extension is enabled" do
      assert Map.has_key?(Handler.methods(:modern), "tasks/update")

      Application.put_env(:conduit_mcp, :ext_tasks, false)

      refute Map.has_key?(Handler.methods(:modern), "tasks/update")
      response = dispatch(request("tasks/get", %{"taskId" => "x"}))
      assert %{"error" => %{"code" => -32_601}} = response
      assert Modern.http_status(response) == 404
    end

    test "server/discover advertises the extension only when enabled" do
      discover = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}

      %{"result" => %{"capabilities" => caps}} = dispatch(discover)
      assert caps["extensions"] == %{"io.modelcontextprotocol/tasks" => %{}}

      Application.put_env(:conduit_mcp, :ext_tasks, false)
      %{"result" => %{"capabilities" => caps}} = dispatch(discover)
      refute Map.has_key?(caps, "extensions")
    end
  end
end

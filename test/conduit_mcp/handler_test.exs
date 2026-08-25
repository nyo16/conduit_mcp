defmodule ConduitMcp.HandlerTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Protocol
  alias ConduitMcp.TestServer

  # `tasks/*` tests live in ConduitMcp.HandlerTasksTest — they wipe the global
  # `:conduit_mcp_tasks` table and must not run concurrently with this module.

  describe "handle_request/2 with valid requests" do
    test "handles initialize request with latest protocol version" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2025-11-25"
      assert response["result"]["serverInfo"]["name"] == "conduit-mcp"

      assert response["result"]["serverInfo"]["version"] ==
               Application.spec(:conduit_mcp, :vsn) |> to_string()

      assert response["result"]["capabilities"]["tools"] == %{"listChanged" => false}
      assert response["result"]["capabilities"]["resources"] == %{"listChanged" => false}
      assert response["result"]["capabilities"]["prompts"] == %{"listChanged" => false}
    end

    test "handles initialize request with older supported protocol version" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["result"]["protocolVersion"] == "2025-06-18"
      assert response["result"]["serverInfo"]["name"] == "conduit-mcp"
    end

    test "rejects unsupported protocol version" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["error"]["code"] == Protocol.invalid_request()
      assert response["error"]["message"] =~ "Unsupported protocol version"
    end

    test "handles ping request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "ping"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      assert response["result"] == %{}
    end

    test "handles tools/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/list"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 3
      assert is_list(response["result"]["tools"])
      assert length(response["result"]["tools"]) == 2
      assert Enum.any?(response["result"]["tools"], fn t -> t["name"] == "echo" end)
    end

    test "handles tools/call request successfully" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{"message" => "Hello!"}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 4
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Hello!"}]
    end

    test "handles tools/call with tool error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{
          "name" => "fail",
          "arguments" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 5
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "Tool execution failed"
    end

    test "handles tools/call with tool error when request carries _meta" do
      # Regression: clients (e.g. the Python MCP SDK) send a _meta progressToken
      # on every tools/call. Error responses have no "result" key, so merging
      # _meta there used to raise and surface as a generic "Internal server
      # error" instead of the real tool error.
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{
          "_meta" => %{"progressToken" => 1},
          "name" => "fail",
          "arguments" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["id"] == 5
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "Tool execution failed"
      refute Map.has_key?(response, "result")
    end

    test "merges _meta into the result of a successful tools/call" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "_meta" => %{"progressToken" => 7},
          "name" => "echo",
          "arguments" => %{"message" => "Hello!"}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["result"]["content"] == [%{"type" => "text", "text" => "Hello!"}]
      assert response["result"]["_meta"] == %{"progressToken" => 7}
    end

    test "handles tools/call with unknown tool" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "tools/call",
        "params" => %{
          "name" => "unknown_tool",
          "arguments" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 6
      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
      assert response["error"]["message"] == "Tool not found"
    end

    test "handles resources/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "resources/list"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 7
      assert is_list(response["result"]["resources"])
      assert length(response["result"]["resources"]) == 1
    end

    test "handles resources/read request successfully" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 8,
        "method" => "resources/read",
        "params" => %{"uri" => "test://resource1"}
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 8
      assert is_list(response["result"]["contents"])
      assert hd(response["result"]["contents"])["text"] == "Test content"
    end

    test "handles resources/read with unknown resource" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "resources/read",
        "params" => %{"uri" => "test://unknown"}
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 9
      assert response["error"]["code"] == ConduitMcp.Errors.resource_not_found()
      assert response["error"]["message"] == "Resource not found"
    end

    test "handles prompts/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "prompts/list"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 10
      assert is_list(response["result"]["prompts"])
      assert length(response["result"]["prompts"]) == 1
    end

    test "handles prompts/get request successfully" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 11,
        "method" => "prompts/get",
        "params" => %{
          "name" => "greeting",
          "arguments" => %{"name" => "Alice"}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 11
      assert is_list(response["result"]["messages"])
      assert hd(response["result"]["messages"])["content"]["text"] == "Hello, Alice!"
    end

    test "handles prompts/get with default arguments" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 12,
        "method" => "prompts/get",
        "params" => %{
          "name" => "greeting",
          "arguments" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 12
      assert hd(response["result"]["messages"])["content"]["text"] == "Hello, World!"
    end

    test "handles prompts/get with unknown prompt" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 13,
        "method" => "prompts/get",
        "params" => %{
          "name" => "unknown_prompt",
          "arguments" => %{}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 13
      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
      assert response["error"]["message"] == "Prompt not found"
    end
  end

  describe "handle_request/2 with notifications" do
    test "handles notifications/initialized" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      response = Handler.handle_request(notification, TestServer)

      assert response == :ok
    end

    test "handles unknown notification" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/unknown"
      }

      response = Handler.handle_request(notification, TestServer)

      assert response == :ok
    end

    test "notifications/cancelled records cancellation state scoped to the caller" do
      # No table wipe: `:conduit_mcp_cancellations` is a run-global supervised
      # table and this module is `async: true`, so clearing it here is the
      # hazard T-L2 diagnosed for `:conduit_mcp_tasks`. A unique id per run
      # gives the same isolation without touching another module's rows.
      request_id = "cancel-#{System.unique_integer([:positive])}"

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => request_id, "reason" => "user abort"}
      }

      session = "session-#{System.unique_integer([:positive])}"
      caller = Plug.Conn.put_private(%Plug.Conn{}, :mcp_session_id, session <> "-a")
      other = Plug.Conn.put_private(%Plug.Conn{}, :mcp_session_id, session <> "-b")

      assert :ok = Handler.handle_request(notification, TestServer, caller)

      scope = ConduitMcp.Cancellation.scope(caller)
      assert ConduitMcp.Cancellation.cancelled?(request_id, scope)
      assert ConduitMcp.Cancellation.reason(request_id, scope) == "user abort"

      # The whole point of scoping: another client's identical id is untouched.
      refute ConduitMcp.Cancellation.cancelled?(request_id, ConduitMcp.Cancellation.scope(other))
    end

    test "notifications/cancelled with a non-scalar requestId returns invalid_params" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => %{}}
      }

      response = Handler.handle_request(notification, TestServer)

      # Previously `to_string(%{})` raised out of the un-rescued notification
      # path and the transport returned a 500.
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == nil
      assert response["error"]["code"] == Protocol.invalid_params()
      assert response["error"]["message"] =~ "string or integer requestId"
    end

    test "a malformed notifications/cancelled still emits [:conduit_mcp, :request, :stop]" do
      ref =
        ConduitMcp.TelemetryTestHelper.attach_event_handlers(self(), [
          [:conduit_mcp, :request, :stop]
        ])

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => %{}}
      }

      Handler.handle_request(notification, TestServer)

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, _measurements,
                      %{method: "notifications/cancelled", status: :error}}
    end
  end

  describe "handle_request/2 with invalid requests" do
    test "handles invalid JSON-RPC format" do
      request = %{
        "id" => 100,
        "method" => "ping"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 100
      assert response["error"]["code"] == Protocol.invalid_request()
      assert response["error"]["message"] == "Invalid JSON-RPC 2.0 request"
    end

    test "handles unknown method" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 101,
        "method" => "unknown/method"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 101
      assert response["error"]["code"] == Protocol.method_not_found()
      assert String.contains?(response["error"]["message"], "Method not found")
    end
  end

  describe "telemetry events" do
    test "emits telemetry event for successful request" do
      alias ConduitMcp.TelemetryTestHelper

      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :request, :stop]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "ping"
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.method == "ping"
      assert metadata.server_module == TestServer
      assert metadata.status == :ok
    end

    test "emits telemetry event for tool execution" do
      alias ConduitMcp.TelemetryTestHelper

      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :tool, :execute]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{"message" => "test"}
        }
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :tool, :execute], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.tool_name == "echo"
      assert metadata.server_module == TestServer
      assert metadata.status == :ok
    end

    test "emits telemetry event with error status for failed tool" do
      alias ConduitMcp.TelemetryTestHelper

      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :tool, :execute]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "fail",
          "arguments" => %{}
        }
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :tool, :execute], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.tool_name == "fail"
      assert metadata.status == :error
    end
  end

  # Inline test server that implements arity-2 list callbacks for pagination
  defmodule PaginationServer do
    use ConduitMcp.Server, dsl: false

    @tools_page1 [
      %{
        "name" => "tool_a",
        "description" => "First tool",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]

    @tools_page2 [
      %{
        "name" => "tool_b",
        "description" => "Second tool",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]

    @impl true
    def handle_list_tools(_conn, params) do
      case Map.get(params, "cursor") do
        "page2" ->
          {:ok, %{"tools" => @tools_page2}}

        _ ->
          {:ok, %{"tools" => @tools_page1, "nextCursor" => "page2"}}
      end
    end

    @impl true
    def handle_list_resources(_conn, params) do
      case Map.get(params, "cursor") do
        "page2" ->
          {:ok, %{"resources" => [%{"uri" => "test://r2", "name" => "Resource 2"}]}}

        _ ->
          {:ok,
           %{
             "resources" => [%{"uri" => "test://r1", "name" => "Resource 1"}],
             "nextCursor" => "page2"
           }}
      end
    end

    @impl true
    def handle_list_prompts(_conn, params) do
      case Map.get(params, "cursor") do
        "page2" ->
          {:ok, %{"prompts" => [%{"name" => "prompt_b", "description" => "Second prompt"}]}}

        _ ->
          {:ok,
           %{
             "prompts" => [%{"name" => "prompt_a", "description" => "First prompt"}],
             "nextCursor" => "page2"
           }}
      end
    end
  end

  # Inline test server that implements handle_complete, handle_set_log_level,
  # handle_subscribe_resource, and handle_unsubscribe_resource
  defmodule ImplementedCallbacksServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_complete(_conn, ref, argument) do
      ref_name = Map.get(ref, "name", "unknown")
      arg_value = Map.get(argument, "value", "")

      completions =
        case ref_name do
          "greeting" ->
            ["english", "espanol", "esperanto"]
            |> Enum.filter(&String.starts_with?(&1, arg_value))

          _ ->
            []
        end

      {:ok,
       %{
         "completion" => %{
           "values" => completions,
           "total" => length(completions),
           "hasMore" => false
         }
       }}
    end

    @impl true
    def handle_set_log_level(_conn, level) do
      {:ok, %{"level" => level}}
    end

    @impl true
    def handle_subscribe_resource(_conn, uri) do
      {:ok, %{"subscribed" => uri}}
    end

    @impl true
    def handle_unsubscribe_resource(_conn, uri) do
      {:ok, %{"unsubscribed" => uri}}
    end
  end

  describe "new MCP 2025-11-25 methods" do
    test "completion/complete returns empty values when not implemented" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
          "argument" => %{"name" => "language", "value" => "py"}
        }
      }

      response = Handler.handle_request(request, TestServer)

      assert response["result"]["completion"]["values"] == []
      assert response["result"]["completion"]["hasMore"] == false
    end

    test "logging/setLevel returns ok when not implemented" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "logging/setLevel",
        "params" => %{"level" => "debug"}
      }

      response = Handler.handle_request(request, TestServer)
      assert response["result"] == %{}
    end

    test "resources/subscribe returns method not found when not implemented" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/subscribe",
        "params" => %{"uri" => "test://resource1"}
      }

      response = Handler.handle_request(request, TestServer)
      assert response["error"]["code"] == Protocol.method_not_found()
    end

    test "resources/unsubscribe returns method not found when not implemented" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/unsubscribe",
        "params" => %{"uri" => "test://resource1"}
      }

      response = Handler.handle_request(request, TestServer)
      assert response["error"]["code"] == Protocol.method_not_found()
    end

    test "_meta field is passed through in tool call response" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{"message" => "test"},
          "_meta" => %{"progressToken" => "abc123"}
        }
      }

      response = Handler.handle_request(request, TestServer)
      assert response["result"]["_meta"]["progressToken"] == "abc123"
    end
  end

  describe "pagination via arity-2 list callbacks" do
    test "tools/list passes cursor param to arity-2 handle_list_tools" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"cursor" => "page2"}
      }

      response = Handler.handle_request(request, PaginationServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert length(response["result"]["tools"]) == 1
      assert hd(response["result"]["tools"])["name"] == "tool_b"
      refute Map.has_key?(response["result"], "nextCursor")
    end

    test "tools/list returns first page with nextCursor when no cursor provided" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list"
      }

      response = Handler.handle_request(request, PaginationServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      assert length(response["result"]["tools"]) == 1
      assert hd(response["result"]["tools"])["name"] == "tool_a"
      assert response["result"]["nextCursor"] == "page2"
    end

    test "resources/list passes cursor param to arity-2 handle_list_resources" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "resources/list",
        "params" => %{"cursor" => "page2"}
      }

      response = Handler.handle_request(request, PaginationServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 3
      assert length(response["result"]["resources"]) == 1
      assert hd(response["result"]["resources"])["name"] == "Resource 2"
    end

    test "prompts/list passes cursor param to arity-2 handle_list_prompts" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "prompts/list",
        "params" => %{"cursor" => "page2"}
      }

      response = Handler.handle_request(request, PaginationServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 4
      assert length(response["result"]["prompts"]) == 1
      assert hd(response["result"]["prompts"])["name"] == "prompt_b"
    end

    test "arity-1 fallback still works for servers without arity-2" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/list",
        "params" => %{"cursor" => "page2"}
      }

      response = Handler.handle_request(request, TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 5
      # TestServer only implements arity-1, so it ignores the cursor
      assert is_list(response["result"]["tools"])
      assert length(response["result"]["tools"]) == 2
    end
  end

  describe "handler methods with actual implementations" do
    test "completion/complete returns server's completion values" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
          "argument" => %{"name" => "language", "value" => "e"}
        }
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["completion"]["values"] == ["english", "espanol", "esperanto"]
      assert response["result"]["completion"]["total"] == 3
      assert response["result"]["completion"]["hasMore"] == false
    end

    test "completion/complete filters values based on partial input" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
          "argument" => %{"name" => "language", "value" => "es"}
        }
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["result"]["completion"]["values"] == ["espanol", "esperanto"]
      assert response["result"]["completion"]["total"] == 2
    end

    test "completion/complete returns empty for unknown ref" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "unknown"},
          "argument" => %{"name" => "language", "value" => "e"}
        }
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["result"]["completion"]["values"] == []
      assert response["result"]["completion"]["total"] == 0
    end

    test "completion/complete rejects unknown ref.type with -32602" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/garbage", "name" => "x"},
          "argument" => %{"name" => "a", "value" => "b"}
        }
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
      assert response["error"]["message"] =~ ~s(Invalid completion ref type "ref/garbage")
    end

    test "completion/complete rejects ref missing required field" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt"},
          "argument" => %{"name" => "a", "value" => "b"}
        }
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)
      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
      assert response["error"]["message"] =~ "missing name"
    end

    test "completion/complete rejects ref without type" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{},
          "argument" => %{"name" => "a", "value" => "b"}
        }
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)
      assert response["error"]["code"] == ConduitMcp.Errors.invalid_params()
    end

    test "logging/setLevel returns the server's response with level" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "logging/setLevel",
        "params" => %{"level" => "debug"}
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 4
      assert response["result"]["level"] == "debug"
    end

    test "logging/setLevel works with different log levels" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "logging/setLevel",
        "params" => %{"level" => "error"}
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["result"]["level"] == "error"
    end

    test "resources/subscribe returns the server's response" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "resources/subscribe",
        "params" => %{"uri" => "test://resource1"}
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 6
      assert response["result"]["subscribed"] == "test://resource1"
    end

    test "resources/unsubscribe returns the server's response" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "resources/unsubscribe",
        "params" => %{"uri" => "test://resource1"}
      }

      response = Handler.handle_request(request, ImplementedCallbacksServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 7
      assert response["result"]["unsubscribed"] == "test://resource1"
    end
  end

  describe "resources/templates/list" do
    test "returns empty list when server does not implement the callback" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/templates/list"
      }

      response = Handler.handle_request(request, TestServer)

      assert response["result"] == %{"resourceTemplates" => []}
    end
  end

  describe "capability advertisement on initialize" do
    setup do
      ConduitMcp.ServerMeta.clear(TestServer)
      ConduitMcp.ServerMeta.clear(ImplementedCallbacksServer)
      :ok
    end

    test "server without optional callbacks advertises only base capabilities" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test", "version" => "1.0"},
          "capabilities" => %{}
        }
      }

      caps = Handler.handle_request(request, TestServer)["result"]["capabilities"]

      assert Map.has_key?(caps, "tools")
      assert Map.has_key?(caps, "resources")
      assert Map.has_key?(caps, "prompts")
      refute Map.has_key?(caps, "completions")
      refute Map.has_key?(caps, "logging")
      refute Map.has_key?(caps["resources"], "subscribe")
    end

    test "server with all optional callbacks advertises completions, logging, subscribe" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test", "version" => "1.0"},
          "capabilities" => %{}
        }
      }

      caps =
        Handler.handle_request(request, ImplementedCallbacksServer)["result"]["capabilities"]

      assert caps["completions"] == %{}
      assert caps["logging"] == %{}
      assert caps["resources"]["subscribe"] == true
    end
  end
end

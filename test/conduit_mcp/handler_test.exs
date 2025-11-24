defmodule ConduitMcp.HandlerTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Protocol
  alias ConduitMcp.TestServer

  describe "handle_request/2 with valid requests" do
    test "handles initialize request" do
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

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2025-06-18"
      assert response["result"]["serverInfo"]["name"] == "conduit-mcp"
      assert response["result"]["serverInfo"]["version"] == "0.4.7"
      assert response["result"]["capabilities"]["tools"] == %{}
      assert response["result"]["capabilities"]["resources"] == %{}
      assert response["result"]["capabilities"]["prompts"] == %{}
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
      assert response["error"]["code"] == -32601
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
      assert response["error"]["code"] == -32601
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
      assert response["error"]["code"] == -32601
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
end

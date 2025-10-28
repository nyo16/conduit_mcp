defmodule ConduitMcp.ProtocolTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Protocol

  describe "protocol_version/0" do
    test "returns the correct protocol version" do
      assert Protocol.protocol_version() == "2025-06-18"
    end
  end

  describe "error code constants" do
    test "parse_error returns -32700" do
      assert Protocol.parse_error() == -32700
    end

    test "invalid_request returns -32600" do
      assert Protocol.invalid_request() == -32600
    end

    test "method_not_found returns -32601" do
      assert Protocol.method_not_found() == -32601
    end

    test "invalid_params returns -32602" do
      assert Protocol.invalid_params() == -32602
    end

    test "internal_error returns -32603" do
      assert Protocol.internal_error() == -32603
    end
  end

  describe "methods/0" do
    test "returns all supported MCP methods" do
      methods = Protocol.methods()

      assert methods["initialize"] == :initialize
      assert methods["notifications/initialized"] == :initialized
      assert methods["ping"] == :ping
      assert methods["tools/list"] == :list_tools
      assert methods["tools/call"] == :call_tool
      assert methods["resources/list"] == :list_resources
      assert methods["resources/read"] == :read_resource
      assert methods["prompts/list"] == :list_prompts
      assert methods["prompts/get"] == :get_prompt
      assert methods["logging/setLevel"] == :set_log_level
    end
  end

  describe "valid_request?/1" do
    test "returns true for valid JSON-RPC 2.0 request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "ping"
      }

      assert Protocol.valid_request?(request)
    end

    test "returns true for request with params" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "abc-123",
        "method" => "tools/call",
        "params" => %{"name" => "test"}
      }

      assert Protocol.valid_request?(request)
    end

    test "returns false when jsonrpc field is missing" do
      request = %{
        "id" => 1,
        "method" => "ping"
      }

      refute Protocol.valid_request?(request)
    end

    test "returns false when jsonrpc version is wrong" do
      request = %{
        "jsonrpc" => "1.0",
        "id" => 1,
        "method" => "ping"
      }

      refute Protocol.valid_request?(request)
    end

    test "returns false when id is missing" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "ping"
      }

      refute Protocol.valid_request?(request)
    end

    test "returns false when method is missing" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1
      }

      refute Protocol.valid_request?(request)
    end

    test "returns false when method is not a string" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => 123
      }

      refute Protocol.valid_request?(request)
    end

    test "returns false for non-map input" do
      refute Protocol.valid_request?("not a map")
      refute Protocol.valid_request?(nil)
      refute Protocol.valid_request?([])
    end
  end

  describe "valid_notification?/1" do
    test "returns true for valid JSON-RPC 2.0 notification" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }

      assert Protocol.valid_notification?(notification)
    end

    test "returns true for notification with params" do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{"clientId" => "test"}
      }

      assert Protocol.valid_notification?(notification)
    end

    test "returns false when id is present" do
      notification = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "notifications/initialized"
      }

      refute Protocol.valid_notification?(notification)
    end

    test "returns false when jsonrpc field is missing" do
      notification = %{
        "method" => "notifications/initialized"
      }

      refute Protocol.valid_notification?(notification)
    end

    test "returns false when method is missing" do
      notification = %{
        "jsonrpc" => "2.0"
      }

      refute Protocol.valid_notification?(notification)
    end

    test "returns false for non-map input" do
      refute Protocol.valid_notification?("not a map")
      refute Protocol.valid_notification?(nil)
    end
  end

  describe "success_response/2" do
    test "creates a valid success response with integer id" do
      response = Protocol.success_response(1, %{"status" => "ok"})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{"status" => "ok"}
      refute Map.has_key?(response, "error")
    end

    test "creates a valid success response with string id" do
      response = Protocol.success_response("abc-123", %{"data" => "test"})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "abc-123"
      assert response["result"] == %{"data" => "test"}
    end

    test "creates response with null result" do
      response = Protocol.success_response(2, nil)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      assert response["result"] == nil
    end

    test "creates response with empty map result" do
      response = Protocol.success_response(3, %{})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 3
      assert response["result"] == %{}
    end
  end

  describe "error_response/3" do
    test "creates a valid error response" do
      response = Protocol.error_response(1, -32601, "Method not found")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found"
      refute Map.has_key?(response["error"], "data")
    end

    test "creates error response with string id" do
      response = Protocol.error_response("test-id", -32600, "Invalid request")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "test-id"
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] == "Invalid request"
    end

    test "creates error response with null id" do
      response = Protocol.error_response(nil, -32700, "Parse error")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == nil
      assert response["error"]["code"] == -32700
      assert response["error"]["message"] == "Parse error"
    end
  end

  describe "error_response/4" do
    test "creates error response with additional data" do
      response = Protocol.error_response(
        1,
        -32603,
        "Internal error",
        %{"details" => "Stack trace"}
      )

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "Internal error"
      assert response["error"]["data"] == %{"details" => "Stack trace"}
    end

    test "creates error response with nil data (same as 3-arg version)" do
      response = Protocol.error_response(1, -32601, "Method not found", nil)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found"
      refute Map.has_key?(response["error"], "data")
    end
  end

  describe "notification/1" do
    test "creates a valid notification without params" do
      notification = Protocol.notification("notifications/initialized")

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/initialized"
      refute Map.has_key?(notification, "id")
      refute Map.has_key?(notification, "params")
    end
  end

  describe "notification/2" do
    test "creates a valid notification with params" do
      notification = Protocol.notification("logging/setLevel", %{"level" => "debug"})

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "logging/setLevel"
      assert notification["params"] == %{"level" => "debug"}
      refute Map.has_key?(notification, "id")
    end

    test "creates notification without params field when params is nil" do
      notification = Protocol.notification("test/method", nil)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "test/method"
      refute Map.has_key?(notification, "params")
      refute Map.has_key?(notification, "id")
    end
  end
end

defmodule ConduitMcp.ProtocolTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Protocol

  describe "protocol_version/0" do
    test "returns the correct protocol version" do
      assert Protocol.protocol_version() == "2025-11-25"
    end
  end

  describe "supported_versions/0" do
    test "returns list of supported protocol versions" do
      versions = Protocol.supported_versions()
      assert is_list(versions)
      assert "2025-11-25" in versions
      assert "2025-06-18" in versions
    end
  end

  describe "negotiate_version/1" do
    test "returns matching version for supported version" do
      assert Protocol.negotiate_version("2025-11-25") == "2025-11-25"
      assert Protocol.negotiate_version("2025-06-18") == "2025-06-18"
    end

    test "returns nil for unsupported version" do
      assert Protocol.negotiate_version("1999-01-01") == nil
      assert Protocol.negotiate_version("unknown") == nil
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

    test "resource_not_found returns -32002" do
      assert Protocol.resource_not_found() == -32002
    end

    test "server_error returns -32000" do
      # The moduledoc advertised it while the defdelegate block omitted it, so
      # this call used to raise UndefinedFunctionError.
      assert Protocol.server_error() == -32000
    end

    test "task_not_ready returns -32004" do
      assert Protocol.task_not_ready() == -32004
    end

    test "request_cancelled returns -32800" do
      assert Protocol.request_cancelled() == -32800
    end
  end

  describe "methods/0" do
    test "returns all supported MCP methods, including the six it used to miss" do
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
      assert methods["completion/complete"] == :complete
      assert methods["logging/setLevel"] == :set_log_level
      assert methods["resources/subscribe"] == :subscribe_resource
      assert methods["resources/unsubscribe"] == :unsubscribe_resource

      # Previously absent from methods/0 while being routed by the handler.
      assert methods["resources/templates/list"] == :list_resource_templates
      assert methods["tasks/get"] == :get_task
      assert methods["tasks/cancel"] == :cancel_task
      assert methods["tasks/result"] == :task_result
      assert methods["tasks/list"] == :list_tasks
      assert methods["notifications/cancelled"] == :cancelled
    end

    test "every listed method is actually routed by the handler" do
      # methods/0 and the dispatcher are the same map, so this pins the other
      # direction: a method in the table with no route clause.
      notifications = ["notifications/initialized", "notifications/cancelled"]

      for {method, _name} <- Protocol.methods(), method not in notifications do
        request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => %{}}
        response = ConduitMcp.Handler.handle_request(request, ConduitMcp.TestServer)

        # A server callback may legitimately answer "not found"; what must not
        # happen is the *router* rejecting a method it publishes.
        message = get_in(response, ["error", "message"]) || ""

        refute message =~ "Method not found",
               "#{method} is listed in methods/0 but the handler does not route it"
      end
    end

    test "no published method reaches the rescue's internal_error" do
      # `route/5` has no catch-all, so a table entry with no clause raises
      # FunctionClauseError, which the rescue converts into -32603. That makes
      # a missing clause a runtime discovery reported to the client as a server
      # bug. This is the assertion that turns it into a test failure.
      notifications = ["notifications/initialized", "notifications/cancelled"]

      for {method, _name} <- Protocol.methods(), method not in notifications do
        request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => %{}}
        response = ConduitMcp.Handler.handle_request(request, ConduitMcp.TestServer)

        refute get_in(response, ["error", "code"]) == Protocol.internal_error(),
               "#{method} is published by methods/0 but has no route/5 clause"
      end
    end

    test "every published notification is routed, none logs as unknown" do
      # The same drift in the other dispatcher: `handle_notification/3` used a
      # hand-written case over string literals, so a table entry with no clause
      # was advertised and then dropped as "Unknown notification".
      for method <- ["notifications/initialized", "notifications/cancelled"] do
        assert Map.has_key?(Protocol.methods(), method)

        # A valid notification carries no id.
        notification = %{"jsonrpc" => "2.0", "method" => method, "params" => %{}}

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            ConduitMcp.Handler.handle_request(notification, ConduitMcp.TestServer)
          end)

        refute log =~ "Unknown notification",
               "#{method} is published by methods/0 but handle_notification/3 drops it"
      end
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
      response =
        Protocol.error_response(
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

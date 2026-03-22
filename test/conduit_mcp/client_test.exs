defmodule ConduitMcp.ClientTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client

  describe "create_message_request/2" do
    test "builds a sampling request" do
      messages = [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}]
      request = Client.create_message_request(messages, max_tokens: 1000)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "sampling/createMessage"
      assert request["params"]["messages"] == messages
      assert request["params"]["maxTokens"] == 1000
      assert is_integer(request["id"])
    end

    test "omits nil options" do
      request = Client.create_message_request([])
      refute Map.has_key?(request["params"], "maxTokens")
      refute Map.has_key?(request["params"], "systemPrompt")
    end
  end

  describe "elicit_request/2" do
    test "builds an elicitation request" do
      schema = %{"type" => "object", "properties" => %{"key" => %{"type" => "string"}}}
      request = Client.elicit_request("Enter your key", schema)

      assert request["method"] == "elicitation/create"
      assert request["params"]["message"] == "Enter your key"
      assert request["params"]["requestedSchema"] == schema
    end
  end

  describe "list_roots_request/0" do
    test "builds a roots list request" do
      request = Client.list_roots_request()
      assert request["method"] == "roots/list"
      assert request["jsonrpc"] == "2.0"
    end
  end

  describe "progress_notification/3" do
    test "builds a progress notification" do
      notification = Client.progress_notification("token-1", 50, total: 100, message: "Half done")

      assert notification["method"] == "notifications/progress"
      assert notification["params"]["progressToken"] == "token-1"
      assert notification["params"]["progress"] == 50
      assert notification["params"]["total"] == 100
      assert notification["params"]["message"] == "Half done"
      refute Map.has_key?(notification, "id")
    end
  end

  describe "log_notification/3" do
    test "builds a log notification" do
      notification = Client.log_notification("info", "Server started", logger: "my-server")

      assert notification["method"] == "notifications/message"
      assert notification["params"]["level"] == "info"
      assert notification["params"]["data"] == "Server started"
      assert notification["params"]["logger"] == "my-server"
    end
  end

  describe "resource notifications" do
    test "resource_updated_notification/1" do
      n = Client.resource_updated_notification("file:///test.txt")
      assert n["method"] == "notifications/resources/updated"
      assert n["params"]["uri"] == "file:///test.txt"
    end

    test "resource_list_changed_notification/0" do
      n = Client.resource_list_changed_notification()
      assert n["method"] == "notifications/resources/list_changed"
    end

    test "tool_list_changed_notification/0" do
      n = Client.tool_list_changed_notification()
      assert n["method"] == "notifications/tools/list_changed"
    end

    test "prompt_list_changed_notification/0" do
      n = Client.prompt_list_changed_notification()
      assert n["method"] == "notifications/prompts/list_changed"
    end
  end
end

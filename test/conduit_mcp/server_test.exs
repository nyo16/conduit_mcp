defmodule ConduitMcp.ServerTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.TestServer

  describe "handle_list_tools callback" do
    test "returns tools list" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_list_tools(conn)
      assert is_map(result)
      assert Map.has_key?(result, "tools")
      assert is_list(result["tools"])
      assert length(result["tools"]) == 2
    end

    test "tools have required fields" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_list_tools(conn)
      tool = hd(result["tools"])
      assert Map.has_key?(tool, "name")
      assert Map.has_key?(tool, "description")
      assert Map.has_key?(tool, "inputSchema")
    end
  end

  describe "handle_call_tool callback" do
    test "executes tool successfully" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_call_tool(conn, "echo", %{"message" => "hello"})
      assert is_map(result)
      assert result["content"] == [%{"type" => "text", "text" => "hello"}]
    end

    test "returns error for failing tool" do
      conn = %Plug.Conn{}
      {:error, error} = TestServer.handle_call_tool(conn, "fail", %{})
      assert error["code"] == -32000
      assert error["message"] == "Tool execution failed"
    end

    test "returns error for unknown tool" do
      conn = %Plug.Conn{}
      {:error, error} = TestServer.handle_call_tool(conn, "unknown", %{})
      assert error["code"] == ConduitMcp.Errors.invalid_params()
      assert error["message"] == "Tool not found"
    end
  end

  describe "handle_list_resources callback" do
    test "returns resources list" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_list_resources(conn)
      assert is_map(result)
      assert Map.has_key?(result, "resources")
      assert is_list(result["resources"])
      assert length(result["resources"]) == 1
    end

    test "resources have required fields" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_list_resources(conn)
      resource = hd(result["resources"])
      assert Map.has_key?(resource, "uri")
      assert Map.has_key?(resource, "name")
    end
  end

  describe "handle_read_resource callback" do
    test "reads resource successfully" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_read_resource(conn, "test://resource1")
      assert is_map(result)
      assert Map.has_key?(result, "contents")
      assert is_list(result["contents"])
    end

    test "returns error for unknown resource" do
      conn = %Plug.Conn{}
      {:error, error} = TestServer.handle_read_resource(conn, "test://unknown")
      assert error["code"] == ConduitMcp.Errors.resource_not_found()
      assert error["message"] == "Resource not found"
    end
  end

  describe "handle_list_prompts callback" do
    test "returns prompts list" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_list_prompts(conn)
      assert is_map(result)
      assert Map.has_key?(result, "prompts")
      assert is_list(result["prompts"])
      assert length(result["prompts"]) == 1
    end

    test "prompts have required fields" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_list_prompts(conn)
      prompt = hd(result["prompts"])
      assert Map.has_key?(prompt, "name")
      assert Map.has_key?(prompt, "description")
    end
  end

  describe "handle_get_prompt callback" do
    test "gets prompt successfully with arguments" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_get_prompt(conn, "greeting", %{"name" => "Alice"})
      assert is_map(result)
      assert Map.has_key?(result, "messages")
      assert is_list(result["messages"])
      message = hd(result["messages"])
      assert message["content"]["text"] == "Hello, Alice!"
    end

    test "gets prompt with default arguments" do
      conn = %Plug.Conn{}
      {:ok, result} = TestServer.handle_get_prompt(conn, "greeting", %{})
      message = hd(result["messages"])
      assert message["content"]["text"] == "Hello, World!"
    end

    test "returns error for unknown prompt" do
      conn = %Plug.Conn{}
      {:error, error} = TestServer.handle_get_prompt(conn, "unknown", %{})
      assert error["code"] == ConduitMcp.Errors.invalid_params()
      assert error["message"] == "Prompt not found"
    end
  end

  describe "minimal server implementation" do
    defmodule MinimalServer do
      use ConduitMcp.Server, dsl: false

      @impl true
      def handle_list_tools(_conn) do
        {:ok, %{"tools" => []}}
      end

      @impl true
      def handle_call_tool(_conn, _name, _params) do
        {:error, %{"code" => -32601, "message" => "No tools available"}}
      end
    end

    test "minimal server can respond" do
      conn = %Plug.Conn{}

      {:ok, result} = MinimalServer.handle_list_tools(conn)
      assert result == %{"tools" => []}

      # Default implementations should work
      {:ok, resources_result} = MinimalServer.handle_list_resources(conn)
      assert resources_result["resources"] == []

      {:ok, prompts_result} = MinimalServer.handle_list_prompts(conn)
      assert prompts_result["prompts"] == []
    end

    # RC9's acceptance is identical codes across DSL, Endpoint and manual mode.
    # `ConduitMcp.TestServer` overrides every not-found callback with its own
    # literal, so the library defaults in `ConduitMcp.Server`'s `__using__`
    # were never reached by any test - reverting them would have left the suite
    # green. This server overrides nothing but `handle_list_tools/1`.
    defmodule DefaultsOnlyServer do
      use ConduitMcp.Server, dsl: false

      @impl true
      def handle_list_tools(_conn) do
        {:ok, %{"tools" => []}}
      end
    end

    test "manual mode's default not-found codes match DSL and Endpoint mode" do
      conn = %Plug.Conn{}

      assert {:error, tool} = DefaultsOnlyServer.handle_call_tool(conn, "nope", %{})
      assert tool["code"] == ConduitMcp.Errors.invalid_params()
      assert tool["message"] == "Unknown tool: nope"

      assert {:error, resource} = DefaultsOnlyServer.handle_read_resource(conn, "test://nope")
      assert resource["code"] == ConduitMcp.Errors.resource_not_found()
      assert resource["message"] == "Resource not found: test://nope"

      assert {:error, prompt} = DefaultsOnlyServer.handle_get_prompt(conn, "nope", %{})
      assert prompt["code"] == ConduitMcp.Errors.invalid_params()
      assert prompt["message"] == "Unknown prompt: nope"
    end
  end
end

defmodule ConduitMcp.ServerTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.TestServer

  describe "server lifecycle" do
    test "starts with start_link/1" do
      {:ok, pid} = TestServer.start_link([])
      assert Process.alive?(pid)
      Agent.stop(pid)
    end

    test "initializes with mcp_init options" do
      {:ok, pid} = TestServer.start_link(custom_key: "custom_value")
      config = Agent.get(pid, & &1)
      assert config.custom_key == "custom_value"
      Agent.stop(pid)
    end

    test "registers with module name" do
      {:ok, _pid} = TestServer.start_link([])
      assert Process.whereis(TestServer) != nil
      Agent.stop(TestServer)
    end
  end

  describe "handle_list_tools callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "returns tools list" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_list_tools(config)
      assert is_map(result)
      assert Map.has_key?(result, "tools")
      assert is_list(result["tools"])
      assert length(result["tools"]) == 2
    end

    test "tools have required fields" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_list_tools(config)
      tool = hd(result["tools"])
      assert Map.has_key?(tool, "name")
      assert Map.has_key?(tool, "description")
      assert Map.has_key?(tool, "inputSchema")
    end
  end

  describe "handle_call_tool callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "executes tool successfully" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_call_tool("echo", %{"message" => "hello"}, config)
      assert is_map(result)
      assert result["content"] == [%{"type" => "text", "text" => "hello"}]
    end

    test "returns error for failing tool" do
      config = TestServer.get_config()
      {:error, error} = TestServer.handle_call_tool("fail", %{}, config)
      assert error["code"] == -32000
      assert error["message"] == "Tool execution failed"
    end

    test "returns error for unknown tool" do
      config = TestServer.get_config()
      {:error, error} = TestServer.handle_call_tool("unknown", %{}, config)
      assert error["code"] == -32601
      assert error["message"] == "Tool not found"
    end
  end

  describe "handle_list_resources callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "returns resources list" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_list_resources(config)
      assert is_map(result)
      assert Map.has_key?(result, "resources")
      assert is_list(result["resources"])
      assert length(result["resources"]) == 1
    end

    test "resources have required fields" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_list_resources(config)
      resource = hd(result["resources"])
      assert Map.has_key?(resource, "uri")
      assert Map.has_key?(resource, "name")
    end
  end

  describe "handle_read_resource callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "reads resource successfully" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_read_resource("test://resource1", config)
      assert is_map(result)
      assert Map.has_key?(result, "contents")
      assert is_list(result["contents"])
    end

    test "returns error for unknown resource" do
      config = TestServer.get_config()
      {:error, error} = TestServer.handle_read_resource("test://unknown", config)
      assert error["code"] == -32601
      assert error["message"] == "Resource not found"
    end
  end

  describe "handle_list_prompts callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "returns prompts list" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_list_prompts(config)
      assert is_map(result)
      assert Map.has_key?(result, "prompts")
      assert is_list(result["prompts"])
      assert length(result["prompts"]) == 1
    end

    test "prompts have required fields" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_list_prompts(config)
      prompt = hd(result["prompts"])
      assert Map.has_key?(prompt, "name")
      assert Map.has_key?(prompt, "description")
    end
  end

  describe "handle_get_prompt callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "gets prompt successfully with arguments" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_get_prompt("greeting", %{"name" => "Alice"}, config)
      assert is_map(result)
      assert Map.has_key?(result, "messages")
      assert is_list(result["messages"])
      message = hd(result["messages"])
      assert message["content"]["text"] == "Hello, Alice!"
    end

    test "gets prompt with default arguments" do
      config = TestServer.get_config()
      {:ok, result} = TestServer.handle_get_prompt("greeting", %{}, config)
      message = hd(result["messages"])
      assert message["content"]["text"] == "Hello, World!"
    end

    test "returns error for unknown prompt" do
      config = TestServer.get_config()
      {:error, error} = TestServer.handle_get_prompt("unknown", %{}, config)
      assert error["code"] == -32601
      assert error["message"] == "Prompt not found"
    end
  end

  describe "minimal server implementation" do
    defmodule MinimalServer do
      use ConduitMcp.Server

      @impl true
      def mcp_init(_opts) do
        {:ok, %{}}
      end

      @impl true
      def handle_list_tools(_config) do
        {:ok, %{"tools" => []}}
      end

      @impl true
      def handle_call_tool(_name, _params, _config) do
        {:error, %{"code" => -32601, "message" => "No tools available"}}
      end
    end

    test "minimal server can start and respond" do
      {:ok, pid} = MinimalServer.start_link([])
      config = MinimalServer.get_config()

      {:ok, result} = MinimalServer.handle_list_tools(config)
      assert result == %{"tools" => []}

      # Default implementations should work
      {:ok, resources_result} = MinimalServer.handle_list_resources(config)
      assert resources_result["resources"] == []

      {:ok, prompts_result} = MinimalServer.handle_list_prompts(config)
      assert prompts_result["prompts"] == []

      Agent.stop(pid)
    end
  end
end

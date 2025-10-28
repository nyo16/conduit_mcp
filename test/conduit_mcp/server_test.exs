defmodule ConduitMcp.ServerTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.TestServer

  describe "server lifecycle" do
    test "starts with start_link/1" do
      {:ok, pid} = TestServer.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "initializes with mcp_init options" do
      {:ok, pid} = TestServer.start_link(custom_key: "custom_value")
      state = :sys.get_state(pid)
      assert state.custom_key == "custom_value"
      GenServer.stop(pid)
    end

    test "registers with module name" do
      {:ok, _pid} = TestServer.start_link([])
      assert Process.whereis(TestServer) != nil
      GenServer.stop(TestServer)
    end
  end

  describe "handle_list_tools callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "returns tools list" do
      result = GenServer.call(TestServer, {:list_tools})
      assert is_map(result)
      assert Map.has_key?(result, "tools")
      assert is_list(result["tools"])
      assert length(result["tools"]) == 2
    end

    test "tools have required fields" do
      result = GenServer.call(TestServer, {:list_tools})
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
      result = GenServer.call(TestServer, {:call_tool, "echo", %{"message" => "hello"}})
      assert is_map(result)
      assert result["content"] == [%{"type" => "text", "text" => "hello"}]
    end

    test "returns error for failing tool" do
      result = GenServer.call(TestServer, {:call_tool, "fail", %{}})
      assert {:error, error} = result
      assert error.code == -32000
      assert error.message == "Tool execution failed"
    end

    test "returns error for unknown tool" do
      result = GenServer.call(TestServer, {:call_tool, "unknown", %{}})
      assert {:error, error} = result
      assert error.code == -32601
      assert error.message == "Tool not found"
    end

    test "updates state on successful execution" do
      initial_state = :sys.get_state(TestServer)
      initial_count = initial_state.call_count

      GenServer.call(TestServer, {:call_tool, "echo", %{"message" => "test"}})

      new_state = :sys.get_state(TestServer)
      assert new_state.call_count == initial_count + 1
    end
  end

  describe "handle_list_resources callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "returns resources list" do
      result = GenServer.call(TestServer, {:list_resources})
      assert is_map(result)
      assert Map.has_key?(result, "resources")
      assert is_list(result["resources"])
      assert length(result["resources"]) == 1
    end

    test "resources have required fields" do
      result = GenServer.call(TestServer, {:list_resources})
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
      result = GenServer.call(TestServer, {:read_resource, "test://resource1"})
      assert is_map(result)
      assert Map.has_key?(result, "contents")
      assert is_list(result["contents"])
    end

    test "returns error for unknown resource" do
      result = GenServer.call(TestServer, {:read_resource, "test://unknown"})
      assert {:error, error} = result
      assert error.code == -32601
      assert error.message == "Resource not found"
    end
  end

  describe "handle_list_prompts callback" do
    setup do
      {:ok, _pid} = start_supervised({TestServer, []})
      :ok
    end

    test "returns prompts list" do
      result = GenServer.call(TestServer, {:list_prompts})
      assert is_map(result)
      assert Map.has_key?(result, "prompts")
      assert is_list(result["prompts"])
      assert length(result["prompts"]) == 1
    end

    test "prompts have required fields" do
      result = GenServer.call(TestServer, {:list_prompts})
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
      result = GenServer.call(TestServer, {:get_prompt, "greeting", %{"name" => "Alice"}})
      assert is_map(result)
      assert Map.has_key?(result, "messages")
      assert is_list(result["messages"])
      message = hd(result["messages"])
      assert message["content"]["text"] == "Hello, Alice!"
    end

    test "gets prompt with default arguments" do
      result = GenServer.call(TestServer, {:get_prompt, "greeting", %{}})
      message = hd(result["messages"])
      assert message["content"]["text"] == "Hello, World!"
    end

    test "returns error for unknown prompt" do
      result = GenServer.call(TestServer, {:get_prompt, "unknown", %{}})
      assert {:error, error} = result
      assert error.code == -32601
      assert error.message == "Prompt not found"
    end
  end

  describe "terminate callback" do
    test "calls terminate on stop" do
      {:ok, pid} = TestServer.start_link([])
      assert :ok == GenServer.stop(pid)
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
      def handle_list_tools(state) do
        {:reply, %{"tools" => []}, state}
      end

      @impl true
      def handle_call_tool(_name, _params, state) do
        {:error, %{code: -32601, message: "No tools available"}, state}
      end
    end

    test "minimal server can start and respond" do
      {:ok, pid} = MinimalServer.start_link([])

      result = GenServer.call(MinimalServer, {:list_tools})
      assert result == %{"tools" => []}

      # Default implementations should work
      resources_result = GenServer.call(MinimalServer, {:list_resources})
      assert resources_result[:resources] == []

      prompts_result = GenServer.call(MinimalServer, {:list_prompts})
      assert prompts_result[:prompts] == []

      GenServer.stop(pid)
    end
  end
end

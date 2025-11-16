defmodule ConduitMcp.DSLTest do
  use ExUnit.Case, async: true

  # Test server using DSL
  defmodule DSLTestServer do
    use ConduitMcp.Server

    tool "simple", "Simple tool" do
      param :message, :string, "A message", required: true

      handle fn _conn, %{"message" => msg} ->
        text("Got: #{msg}")
      end
    end

    tool "with_enum", "Tool with enum" do
      param :action, :string, "Action to perform", enum: ["start", "stop", "restart"], required: true

      handle fn _conn, %{"action" => action} ->
        text("Action: #{action}")
      end
    end

    tool "with_default", "Tool with default value" do
      param :name, :string, "Name", default: "World"

      handle fn _conn, params ->
        name = params["name"] || "World"
        text("Hello, #{name}!")
      end
    end

    tool "with_mfa", "Tool using MFA handler" do
      param :value, :number, "A number", required: true

      handle __MODULE__, :double_value
    end

    # TODO: Add nested object support in future version
    # tool "nested_object", "Tool with nested object" do
    #   param :user, :object, "User data", required: true do
    #     field :name, :string, "Full name", required: true
    #     field :email, :string, "Email address", required: true
    #   end
    #   handle fn _conn, params -> text("User: #{params["user"]["name"]}") end
    # end

    # MFA handler implementation
    def double_value(_conn, %{"value" => val}) do
      text("Result: #{val * 2}")
    end

    # Prompt examples
    prompt "code_review", "Code review assistant" do
      arg :code, :string, "Code to review", required: true
      arg :language, :string, "Programming language", default: "elixir"

      get fn _conn, args ->
        language = args["language"] || "elixir"
        [
          system("You are an expert code reviewer"),
          user("Review this #{language} code:\n#{args["code"]}")
        ]
      end
    end

    prompt "simple_prompt", "Simple prompt" do
      arg :topic, :string, "Topic to discuss"

      get fn _conn, args ->
        [user("Tell me about #{args["topic"] || "Elixir"}")]
      end
    end

    # Resource examples
    resource "user://{id}" do
      description "User profile data"
      mime_type "application/json"

      read fn _conn, params, _opts ->
        user_id = params["id"]
        json(%{id: user_id, name: "User #{user_id}", email: "user#{user_id}@example.com"})
      end
    end

    resource "static://readme" do
      description "Project README"
      mime_type "text/markdown"

      read fn _conn, _params, _opts ->
        text("# README\n\nThis is a test README.")
      end
    end
  end

  describe "DSL tool definitions" do
    test "generates tool schemas correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      tools = result["tools"]
      assert is_list(tools)
      assert length(tools) == 4  # simple, with_enum, with_default, with_mfa

      # Check simple tool
      simple_tool = Enum.find(tools, fn t -> t["name"] == "simple" end)
      assert simple_tool["description"] == "Simple tool"
      assert simple_tool["inputSchema"]["type"] == "object"
      assert simple_tool["inputSchema"]["properties"]["message"]["type"] == "string"
      assert simple_tool["inputSchema"]["required"] == ["message"]
    end

    test "handles enum parameters correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      enum_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_enum" end)
      assert enum_tool["inputSchema"]["properties"]["action"]["enum"] == ["start", "stop", "restart"]
    end

    test "handles default values correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      default_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_default" end)
      assert default_tool["inputSchema"]["properties"]["name"]["default"] == "World"
    end

    # TODO: Test nested objects when implemented
    # test "handles nested objects correctly" do
    #   ...
    # end
  end

  describe "DSL tool execution" do
    test "executes simple tool with inline handler" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "simple", %{"message" => "test"})

      assert result["content"] == [%{"type" => "text", "text" => "Got: test"}]
    end

    test "executes tool with MFA handler" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_mfa", %{"value" => 21})

      assert result["content"] == [%{"type" => "text", "text" => "Result: 42"}]
    end

    # TODO: Test nested objects when implemented
    # test "executes tool with nested object parameter" do
    #   ...
    # end

    test "returns error for unknown tool" do
      conn = %Plug.Conn{}
      {:error, error} = DSLTestServer.handle_call_tool(conn, "unknown", %{})

      assert error["code"] == -32601
      assert error["message"] =~ "Tool not found"
    end
  end

  describe "DSL prompt definitions" do
    test "generates prompt schemas correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_prompts(conn)

      prompts = result["prompts"]
      assert is_list(prompts)
      assert length(prompts) == 2

      code_review = Enum.find(prompts, fn p -> p["name"] == "code_review" end)
      assert code_review["description"] == "Code review assistant"
      assert is_list(code_review["arguments"])
    end

    test "executes prompt with inline handler" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_get_prompt(conn, "code_review", %{
        "code" => "def hello, do: :world",
        "language" => "elixir"
      })

      messages = result["messages"]
      assert length(messages) == 2
      assert hd(messages)["role"] == "system"
      assert Enum.at(messages, 1)["role"] == "user"
      assert Enum.at(messages, 1)["content"]["text"] =~ "elixir"
    end

    test "executes prompt with default arguments" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_get_prompt(conn, "code_review", %{
        "code" => "def test, do: :ok"
      })

      messages = result["messages"]
      # Should use default language "elixir"
      assert Enum.at(messages, 1)["content"]["text"] =~ "elixir"
    end
  end

  describe "DSL resource definitions" do
    test "generates resource schemas correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_resources(conn)

      resources = result["resources"]
      assert is_list(resources)
      assert length(resources) == 2

      user_resource = Enum.find(resources, fn r -> r["uri"] == "user://{id}" end)
      assert user_resource["description"] == "User profile data"
      assert user_resource["mimeType"] == "application/json"

      static_resource = Enum.find(resources, fn r -> r["uri"] == "static://readme" end)
      assert static_resource["mimeType"] == "text/markdown"
    end

    test "executes resource read with URI template" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_read_resource(conn, "user://{id}")

      # Should return JSON content
      assert is_map(result)
      content = hd(result["content"])
      assert content["type"] == "text"

      # Verify it's valid JSON
      assert {:ok, data} = Jason.decode(content["text"])
      assert is_map(data)
    end

    test "executes static resource read" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_read_resource(conn, "static://readme")

      assert result["content"] == [%{"type" => "text", "text" => "# README\n\nThis is a test README."}]
    end
  end

  describe "helper macros" do
    test "text/1 helper returns correct format" do
      # This is tested indirectly through tool execution
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "simple", %{"message" => "hello"})

      assert result["content"] == [%{"type" => "text", "text" => "Got: hello"}]
    end

    test "json/1 helper returns JSON-encoded content" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_read_resource(conn, "user://{id}")

      content_text = hd(result["content"])["text"]
      assert {:ok, _data} = Jason.decode(content_text)
    end
  end

  describe "schema builder" do
    alias ConduitMcp.DSL.SchemaBuilder

    test "builds tool schema with simple params" do
      tool_def = %{
        name: "test_tool",
        description: "Test tool",
        params: [
          %{name: :input, type: :string, description: "Input", opts: [required: true]},
          %{name: :count, type: :number, description: "Count", opts: []}
        ]
      }

      schema = SchemaBuilder.build_tool_schema(tool_def)

      assert schema["name"] == "test_tool"
      assert schema["description"] == "Test tool"
      assert schema["inputSchema"]["type"] == "object"
      assert schema["inputSchema"]["properties"]["input"]["type"] == "string"
      assert schema["inputSchema"]["properties"]["count"]["type"] == "number"
      assert schema["inputSchema"]["required"] == ["input"]
    end

    test "builds schema with enum" do
      tool_def = %{
        name: "test",
        description: "Test",
        params: [
          %{name: :action, type: :string, description: "Action", opts: [enum: ["a", "b", "c"], required: true]}
        ]
      }

      schema = SchemaBuilder.build_tool_schema(tool_def)

      assert schema["inputSchema"]["properties"]["action"]["enum"] == ["a", "b", "c"]
    end

    test "builds schema with default value" do
      tool_def = %{
        name: "test",
        description: "Test",
        params: [
          %{name: :opt, type: :string, description: "Option", opts: [default: "default_val"]}
        ]
      }

      schema = SchemaBuilder.build_tool_schema(tool_def)

      assert schema["inputSchema"]["properties"]["opt"]["default"] == "default_val"
    end

    # TODO: Test nested objects when fully implemented
    # test "builds schema with nested object" do ...  end
    # test "builds schema with array" do ... end

    test "builds prompt schema" do
      prompt_def = %{
        name: "test_prompt",
        description: "Test prompt",
        args: [
          %{name: :input, type: :string, description: "Input", opts: [required: true]},
          %{name: :style, type: :string, description: "Style", opts: [default: "casual"]}
        ]
      }

      schema = SchemaBuilder.build_prompt_schema(prompt_def)

      assert schema["name"] == "test_prompt"
      assert schema["description"] == "Test prompt"
      assert is_list(schema["arguments"])
      assert length(schema["arguments"]) == 2

      input_arg = Enum.find(schema["arguments"], fn a -> a["name"] == "input" end)
      assert input_arg["required"] == true
    end

    test "builds resource schema" do
      resource_def = %{
        uri: "file://{path}",
        description: "File resource",
        mime_type: "text/plain"
      }

      schema = SchemaBuilder.build_resource_schema(resource_def)

      assert schema["uri"] == "file://{path}"
      assert schema["description"] == "File resource"
      assert schema["mimeType"] == "text/plain"
    end
  end

  describe "helper functions" do
    test "text/1 creates proper response format" do
      # Compile-time test - verify the macro works
      import ConduitMcp.DSL.Helpers

      result = text("Hello")
      assert result == {:ok, %{"content" => [%{"type" => "text", "text" => "Hello"}]}}
    end

    test "json/1 encodes data to JSON" do
      import ConduitMcp.DSL.Helpers

      result = json(%{key: "value", count: 42})
      assert {:ok, %{"content" => [%{"type" => "text", "text" => json_str}]}} = result
      assert {:ok, %{"key" => "value", "count" => 42}} = Jason.decode(json_str)
    end

    test "error/1 creates error response" do
      import ConduitMcp.DSL.Helpers

      result = error("Not found")
      assert result == {:error, %{"code" => -32000, "message" => "Not found"}}
    end

    test "error/2 supports custom error code" do
      import ConduitMcp.DSL.Helpers

      result = error("Invalid params", -32602)
      assert result == {:error, %{"code" => -32602, "message" => "Invalid params"}}
    end

    test "system/1 creates system message" do
      import ConduitMcp.DSL.Helpers

      msg = system("You are helpful")
      assert msg == %{
        "role" => "system",
        "content" => %{"type" => "text", "text" => "You are helpful"}
      }
    end

    test "user/1 creates user message" do
      import ConduitMcp.DSL.Helpers

      msg = user("Hello")
      assert msg == %{
        "role" => "user",
        "content" => %{"type" => "text", "text" => "Hello"}
      }
    end

    test "assistant/1 creates assistant message" do
      import ConduitMcp.DSL.Helpers

      msg = assistant("Hi there")
      assert msg == %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "Hi there"}
      }
    end

    test "texts/1 creates multiple content items" do
      import ConduitMcp.DSL.Helpers

      result = texts(["Line 1", "Line 2", "Line 3"])

      assert result == [
        %{"type" => "text", "text" => "Line 1"},
        %{"type" => "text", "text" => "Line 2"},
        %{"type" => "text", "text" => "Line 3"}
      ]
    end
  end

  describe "manual mode (dsl: false)" do
    defmodule ManualServer do
      use ConduitMcp.Server, dsl: false

      @tools [
        %{
          "name" => "manual_tool",
          "description" => "Manually defined tool",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "input" => %{"type" => "string"}
            },
            "required" => ["input"]
          }
        }
      ]

      @impl true
      def handle_list_tools(_conn) do
        {:ok, %{"tools" => @tools}}
      end

      @impl true
      def handle_call_tool(_conn, "manual_tool", %{"input" => input}) do
        {:ok, %{"content" => [%{"type" => "text", "text" => "Manual: #{input}"}]}}
      end

      @impl true
      def handle_call_tool(_conn, _name, _params) do
        {:error, %{"code" => -32601, "message" => "Tool not found"}}
      end
    end

    test "manual mode still works without DSL" do
      conn = %Plug.Conn{}
      {:ok, result} = ManualServer.handle_list_tools(conn)

      tools = result["tools"]
      assert length(tools) == 1
      assert hd(tools)["name"] == "manual_tool"
    end

    test "manual mode executes tools correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = ManualServer.handle_call_tool(conn, "manual_tool", %{"input" => "test"})

      assert result["content"] == [%{"type" => "text", "text" => "Manual: test"}]
    end
  end

  describe "edge cases" do
    test "tool with no parameters" do
      defmodule NoParamsServer do
        use ConduitMcp.Server

        tool "ping", "Simple ping" do
          handle fn _conn, _params ->
            text("pong")
          end
        end
      end

      conn = %Plug.Conn{}
      {:ok, result} = NoParamsServer.handle_list_tools(conn)

      ping_tool = hd(result["tools"])
      assert ping_tool["name"] == "ping"
      # Should have empty or minimal schema
      assert ping_tool["inputSchema"]["type"] == "object"

      {:ok, exec_result} = NoParamsServer.handle_call_tool(conn, "ping", %{})
      assert exec_result["content"] == [%{"type" => "text", "text" => "pong"}]
    end

    test "server with no tools defined" do
      defmodule EmptyServer do
        use ConduitMcp.Server
        # No tools defined
      end

      conn = %Plug.Conn{}
      {:ok, result} = EmptyServer.handle_list_tools(conn)

      assert result["tools"] == []
    end
  end
end

defmodule ConduitMcp.DSLTest do
  use ExUnit.Case, async: true

  # Test server using DSL
  defmodule DSLTestServer do
    use ConduitMcp.Server

    tool "simple", "Simple tool" do
      param(:message, :string, "A message", required: true)

      handle(fn _conn, %{"message" => msg} ->
        text("Got: #{msg}")
      end)
    end

    tool "with_enum", "Tool with enum" do
      param(:action, :string, "Action to perform",
        enum: ["start", "stop", "restart"],
        required: true
      )

      handle(fn _conn, %{"action" => action} ->
        text("Action: #{action}")
      end)
    end

    tool "with_default", "Tool with default value" do
      param(:name, :string, "Name", default: "World")

      handle(fn _conn, params ->
        name = params["name"] || "World"
        text("Hello, #{name}!")
      end)
    end

    tool "with_mfa", "Tool using MFA handler" do
      param(:value, :number, "A number", required: true)

      handle(__MODULE__, :double_value)
    end

    tool "with_capture", "Tool using function capture" do
      param(:value, :number, "A number", required: true)

      handle(&__MODULE__.triple_value/2)
    end

    tool "with_boolean", "Tool with boolean parameter" do
      param(:enabled, :boolean, "Enable feature", required: true)
      param(:count, :integer, "Item count", default: 0)

      handle(fn _conn, params ->
        enabled = params["enabled"]
        count = params["count"] || 0
        text("Enabled: #{enabled}, Count: #{count}")
      end)
    end

    # MFA handler implementations
    def double_value(_conn, %{"value" => val}) do
      text("Result: #{val * 2}")
    end

    def triple_value(_conn, %{"value" => val}) do
      text("Result: #{val * 3}")
    end

    # Prompt examples
    prompt "code_review", "Code review assistant" do
      arg(:code, :string, "Code to review", required: true)
      arg(:language, :string, "Programming language", default: "elixir")

      get(fn _conn, args ->
        language = args["language"] || "elixir"

        [
          system("You are an expert code reviewer"),
          user("Review this #{language} code:\n#{args["code"]}")
        ]
      end)
    end

    prompt "simple_prompt", "Simple prompt" do
      arg(:topic, :string, "Topic to discuss")

      get(fn _conn, args ->
        [user("Tell me about #{args["topic"] || "Elixir"}")]
      end)
    end

    # Resource examples
    resource "user://{id}" do
      description("User profile data")
      mime_type("application/json")

      read(fn _conn, params, _opts ->
        user_id = params["id"]
        json(%{id: user_id, name: "User #{user_id}", email: "user#{user_id}@example.com"})
      end)
    end

    resource "static://readme" do
      description("Project README")
      mime_type("text/markdown")

      read(fn _conn, _params, _opts ->
        text("# README\n\nThis is a test README.")
      end)
    end
  end

  describe "DSL tool definitions" do
    test "generates tool schemas correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      tools = result["tools"]
      assert is_list(tools)
      # simple, with_enum, with_default, with_mfa, with_capture, with_boolean
      assert length(tools) == 6

      # Check simple tool
      simple_tool = Enum.find(tools, fn t -> t["name"] == "simple" end)
      assert simple_tool["description"] == "Simple tool"
      assert simple_tool["inputSchema"]["type"] == "object"
      assert simple_tool["inputSchema"]["properties"]["message"]["type"] == "string"
      assert simple_tool["inputSchema"]["required"] == ["message"]
    end

    test "handles boolean and integer types correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      bool_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_boolean" end)
      assert bool_tool["inputSchema"]["properties"]["enabled"]["type"] == "boolean"
      assert bool_tool["inputSchema"]["properties"]["count"]["type"] == "integer"
      assert bool_tool["inputSchema"]["properties"]["count"]["default"] == 0
      assert bool_tool["inputSchema"]["required"] == ["enabled"]
    end

    test "generates correct required fields list" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      # Tool with multiple required params
      simple_tool = Enum.find(result["tools"], fn t -> t["name"] == "simple" end)
      assert simple_tool["inputSchema"]["required"] == ["message"]

      # Tool with no required params
      default_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_default" end)
      # Should have no required field or empty list
      refute Map.has_key?(default_tool["inputSchema"], "required") or
               default_tool["inputSchema"]["required"] == []
    end

    test "handles enum parameters correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      enum_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_enum" end)

      assert enum_tool["inputSchema"]["properties"]["action"]["enum"] == [
               "start",
               "stop",
               "restart"
             ]
    end

    test "handles default values correctly" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      default_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_default" end)
      assert default_tool["inputSchema"]["properties"]["name"]["default"] == "World"
    end
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

    test "executes tool with function capture handler" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_capture", %{"value" => 10})

      assert result["content"] == [%{"type" => "text", "text" => "Result: 30"}]
    end

    test "executes tool with boolean and integer parameters" do
      conn = %Plug.Conn{}

      {:ok, result} =
        DSLTestServer.handle_call_tool(conn, "with_boolean", %{"enabled" => true, "count" => 5})

      assert result["content"] == [%{"type" => "text", "text" => "Enabled: true, Count: 5"}]
    end

    test "executes tool with boolean using default value" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_boolean", %{"enabled" => false})

      assert result["content"] == [%{"type" => "text", "text" => "Enabled: false, Count: 0"}]
    end

    test "returns error for unknown tool" do
      conn = %Plug.Conn{}
      {:error, error} = DSLTestServer.handle_call_tool(conn, "unknown", %{})

      # -32602 per the MCP spec ("Unknown tool: invalid_tool_name"), and
      # identical in manual and Endpoint mode.
      assert error["code"] == ConduitMcp.Errors.invalid_params()
      assert error["message"] == "Unknown tool: unknown"
    end

    test "tool with enum validates allowed values" do
      conn = %Plug.Conn{}

      # Test with valid enum value
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_enum", %{"action" => "start"})
      assert result["content"] == [%{"type" => "text", "text" => "Action: start"}]

      # All enum values should work
      {:ok, result2} = DSLTestServer.handle_call_tool(conn, "with_enum", %{"action" => "stop"})
      assert result2["content"] == [%{"type" => "text", "text" => "Action: stop"}]

      {:ok, result3} = DSLTestServer.handle_call_tool(conn, "with_enum", %{"action" => "restart"})
      assert result3["content"] == [%{"type" => "text", "text" => "Action: restart"}]
    end

    test "tool handles default values when parameter not provided" do
      conn = %Plug.Conn{}

      # Call tool without providing the parameter that has a default
      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_default", %{})

      assert result["content"] == [%{"type" => "text", "text" => "Hello, World!"}]
    end

    test "tool handles explicit values overriding defaults" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_default", %{"name" => "Alice"})

      assert result["content"] == [%{"type" => "text", "text" => "Hello, Alice!"}]
    end

    test "tool with MFA handler receives correct parameters" do
      conn = %Plug.Conn{}

      # Test various values
      {:ok, result1} = DSLTestServer.handle_call_tool(conn, "with_mfa", %{"value" => 5})
      assert result1["content"] == [%{"type" => "text", "text" => "Result: 10"}]

      {:ok, result2} = DSLTestServer.handle_call_tool(conn, "with_mfa", %{"value" => 100})
      assert result2["content"] == [%{"type" => "text", "text" => "Result: 200"}]
    end

    test "tool with function capture works correctly" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_call_tool(conn, "with_capture", %{"value" => 7})
      assert result["content"] == [%{"type" => "text", "text" => "Result: 21"}]
    end

    test "tool with boolean handles both true and false" do
      conn = %Plug.Conn{}

      # Test with true
      {:ok, result1} =
        DSLTestServer.handle_call_tool(conn, "with_boolean", %{"enabled" => true, "count" => 10})

      assert result1["content"] == [%{"type" => "text", "text" => "Enabled: true, Count: 10"}]

      # Test with false
      {:ok, result2} =
        DSLTestServer.handle_call_tool(conn, "with_boolean", %{"enabled" => false, "count" => 0})

      assert result2["content"] == [%{"type" => "text", "text" => "Enabled: false, Count: 0"}]
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

      {:ok, result} =
        DSLTestServer.handle_get_prompt(conn, "code_review", %{
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

      {:ok, result} =
        DSLTestServer.handle_get_prompt(conn, "code_review", %{
          "code" => "def test, do: :ok"
        })

      messages = result["messages"]
      # Should use default language "elixir"
      assert Enum.at(messages, 1)["content"]["text"] =~ "elixir"
    end

    test "prompt returns properly formatted messages" do
      conn = %Plug.Conn{}

      {:ok, result} =
        DSLTestServer.handle_get_prompt(conn, "code_review", %{
          "code" => "function test() { return true; }",
          "language" => "javascript"
        })

      messages = result["messages"]

      # Verify message structure
      assert length(messages) == 2

      # System message
      system_msg = Enum.at(messages, 0)
      assert system_msg["role"] == "system"
      assert system_msg["content"]["type"] == "text"
      assert system_msg["content"]["text"] == "You are an expert code reviewer"

      # User message
      user_msg = Enum.at(messages, 1)
      assert user_msg["role"] == "user"
      assert user_msg["content"]["type"] == "text"
      assert user_msg["content"]["text"] =~ "javascript"
      assert user_msg["content"]["text"] =~ "function test()"
    end

    test "prompt handles missing optional arguments" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_get_prompt(conn, "simple_prompt", %{})

      messages = result["messages"]
      # Should use default topic "Elixir"
      assert hd(messages)["content"]["text"] =~ "Elixir"
    end

    test "prompt handles provided optional arguments" do
      conn = %Plug.Conn{}

      {:ok, result} =
        DSLTestServer.handle_get_prompt(conn, "simple_prompt", %{"topic" => "Phoenix"})

      messages = result["messages"]
      assert hd(messages)["content"]["text"] =~ "Phoenix"
    end

    test "returns error for unknown prompt" do
      conn = %Plug.Conn{}

      {:error, error} = DSLTestServer.handle_get_prompt(conn, "nonexistent", %{})

      assert error["code"] == ConduitMcp.Errors.invalid_params()
      assert error["message"] == "Unknown prompt: nonexistent"
    end
  end

  describe "DSL resource definitions" do
    test "generates resource schemas correctly (static only in resources/list)" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_resources(conn)

      resources = result["resources"]
      assert is_list(resources)

      # Templated URIs belong in resources/templates/list per MCP spec
      refute Enum.any?(resources, fn r -> r["uri"] == "user://{id}" end)

      static_resource = Enum.find(resources, fn r -> r["uri"] == "static://readme" end)
      assert static_resource["mimeType"] == "text/markdown"
    end

    test "templated resources appear in resources/templates/list" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_resource_templates(conn)

      templates = result["resourceTemplates"]
      assert is_list(templates)

      user_template = Enum.find(templates, fn r -> r["uriTemplate"] == "user://{id}" end)
      assert user_template["description"] == "User profile data"
      assert user_template["mimeType"] == "application/json"
      refute Map.has_key?(user_template, "uri")
    end

    test "executes resource read with URI template" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_read_resource(conn, "user://{id}")

      # Should return JSON content
      assert is_map(result)
      content = hd(result["content"])
      assert content["type"] == "text"

      # Verify it's valid JSON
      assert {:ok, data} = JSON.decode(content["text"])
      assert is_map(data)
    end

    test "executes static resource read" do
      conn = %Plug.Conn{}

      {:ok, result} = DSLTestServer.handle_read_resource(conn, "static://readme")

      assert result["content"] == [
               %{"type" => "text", "text" => "# README\n\nThis is a test README."}
             ]
    end

    test "extracts URI parameters from actual URIs" do
      conn = %Plug.Conn{}

      # Test with actual user ID
      {:ok, result} = DSLTestServer.handle_read_resource(conn, "user://123")

      content = hd(result["content"])
      assert content["type"] == "text"

      # Verify parameter was extracted and used
      {:ok, data} = JSON.decode(content["text"])
      assert data["id"] == "123"
      assert data["name"] == "User 123"
      assert data["email"] == "user123@example.com"
    end

    test "extracts parameters from different URIs" do
      conn = %Plug.Conn{}

      # Test with different ID
      {:ok, result} = DSLTestServer.handle_read_resource(conn, "user://456")

      content = hd(result["content"])
      {:ok, data} = JSON.decode(content["text"])
      assert data["id"] == "456"
      assert data["name"] == "User 456"
    end

    test "returns error for non-matching URI" do
      conn = %Plug.Conn{}

      # Test with URI that doesn't match any template
      {:error, error} = DSLTestServer.handle_read_resource(conn, "unknown://resource")

      assert error["code"] == ConduitMcp.Errors.resource_not_found()
      assert error["message"] =~ "Resource not found"
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
      assert {:ok, _data} = JSON.decode(content_text)
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
          %{
            name: :action,
            type: :string,
            description: "Action",
            opts: [enum: ["a", "b", "c"], required: true]
          }
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

    test "emits title when set" do
      schema =
        SchemaBuilder.build_tool_schema(%{
          name: "x",
          description: "",
          params: [],
          title: "Friendly Name"
        })

      assert schema["title"] == "Friendly Name"
    end

    test "omits title when nil or empty" do
      schema_nil =
        SchemaBuilder.build_tool_schema(%{name: "x", description: "", params: [], title: nil})

      schema_empty =
        SchemaBuilder.build_tool_schema(%{name: "x", description: "", params: [], title: ""})

      refute Map.has_key?(schema_nil, "title")
      refute Map.has_key?(schema_empty, "title")
    end

    test "emits icons when non-empty" do
      icons = [%{"src" => "https://example.com/x.svg", "mimeType" => "image/svg+xml"}]

      schema =
        SchemaBuilder.build_tool_schema(%{
          name: "x",
          description: "",
          params: [],
          icons: icons
        })

      assert schema["icons"] == icons
    end

    test "omits icons when nil or empty list" do
      schema_nil =
        SchemaBuilder.build_tool_schema(%{name: "x", description: "", params: [], icons: nil})

      schema_empty =
        SchemaBuilder.build_tool_schema(%{name: "x", description: "", params: [], icons: []})

      refute Map.has_key?(schema_nil, "icons")
      refute Map.has_key?(schema_empty, "icons")
    end

    test "emits outputSchema when set" do
      output = %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}

      schema =
        SchemaBuilder.build_tool_schema(%{
          name: "x",
          description: "",
          params: [],
          output_schema: output
        })

      assert schema["outputSchema"] == output
    end

    test "emits execution.taskSupport when set" do
      schema_supported =
        SchemaBuilder.build_tool_schema(%{
          name: "x",
          description: "",
          params: [],
          task_support: :supported
        })

      schema_required =
        SchemaBuilder.build_tool_schema(%{
          name: "x",
          description: "",
          params: [],
          task_support: :required
        })

      schema_none =
        SchemaBuilder.build_tool_schema(%{
          name: "x",
          description: "",
          params: [],
          task_support: :none
        })

      assert schema_supported["execution"] == %{"taskSupport" => "supported"}
      assert schema_required["execution"] == %{"taskSupport" => "required"}
      refute Map.has_key?(schema_none, "execution")
    end

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
      assert {:ok, %{"key" => "value", "count" => 42}} = JSON.decode(json_str)
    end

    test "raw/1 returns data directly without MCP wrapping" do
      import ConduitMcp.DSL.Helpers

      result = raw(%{status: "ok", count: 42})
      assert result == {:ok, %{status: "ok", count: 42}}
    end

    test "raw/1 works with simple values" do
      import ConduitMcp.DSL.Helpers

      result = raw("simple string")
      assert result == {:ok, "simple string"}
    end

    test "raw/1 works with lists" do
      import ConduitMcp.DSL.Helpers

      result = raw([1, 2, 3])
      assert result == {:ok, [1, 2, 3]}
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

    test "execution_error/1 returns a successful result with isError=true" do
      import ConduitMcp.DSL.Helpers

      assert {:ok,
              %{
                "content" => [%{"type" => "text", "text" => "User missing"}],
                "isError" => true
              }} = execution_error("User missing")
    end

    test "structured/2 emits content + structuredContent" do
      import ConduitMcp.DSL.Helpers

      payload = %{"id" => "42", "email" => "x@example.com"}

      assert {:ok,
              %{
                "content" => [%{"type" => "text", "text" => "Got user"}],
                "structuredContent" => ^payload
              }} = structured(payload, "Got user")
    end

    test "structured/1 falls back to JSON-encoded text when message omitted" do
      import ConduitMcp.DSL.Helpers

      payload = %{"id" => "42"}

      assert {:ok,
              %{
                "content" => [%{"type" => "text", "text" => text}],
                "structuredContent" => ^payload
              }} = structured(payload)

      assert {:ok, ^payload} = JSON.decode(text)
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

  describe "edge cases and parameter types" do
    test "tool with no parameters" do
      defmodule NoParamsServer do
        use ConduitMcp.Server

        tool "ping", "Simple ping" do
          handle(fn _conn, _params ->
            text("pong")
          end)
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

    test "all parameter types generate correct schemas" do
      defmodule TypesServer do
        use ConduitMcp.Server

        tool "all_types", "Tool with all param types" do
          param(:str, :string, "A string")
          param(:num, :number, "A number")
          param(:int, :integer, "An integer")
          param(:bool, :boolean, "A boolean")

          handle(fn _conn, _p -> text("ok") end)
        end
      end

      conn = %Plug.Conn{}
      {:ok, result} = TypesServer.handle_list_tools(conn)

      tool = hd(result["tools"])
      props = tool["inputSchema"]["properties"]

      assert props["str"]["type"] == "string"
      assert props["num"]["type"] == "number"
      assert props["int"]["type"] == "integer"
      assert props["bool"]["type"] == "boolean"
    end

    test "tool with multiple required parameters" do
      defmodule MultiRequiredServer do
        use ConduitMcp.Server

        tool "multi", "Multiple required params" do
          param(:first, :string, "First", required: true)
          param(:second, :number, "Second", required: true)
          param(:third, :string, "Third")

          handle(fn _conn, _p -> text("ok") end)
        end
      end

      conn = %Plug.Conn{}
      {:ok, result} = MultiRequiredServer.handle_list_tools(conn)

      tool = hd(result["tools"])
      required = tool["inputSchema"]["required"]

      assert length(required) == 2
      assert "first" in required
      assert "second" in required
      refute "third" in required
    end

    test "enum validation appears in schema" do
      conn = %Plug.Conn{}
      {:ok, result} = DSLTestServer.handle_list_tools(conn)

      enum_tool = Enum.find(result["tools"], fn t -> t["name"] == "with_enum" end)
      enum_values = enum_tool["inputSchema"]["properties"]["action"]["enum"]

      assert length(enum_values) == 3
      assert "start" in enum_values
      assert "stop" in enum_values
      assert "restart" in enum_values
    end
  end

  describe "URI parameter extraction" do
    test "extracts single parameter from URI" do
      template = "user://{id}"
      uri = "user://123"

      assert {:ok, %{"id" => "123"}} = ConduitMcp.DSL.extract_uri_params(template, uri)
    end

    test "extracts multiple parameters from URI" do
      template = "user://{user_id}/posts/{post_id}"
      uri = "user://123/posts/456"

      assert {:ok, params} = ConduitMcp.DSL.extract_uri_params(template, uri)
      assert params["user_id"] == "123"
      assert params["post_id"] == "456"
    end

    test "matches template against itself" do
      template = "user://{id}"

      # When called with template itself, should extract placeholder name
      assert {:ok, %{"id" => "{id}"}} = ConduitMcp.DSL.extract_uri_params(template, template)
    end

    test "returns no_match for non-matching URI" do
      template = "user://{id}"
      uri = "post://123"

      assert :no_match = ConduitMcp.DSL.extract_uri_params(template, uri)
    end

    test "handles URIs with special characters in template" do
      template = "file://path/{filename}.txt"
      uri = "file://path/document.txt"

      assert {:ok, %{"filename" => "document"}} = ConduitMcp.DSL.extract_uri_params(template, uri)
    end

    test "handles complex URI patterns" do
      template = "api://v1/users/{userId}/projects/{projectId}/tasks/{taskId}"
      uri = "api://v1/users/u123/projects/p456/tasks/t789"

      assert {:ok, params} = ConduitMcp.DSL.extract_uri_params(template, uri)
      assert params["userId"] == "u123"
      assert params["projectId"] == "p456"
      assert params["taskId"] == "t789"
    end

    test "returns no_match when path structure differs" do
      template = "user://{id}/posts/{post_id}"
      uri = "user://123/comments/456"

      assert :no_match = ConduitMcp.DSL.extract_uri_params(template, uri)
    end

    test "handles parameters with underscores and numbers" do
      template = "resource://{resource_id_123}"
      uri = "resource://abc-def-456"

      assert {:ok, %{"resource_id_123" => "abc-def-456"}} =
               ConduitMcp.DSL.extract_uri_params(template, uri)
    end
  end

  describe "tool annotations DSL" do
    defmodule AnnotatedToolServer do
      use ConduitMcp.Server

      tool "delete_item", "Deletes an item" do
        annotations(destructive: true, idempotent: false)

        param(:id, :string, "Item ID", required: true)

        handle(fn _conn, %{"id" => id} ->
          text("Deleted: #{id}")
        end)
      end

      tool "fetch_item", "Fetches an item" do
        annotations(read_only: true, open_world: false)

        param(:id, :string, "Item ID", required: true)

        handle(fn _conn, %{"id" => id} ->
          text("Fetched: #{id}")
        end)
      end

      tool "unannotated", "Tool without annotations" do
        param(:value, :string, "A value")

        handle(fn _conn, _params ->
          text("ok")
        end)
      end
    end

    test "tool with annotations includes annotations in schema" do
      conn = %Plug.Conn{}
      {:ok, result} = AnnotatedToolServer.handle_list_tools(conn)

      delete_tool = Enum.find(result["tools"], fn t -> t["name"] == "delete_item" end)
      assert Map.has_key?(delete_tool, "annotations")
      assert delete_tool["annotations"]["destructiveHint"] == true
      assert delete_tool["annotations"]["idempotentHint"] == false
    end

    test "annotation keys use correct MCP hint naming" do
      conn = %Plug.Conn{}
      {:ok, result} = AnnotatedToolServer.handle_list_tools(conn)

      fetch_tool = Enum.find(result["tools"], fn t -> t["name"] == "fetch_item" end)
      annotations = fetch_tool["annotations"]

      assert annotations["readOnlyHint"] == true
      assert annotations["openWorldHint"] == false
    end

    test "tool without annotations does not have annotations field" do
      conn = %Plug.Conn{}
      {:ok, result} = AnnotatedToolServer.handle_list_tools(conn)

      unannotated_tool = Enum.find(result["tools"], fn t -> t["name"] == "unannotated" end)
      refute Map.has_key?(unannotated_tool, "annotations")
    end

    test "annotated tools still execute correctly" do
      conn = %Plug.Conn{}

      {:ok, result} =
        AnnotatedToolServer.handle_call_tool(conn, "delete_item", %{"id" => "42"})

      assert result["content"] == [%{"type" => "text", "text" => "Deleted: 42"}]
    end
  end

  describe "audio helper macro" do
    test "audio/2 creates proper audio response format" do
      import ConduitMcp.DSL.Helpers

      result = audio("base64audiodata==", "audio/wav")

      assert result ==
               {:ok,
                %{
                  "content" => [
                    %{
                      "type" => "audio",
                      "data" => "base64audiodata==",
                      "mimeType" => "audio/wav"
                    }
                  ]
                }}
    end

    test "audio/2 works with different mime types" do
      import ConduitMcp.DSL.Helpers

      result = audio("mp3data", "audio/mpeg")

      assert {:ok, %{"content" => [content]}} = result
      assert content["type"] == "audio"
      assert content["data"] == "mp3data"
      assert content["mimeType"] == "audio/mpeg"
    end

    test "audio/2 works inside a DSL tool handler" do
      defmodule AudioToolServer do
        use ConduitMcp.Server

        tool "play_sound", "Returns audio content" do
          param(:data, :string, "Base64 audio data", required: true)

          handle(fn _conn, %{"data" => data} ->
            audio(data, "audio/wav")
          end)
        end
      end

      conn = %Plug.Conn{}
      {:ok, result} = AudioToolServer.handle_call_tool(conn, "play_sound", %{"data" => "AAAA"})

      assert result["content"] == [
               %{"type" => "audio", "data" => "AAAA", "mimeType" => "audio/wav"}
             ]
    end
  end
end

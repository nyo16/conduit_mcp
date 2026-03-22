defmodule ConduitMcp.ComponentTest do
  use ExUnit.Case, async: true

  # --- Tool Components ---

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, description: "Echoes text back"

    schema do
      field(:text, :string, "The text to echo", required: true, max_length: 150)
    end

    @impl true
    def execute(%{text: text}, _conn) do
      text(text)
    end
  end

  defmodule MathTool do
    use ConduitMcp.Component,
      type: :tool,
      name: "add_numbers",
      description: "Adds two numbers",
      annotations: [idempotent: true, readOnlyHint: true]

    schema do
      field(:a, :number, "First number", required: true)
      field(:b, :number, "Second number", required: true)
    end

    @impl true
    def execute(%{a: a, b: b}, _conn) do
      json(%{result: a + b})
    end
  end

  defmodule EnumTool do
    use ConduitMcp.Component, type: :tool, description: "Tool with enum and defaults"

    schema do
      field(:mode, :string, "Operating mode", required: true, enum: ["fast", "slow", "balanced"])
      field(:count, :integer, "Number of iterations", default: 10, min: 1, max: 100)
      field(:verbose, :boolean, "Enable verbose output", default: false)
    end

    @impl true
    def execute(%{mode: mode} = params, _conn) do
      count = Map.get(params, :count, 10)
      text("Running #{mode} mode #{count} times")
    end
  end

  defmodule ScopedTool do
    use ConduitMcp.Component,
      type: :tool,
      description: "A scoped tool",
      scope: "admin:write"

    schema do
      field(:action, :string, "Action to perform", required: true)
    end

    @impl true
    def execute(%{action: action}, _conn) do
      text("Performed: #{action}")
    end
  end

  defmodule NoSchemaTool do
    use ConduitMcp.Component, type: :tool, description: "Tool with no params"

    @impl true
    def execute(_params, _conn) do
      text("no params needed")
    end
  end

  defmodule ErrorTool do
    use ConduitMcp.Component, type: :tool, description: "Tool that returns errors"

    schema do
      field(:should_fail, :boolean, "Whether to fail", default: false)
    end

    @impl true
    def execute(%{should_fail: true}, _conn) do
      error("Something went wrong")
    end

    def execute(_params, _conn) do
      text("success")
    end
  end

  # --- Resource Components ---

  defmodule UserResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "user://{id}",
      description: "Reads a user by ID",
      mime_type: "application/json"

    @impl true
    def execute(%{id: id}, _conn) do
      {:ok,
       %{
         "contents" => [
           %{
             "uri" => "user://#{id}",
             "mimeType" => "application/json",
             "text" => Jason.encode!(%{id: id, name: "User #{id}"})
           }
         ]
       }}
    end
  end

  defmodule StaticResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "static://readme",
      description: "Static readme"

    @impl true
    def execute(_params, _conn) do
      {:ok,
       %{
         "contents" => [
           %{
             "uri" => "static://readme",
             "text" => "# README\nHello world"
           }
         ]
       }}
    end
  end

  # --- Prompt Components ---

  defmodule CodeReviewPrompt do
    use ConduitMcp.Component, type: :prompt, description: "Code review assistant"

    schema do
      field(:code, :string, "Code to review", required: true)
      field(:language, :string, "Programming language", default: "elixir")
    end

    @impl true
    def execute(%{code: code} = params, _conn) do
      language = Map.get(params, :language, "elixir")

      {:ok,
       %{
         "messages" => [
           system("You are a #{language} code reviewer"),
           user("Review this code:\n#{code}")
         ]
       }}
    end
  end

  # === Tests ===

  describe "Component type introspection" do
    test "tool component reports correct type" do
      assert EchoTool.__component_type__() == :tool
    end

    test "resource component reports correct type" do
      assert UserResource.__component_type__() == :resource
    end

    test "prompt component reports correct type" do
      assert CodeReviewPrompt.__component_type__() == :prompt
    end
  end

  describe "Name derivation" do
    test "auto-derives name from module" do
      assert EchoTool.__component_name__() == "echo_tool"
    end

    test "respects explicit name" do
      assert MathTool.__component_name__() == "add_numbers"
    end

    test "resource derives name from module" do
      assert UserResource.__component_name__() == "user_resource"
    end

    test "prompt derives name from module" do
      assert CodeReviewPrompt.__component_name__() == "code_review_prompt"
    end
  end

  describe "Description" do
    test "tool has description" do
      assert EchoTool.__component_description__() == "Echoes text back"
    end

    test "resource has description" do
      assert UserResource.__component_description__() == "Reads a user by ID"
    end

    test "prompt has description" do
      assert CodeReviewPrompt.__component_description__() == "Code review assistant"
    end
  end

  describe "JSON Schema generation for tools" do
    test "generates correct tool schema with required params" do
      schema = EchoTool.__component_schema__()

      assert schema["name"] == "echo_tool"
      assert schema["description"] == "Echoes text back"
      assert schema["inputSchema"]["type"] == "object"
      assert schema["inputSchema"]["properties"]["text"]["type"] == "string"
      assert "text" in schema["inputSchema"]["required"]
    end

    test "generates schema with multiple params" do
      schema = MathTool.__component_schema__()

      assert schema["name"] == "add_numbers"
      assert schema["inputSchema"]["properties"]["a"]["type"] == "number"
      assert schema["inputSchema"]["properties"]["b"]["type"] == "number"
      assert "a" in schema["inputSchema"]["required"]
      assert "b" in schema["inputSchema"]["required"]
    end

    test "includes annotations in schema" do
      schema = MathTool.__component_schema__()

      assert schema["annotations"]["idempotent"] == true
      assert schema["annotations"]["readOnlyHint"] == true
    end

    test "schema without annotations has no annotations key" do
      schema = EchoTool.__component_schema__()
      refute Map.has_key?(schema, "annotations")
    end

    test "tool with enum generates correct schema" do
      schema = EnumTool.__component_schema__()
      mode_prop = schema["inputSchema"]["properties"]["mode"]

      assert mode_prop["type"] == "string"
    end

    test "tool with no schema has empty properties" do
      schema = NoSchemaTool.__component_schema__()

      assert schema["inputSchema"]["type"] == "object"
      assert schema["inputSchema"]["properties"] == %{}
    end
  end

  describe "JSON Schema generation for resources" do
    test "generates correct resource schema" do
      schema = UserResource.__component_schema__()

      assert schema["uri"] == "user://{id}"
      assert schema["description"] == "Reads a user by ID"
      assert schema["mimeType"] == "application/json"
    end

    test "static resource schema" do
      schema = StaticResource.__component_schema__()

      assert schema["uri"] == "static://readme"
      assert schema["description"] == "Static readme"
      refute Map.has_key?(schema, "mimeType")
    end
  end

  describe "JSON Schema generation for prompts" do
    test "generates correct prompt schema" do
      schema = CodeReviewPrompt.__component_schema__()

      assert schema["name"] == "code_review_prompt"
      assert schema["description"] == "Code review assistant"
      assert is_list(schema["arguments"])
    end
  end

  describe "Validation schema generation" do
    test "generates NimbleOptions schema for tool" do
      schema = EchoTool.__validation_schema__()

      assert is_list(schema)
      assert Keyword.has_key?(schema, :text)
      text_opts = Keyword.get(schema, :text)
      assert text_opts[:type] == :string
      assert text_opts[:required] == true
    end

    test "generates schema with multiple params" do
      schema = MathTool.__validation_schema__()

      assert Keyword.has_key?(schema, :a)
      assert Keyword.has_key?(schema, :b)
      assert Keyword.get(schema, :a)[:type] == :float
      assert Keyword.get(schema, :a)[:required] == true
    end

    test "generates schema with constraints" do
      schema = EnumTool.__validation_schema__()

      mode_opts = Keyword.get(schema, :mode)
      assert mode_opts[:required] == true
      assert mode_opts[:__enum_values__] == ["fast", "slow", "balanced"]

      count_opts = Keyword.get(schema, :count)
      assert count_opts[:default] == 10
      assert count_opts[:__min_value__] == 1
      assert count_opts[:__max_value__] == 100
    end

    test "empty schema returns empty list" do
      schema = NoSchemaTool.__validation_schema__()
      assert schema == []
    end

    test "prompt validation schema" do
      schema = CodeReviewPrompt.__validation_schema__()

      assert Keyword.has_key?(schema, :code)
      code_opts = Keyword.get(schema, :code)
      assert code_opts[:type] == :string
      assert code_opts[:required] == true
    end
  end

  describe "Component options" do
    test "tool component opts include scope" do
      opts = ScopedTool.__component_opts__()
      assert Keyword.get(opts, :scope) == "admin:write"
    end

    test "resource component opts include uri and mime_type" do
      opts = UserResource.__component_opts__()
      assert Keyword.get(opts, :uri) == "user://{id}"
      assert Keyword.get(opts, :mime_type) == "application/json"
    end
  end

  describe "execute/2" do
    setup do
      conn = %Plug.Conn{}
      {:ok, conn: conn}
    end

    test "tool returns text response", %{conn: conn} do
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "hello"}]}} =
               EchoTool.execute(%{text: "hello"}, conn)
    end

    test "tool returns json response", %{conn: conn} do
      assert {:ok, %{"content" => [%{"type" => "text", "text" => json}]}} =
               MathTool.execute(%{a: 1.0, b: 2.0}, conn)

      assert %{"result" => 3.0} = Jason.decode!(json)
    end

    test "tool returns error response", %{conn: conn} do
      assert {:error, %{"code" => -32000, "message" => "Something went wrong"}} =
               ErrorTool.execute(%{should_fail: true}, conn)
    end

    test "tool returns success on non-failure", %{conn: conn} do
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "success"}]}} =
               ErrorTool.execute(%{should_fail: false}, conn)
    end

    test "resource returns contents", %{conn: conn} do
      assert {:ok, %{"contents" => [%{"uri" => "user://42", "text" => json}]}} =
               UserResource.execute(%{id: "42"}, conn)

      assert %{"id" => "42", "name" => "User 42"} = Jason.decode!(json)
    end

    test "prompt returns messages", %{conn: conn} do
      assert {:ok, %{"messages" => [system_msg, user_msg]}} =
               CodeReviewPrompt.execute(%{code: "def foo, do: :ok", language: "elixir"}, conn)

      assert system_msg["role"] == "system"
      assert system_msg["content"]["text"] =~ "elixir code reviewer"
      assert user_msg["role"] == "user"
      assert user_msg["content"]["text"] =~ "def foo, do: :ok"
    end

    test "tool with no params executes successfully", %{conn: conn} do
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "no params needed"}]}} =
               NoSchemaTool.execute(%{}, conn)
    end
  end

  describe "compile-time validation" do
    test "raises for invalid component type" do
      assert_raise CompileError, ~r/invalid component type/, fn ->
        defmodule BadType do
          use ConduitMcp.Component, type: :invalid, description: "bad"

          @impl true
          def execute(_params, _conn), do: text("nope")
        end
      end
    end

    test "raises for tool without description" do
      assert_raise CompileError, ~r/require a :description/, fn ->
        defmodule NoDescTool do
          use ConduitMcp.Component, type: :tool

          @impl true
          def execute(_params, _conn), do: text("nope")
        end
      end
    end

    test "raises for prompt without description" do
      assert_raise CompileError, ~r/require a :description/, fn ->
        defmodule NoDescPrompt do
          use ConduitMcp.Component, type: :prompt

          @impl true
          def execute(_params, _conn), do: {:ok, %{"messages" => []}}
        end
      end
    end

    test "raises for resource without uri" do
      assert_raise CompileError, ~r/require a :uri/, fn ->
        defmodule NoUriResource do
          use ConduitMcp.Component, type: :resource, description: "bad"

          @impl true
          def execute(_params, _conn), do: {:ok, %{"contents" => []}}
        end
      end
    end
  end

  describe "behaviour enforcement" do
    test "component module implements ConduitMcp.Component behaviour" do
      behaviours =
        EchoTool.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ConduitMcp.Component in behaviours
    end
  end
end

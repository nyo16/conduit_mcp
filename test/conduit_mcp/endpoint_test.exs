defmodule ConduitMcp.EndpointTest do
  use ExUnit.Case, async: true

  # --- Components ---

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, description: "Echoes text"

    schema do
      field(:text, :string, "The text", required: true)
    end

    @impl true
    def execute(%{text: text}, _conn), do: text(text)
  end

  defmodule ReverseTool do
    use ConduitMcp.Component, type: :tool, description: "Reverses text"

    schema do
      field(:text, :string, "The text", required: true)
    end

    @impl true
    def execute(%{text: text}, _conn), do: text(String.reverse(text))
  end

  defmodule ScopedDeleteTool do
    use ConduitMcp.Component,
      type: :tool,
      description: "Deletes something",
      scope: "admin:delete"

    schema do
      field(:id, :string, "ID to delete", required: true)
    end

    @impl true
    def execute(%{id: id}, _conn), do: text("deleted #{id}")
  end

  defmodule UserResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "user://{id}",
      description: "User resource",
      mime_type: "application/json"

    @impl true
    def execute(%{id: id}, _conn) do
      {:ok,
       %{
         "contents" => [
           %{
             "uri" => "user://#{id}",
             "mimeType" => "application/json",
             "text" => ~s({"id":"#{id}"})
           }
         ]
       }}
    end
  end

  defmodule ReadmeResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "static://readme",
      description: "Readme"

    @impl true
    def execute(_params, _conn) do
      {:ok, %{"contents" => [%{"uri" => "static://readme", "text" => "# README"}]}}
    end
  end

  defmodule CodeReviewPrompt do
    use ConduitMcp.Component, type: :prompt, description: "Code review"

    schema do
      field(:code, :string, "Code to review", required: true)
      field(:language, :string, "Language", default: "elixir")
    end

    @impl true
    def execute(%{code: code} = params, _conn) do
      lang = Map.get(params, :language, "elixir")

      {:ok,
       %{
         "messages" => [
           %{
             "role" => "system",
             "content" => %{"type" => "text", "text" => "Review #{lang} code"}
           },
           %{"role" => "user", "content" => %{"type" => "text", "text" => code}}
         ]
       }}
    end
  end

  # --- Endpoints ---

  defmodule ToolsOnlyEndpoint do
    use ConduitMcp.Endpoint,
      name: "Tools Server",
      version: "1.0.0"

    component(EchoTool)
    component(ReverseTool)
    component(ScopedDeleteTool)
  end

  defmodule FullEndpoint do
    use ConduitMcp.Endpoint,
      name: "Full Server",
      version: "2.0.0",
      rate_limit: [backend: :test_backend, limit: 100, scale: 60_000],
      message_rate_limit: [backend: :test_backend, limit: 50, scale: 300_000]

    component(EchoTool)
    component(ReverseTool)
    component(UserResource)
    component(ReadmeResource)
    component(CodeReviewPrompt)
  end

  defmodule EmptyEndpoint do
    use ConduitMcp.Endpoint,
      name: "Empty Server",
      version: "0.1.0"
  end

  # === Tests ===

  describe "handle_list_tools/1" do
    test "returns all registered tools" do
      assert {:ok, %{"tools" => tools}} = ToolsOnlyEndpoint.handle_list_tools(%Plug.Conn{})
      assert length(tools) == 3

      names = Enum.map(tools, & &1["name"])
      assert "echo_tool" in names
      assert "reverse_tool" in names
      assert "scoped_delete_tool" in names
    end

    test "tool schemas have correct structure" do
      {:ok, %{"tools" => tools}} = FullEndpoint.handle_list_tools(%Plug.Conn{})
      echo = Enum.find(tools, &(&1["name"] == "echo_tool"))

      assert echo["description"] == "Echoes text"
      assert echo["inputSchema"]["type"] == "object"
      assert echo["inputSchema"]["properties"]["text"]["type"] == "string"
      assert "text" in echo["inputSchema"]["required"]
    end

    test "empty endpoint returns empty tools list" do
      assert {:ok, %{"tools" => []}} = EmptyEndpoint.handle_list_tools(%Plug.Conn{})
    end
  end

  describe "handle_call_tool/3" do
    setup do
      {:ok, conn: %Plug.Conn{}}
    end

    test "dispatches to correct component", %{conn: conn} do
      assert {:ok, %{"content" => [%{"text" => "hello"}]}} =
               FullEndpoint.handle_call_tool(conn, "echo_tool", %{"text" => "hello"})
    end

    test "dispatches to reverse tool", %{conn: conn} do
      assert {:ok, %{"content" => [%{"text" => "olleh"}]}} =
               FullEndpoint.handle_call_tool(conn, "reverse_tool", %{"text" => "hello"})
    end

    test "converts string keys to atom keys", %{conn: conn} do
      # Component receives atom-keyed params
      assert {:ok, %{"content" => [%{"text" => "world"}]}} =
               FullEndpoint.handle_call_tool(conn, "echo_tool", %{"text" => "world"})
    end

    test "returns error for unknown tool", %{conn: conn} do
      assert {:error, %{"code" => -32601, "message" => msg}} =
               FullEndpoint.handle_call_tool(conn, "nonexistent", %{})

      assert msg =~ "Tool not found"
    end

    test "empty endpoint returns error for any tool", %{conn: conn} do
      assert {:error, %{"code" => -32601}} =
               EmptyEndpoint.handle_call_tool(conn, "anything", %{})
    end
  end

  describe "handle_list_resources/1" do
    test "returns only static (non-templated) resources" do
      assert {:ok, %{"resources" => resources}} =
               FullEndpoint.handle_list_resources(%Plug.Conn{})

      uris = Enum.map(resources, & &1["uri"])
      assert "static://readme" in uris
      refute "user://{id}" in uris
    end

    test "static resource schemas have correct structure" do
      {:ok, %{"resources" => resources}} = FullEndpoint.handle_list_resources(%Plug.Conn{})
      static = Enum.find(resources, &(&1["uri"] == "static://readme"))

      assert is_map(static)
    end

    test "endpoint without resources returns empty list" do
      assert {:ok, %{"resources" => []}} = ToolsOnlyEndpoint.handle_list_resources(%Plug.Conn{})
    end
  end

  describe "handle_list_resource_templates/1" do
    test "returns only templated resources, with uriTemplate key" do
      assert {:ok, %{"resourceTemplates" => templates}} =
               FullEndpoint.handle_list_resource_templates(%Plug.Conn{})

      uri_templates = Enum.map(templates, & &1["uriTemplate"])
      assert "user://{id}" in uri_templates
      refute "static://readme" in uri_templates

      user_template = Enum.find(templates, &(&1["uriTemplate"] == "user://{id}"))
      assert user_template["description"] == "User resource"
      assert user_template["mimeType"] == "application/json"
      refute Map.has_key?(user_template, "uri")
    end

    test "endpoint without templated resources returns empty list" do
      assert {:ok, %{"resourceTemplates" => []}} =
               ToolsOnlyEndpoint.handle_list_resource_templates(%Plug.Conn{})
    end
  end

  describe "handle_read_resource/2" do
    setup do
      {:ok, conn: %Plug.Conn{}}
    end

    test "dispatches to correct resource by URI match", %{conn: conn} do
      assert {:ok, %{"contents" => [%{"uri" => "user://42"}]}} =
               FullEndpoint.handle_read_resource(conn, "user://42")
    end

    test "dispatches to static resource", %{conn: conn} do
      assert {:ok, %{"contents" => [%{"uri" => "static://readme", "text" => "# README"}]}} =
               FullEndpoint.handle_read_resource(conn, "static://readme")
    end

    test "returns error for unknown resource URI", %{conn: conn} do
      assert {:error, %{"code" => -32002, "message" => msg}} =
               FullEndpoint.handle_read_resource(conn, "unknown://thing")

      assert msg =~ "Resource not found"
    end
  end

  describe "handle_list_prompts/1" do
    test "returns all registered prompts" do
      assert {:ok, %{"prompts" => prompts}} = FullEndpoint.handle_list_prompts(%Plug.Conn{})
      assert length(prompts) == 1
      assert hd(prompts)["name"] == "code_review_prompt"
    end

    test "endpoint without prompts returns empty list" do
      assert {:ok, %{"prompts" => []}} = ToolsOnlyEndpoint.handle_list_prompts(%Plug.Conn{})
    end
  end

  describe "handle_get_prompt/3" do
    setup do
      {:ok, conn: %Plug.Conn{}}
    end

    test "dispatches to correct prompt", %{conn: conn} do
      assert {:ok, %{"messages" => [system, user]}} =
               FullEndpoint.handle_get_prompt(conn, "code_review_prompt", %{
                 "code" => "def foo, do: :ok"
               })

      assert system["role"] == "system"
      assert user["content"]["text"] == "def foo, do: :ok"
    end

    test "returns error for unknown prompt", %{conn: conn} do
      assert {:error, %{"code" => -32601, "message" => msg}} =
               FullEndpoint.handle_get_prompt(conn, "nonexistent", %{})

      assert msg =~ "Prompt not found"
    end
  end

  describe "validation schema lookups" do
    test "returns validation schema tuple for tool" do
      {full_schema, clean_schema} = FullEndpoint.__validation_schema_for_tool__("echo_tool")
      assert is_list(full_schema)
      assert Keyword.has_key?(full_schema, :text)
      assert is_list(clean_schema)
      assert Keyword.has_key?(clean_schema, :text)
    end

    test "returns nil for unknown tool" do
      assert is_nil(FullEndpoint.__validation_schema_for_tool__("nonexistent"))
    end

    test "returns validation schema tuple for prompt" do
      {full_schema, clean_schema} =
        FullEndpoint.__validation_schema_for_prompt__("code_review_prompt")

      assert is_list(full_schema)
      assert Keyword.has_key?(full_schema, :code)
      assert is_list(clean_schema)
      assert Keyword.has_key?(clean_schema, :code)
    end

    test "returns nil for unknown prompt" do
      assert is_nil(FullEndpoint.__validation_schema_for_prompt__("nonexistent"))
    end
  end

  describe "scope lookup" do
    test "returns scope for scoped tool" do
      assert ToolsOnlyEndpoint.__scope_for_tool__("scoped_delete_tool") == "admin:delete"
    end

    test "returns nil for unscoped tool" do
      assert is_nil(ToolsOnlyEndpoint.__scope_for_tool__("echo_tool"))
    end

    test "returns nil for unknown tool" do
      assert is_nil(ToolsOnlyEndpoint.__scope_for_tool__("nonexistent"))
    end
  end

  describe "__endpoint_config__/0" do
    test "returns endpoint options" do
      config = FullEndpoint.__endpoint_config__()

      assert Keyword.get(config, :name) == "Full Server"
      assert Keyword.get(config, :version) == "2.0.0"

      assert Keyword.get(config, :rate_limit) == [
               backend: :test_backend,
               limit: 100,
               scale: 60_000
             ]

      assert Keyword.get(config, :message_rate_limit) == [
               backend: :test_backend,
               limit: 50,
               scale: 300_000
             ]
    end

    test "config without rate limiting" do
      config = ToolsOnlyEndpoint.__endpoint_config__()

      assert Keyword.get(config, :name) == "Tools Server"
      assert is_nil(Keyword.get(config, :rate_limit))
    end
  end

  describe "__capabilities__/0" do
    test "tools-only endpoint advertises only tools" do
      caps = ToolsOnlyEndpoint.__capabilities__()

      assert Map.has_key?(caps, "tools")
      refute Map.has_key?(caps, "resources")
      refute Map.has_key?(caps, "prompts")
    end

    test "full endpoint advertises all capabilities" do
      caps = FullEndpoint.__capabilities__()

      assert Map.has_key?(caps, "tools")
      assert Map.has_key?(caps, "resources")
      assert Map.has_key?(caps, "prompts")
    end

    test "empty endpoint advertises no capabilities" do
      caps = EmptyEndpoint.__capabilities__()

      assert caps == %{}
    end
  end

  describe "Server behaviour implementation" do
    test "endpoint implements ConduitMcp.Server behaviour" do
      behaviours =
        FullEndpoint.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ConduitMcp.Server in behaviours
    end
  end

  describe "Handler integration" do
    test "Handler dispatches tools/list to endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})

      assert result["result"]["tools"]
      names = Enum.map(result["result"]["tools"], & &1["name"])
      assert "echo_tool" in names
      assert "reverse_tool" in names
    end

    test "Handler dispatches tools/call to endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo_tool",
          "arguments" => %{"text" => "handler test"}
        }
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})

      assert result["result"]["content"]
      assert hd(result["result"]["content"])["text"] == "handler test"
    end

    test "Handler dispatches resources/list to endpoint (static only)" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "resources/list"
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})
      uris = Enum.map(result["result"]["resources"], & &1["uri"])
      assert "static://readme" in uris
      refute "user://{id}" in uris
    end

    test "Handler dispatches resources/templates/list to endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "resources/templates/list"
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})

      uri_templates =
        Enum.map(result["result"]["resourceTemplates"], & &1["uriTemplate"])

      assert "user://{id}" in uri_templates
    end

    test "Handler dispatches resources/read to endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "resources/read",
        "params" => %{"uri" => "user://99"}
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})
      assert hd(result["result"]["contents"])["uri"] == "user://99"
    end

    test "Handler dispatches prompts/list to endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "prompts/list"
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})
      assert length(result["result"]["prompts"]) == 1
    end

    test "Handler dispatches prompts/get to endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "prompts/get",
        "params" => %{
          "name" => "code_review_prompt",
          "arguments" => %{"code" => "def bar, do: :baz"}
        }
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})
      assert length(result["result"]["messages"]) == 2
    end

    test "Handler uses __capabilities__ from endpoint for initialize" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test", "version" => "1.0"},
          "capabilities" => %{}
        }
      }

      result = ConduitMcp.Handler.handle_request(request, ToolsOnlyEndpoint, %Plug.Conn{})
      caps = result["result"]["capabilities"]

      assert Map.has_key?(caps, "tools")
      refute Map.has_key?(caps, "resources")
      refute Map.has_key?(caps, "prompts")
    end

    test "Handler returns error for unknown tool from endpoint" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 8,
        "method" => "tools/call",
        "params" => %{
          "name" => "nonexistent",
          "arguments" => %{}
        }
      }

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})
      # The error code depends on whether validation intercepts first (-32602)
      # or the tool catch-all fires (-32601). Either is correct.
      assert result["error"]["code"] in [-32601, -32602]
      assert result["error"]
    end

    test "Handler validates tool params via endpoint validation schema" do
      # The FullEndpoint generates __validation_schema_for_tool__ which the
      # Handler's validation pipeline uses
      request = %{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo_tool",
          "arguments" => %{}
        }
      }

      # With validation enabled, missing required 'text' should produce an error
      ConduitMcp.Validation.update_validation_config(
        runtime_validation: true,
        strict_mode: true,
        type_coercion: true
      )

      result = ConduitMcp.Handler.handle_request(request, FullEndpoint, %Plug.Conn{})

      # Should be a validation error (-32602)
      assert result["error"]["code"] == -32602
    after
      ConduitMcp.Validation.update_validation_config([])
    end
  end

  describe "compile-time validation" do
    test "raises for duplicate tool names" do
      assert_raise CompileError, ~r/duplicate tool name/, fn ->
        defmodule DuplicateEndpoint do
          use ConduitMcp.Endpoint, name: "bad", version: "1"

          component(EchoTool)
          component(EchoTool)
        end
      end
    end

    test "raises for invalid component module" do
      assert_raise CompileError, ~r/not a valid ConduitMcp.Component/, fn ->
        defmodule BadComponentEndpoint do
          use ConduitMcp.Endpoint, name: "bad", version: "1"

          component(String)
        end
      end
    end
  end
end

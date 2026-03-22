defmodule ConduitMcp.McpAppsTest do
  use ExUnit.Case, async: true

  # ============ Test Servers ============

  defmodule MetaToolServer do
    use ConduitMcp.Server

    tool "dashboard", "Health dashboard" do
      meta(%{ui: %{resourceUri: "ui://dashboard/app.html"}, custom: "value"})

      handle(fn _conn, _params ->
        json(%{cpu: 42})
      end)
    end

    tool "plain", "Plain tool" do
      param(:name, :string, "Name", required: true)

      handle(fn _conn, params ->
        text("Hello #{params["name"]}")
      end)
    end
  end

  defmodule UiToolServer do
    use ConduitMcp.Server

    tool "health", "Health check with UI" do
      ui("ui://health/dashboard.html")
      param(:format, :string, "Output format", default: "json")

      handle(fn _conn, _params ->
        json(%{status: "ok"})
      end)
    end
  end

  defmodule UiResourceServer do
    use ConduitMcp.Server

    tool "viewer", "Data viewer" do
      ui("ui://viewer/app.html")

      handle(fn _conn, _params ->
        json(%{data: [1, 2, 3]})
      end)
    end

    resource "ui://viewer/app.html" do
      description("Data viewer UI")
      mime_type("text/html;profile=mcp-app")

      read(fn _conn, _params, _opts ->
        app_html("<html><body>Viewer</body></html>")
      end)
    end
  end

  defmodule AppMacroServer do
    use ConduitMcp.Server

    app "metrics", "Server metrics dashboard" do
      param(:range, :string, "Time range", default: "1h")
      view("test/fixtures/test_app.html")

      handle(fn _conn, _params ->
        json(%{cpu: 55, memory: 2048})
      end)
    end

    tool "get_metrics", "Get raw metrics" do
      handle(fn _conn, _params ->
        json(%{cpu: 55})
      end)
    end
  end

  # Component with ui: option
  defmodule DashboardComponent do
    use ConduitMcp.Component,
      type: :tool,
      description: "Dashboard with UI",
      ui: "ui://dashboard-component/app.html"

    schema do
      field(:format, :string, "Output format")
    end

    @impl true
    def execute(_params, _conn) do
      json(%{status: "ok"})
    end
  end

  # Component without ui: option
  defmodule PlainComponent do
    use ConduitMcp.Component,
      type: :tool,
      description: "Plain tool component"

    schema do
      field(:name, :string, "Name", required: true)
    end

    @impl true
    def execute(%{name: name}, _conn) do
      text("Hello #{name}")
    end
  end

  defmodule UiResourceComponent do
    use ConduitMcp.Component,
      type: :resource,
      uri: "ui://dashboard-component/app.html",
      description: "Dashboard UI",
      mime_type: "text/html"

    @impl true
    def execute(_params, _conn) do
      raw_resource("<html><body>Component Dashboard</body></html>", "text/html")
    end
  end

  defmodule ComponentEndpoint do
    use ConduitMcp.Endpoint,
      name: "Test Endpoint",
      version: "1.0.0"

    component(DashboardComponent)
    component(PlainComponent)
    component(UiResourceComponent)
  end

  # ============ Setup ============

  setup_all do
    # Create test fixture for app macro
    File.mkdir_p!("test/fixtures")
    File.write!("test/fixtures/test_app.html", "<html><body>Test App</body></html>")
    on_exit(fn -> File.rm("test/fixtures/test_app.html") end)
    :ok
  end

  # ============ Tests: meta/1 macro ============

  describe "meta/1 macro" do
    test "includes _meta in tool definition with generic metadata" do
      {:ok, result} = MetaToolServer.handle_list_tools(%Plug.Conn{})
      tools = result["tools"]

      dashboard = Enum.find(tools, &(&1["name"] == "dashboard"))

      assert dashboard["_meta"] == %{
               "ui" => %{"resourceUri" => "ui://dashboard/app.html"},
               "custom" => "value"
             }
    end

    test "tools without meta do not include _meta key" do
      {:ok, result} = MetaToolServer.handle_list_tools(%Plug.Conn{})
      tools = result["tools"]

      plain = Enum.find(tools, &(&1["name"] == "plain"))
      refute Map.has_key?(plain, "_meta")
    end
  end

  # ============ Tests: ui/1 macro ============

  describe "ui/1 macro" do
    test "sets _meta.ui.resourceUri on tool" do
      {:ok, result} = UiToolServer.handle_list_tools(%Plug.Conn{})
      tool = hd(result["tools"])

      assert tool["_meta"] == %{
               "ui" => %{"resourceUri" => "ui://health/dashboard.html"},
               "ui/resourceUri" => "ui://health/dashboard.html"
             }
    end

    test "tool retains other fields alongside _meta" do
      {:ok, result} = UiToolServer.handle_list_tools(%Plug.Conn{})
      tool = hd(result["tools"])

      assert tool["name"] == "health"
      assert tool["description"] == "Health check with UI"
      assert tool["inputSchema"]["properties"]["format"]
    end
  end

  # ============ Tests: raw_resource/2 helper ============

  describe "raw_resource/2 helper" do
    test "returns proper resource content format" do
      {:ok, result} =
        UiResourceServer.handle_read_resource(
          %Plug.Conn{},
          "ui://viewer/app.html"
        )

      assert [content] = result["contents"]
      assert content["mimeType"] == "text/html;profile=mcp-app"
      assert content["text"] == "<html><body>Viewer</body></html>"
    end
  end

  # ============ Tests: ui:// resource ============

  describe "ui:// resource" do
    test "listed in resources with correct schema" do
      {:ok, result} = UiResourceServer.handle_list_resources(%Plug.Conn{})
      resource = Enum.find(result["resources"], &(&1["uri"] == "ui://viewer/app.html"))

      assert resource["description"] == "Data viewer UI"
      assert resource["mimeType"] == "text/html;profile=mcp-app"
    end

    test "tool and resource coexist" do
      {:ok, tools_result} = UiResourceServer.handle_list_tools(%Plug.Conn{})
      {:ok, resources_result} = UiResourceServer.handle_list_resources(%Plug.Conn{})

      tool = hd(tools_result["tools"])
      resource = hd(resources_result["resources"])

      # Tool points to the resource
      assert tool["_meta"]["ui"]["resourceUri"] == resource["uri"]
    end
  end

  # ============ Tests: app/2 macro ============

  describe "app/2 macro" do
    test "registers tool with _meta.ui.resourceUri" do
      {:ok, result} = AppMacroServer.handle_list_tools(%Plug.Conn{})
      metrics_tool = Enum.find(result["tools"], &(&1["name"] == "metrics"))

      assert metrics_tool["_meta"]["ui"]["resourceUri"] == "ui://metrics/test_app.html"
      assert metrics_tool["description"] == "Server metrics dashboard"
      assert metrics_tool["inputSchema"]["properties"]["range"]
    end

    test "registers ui:// resource for the HTML file" do
      {:ok, result} = AppMacroServer.handle_list_resources(%Plug.Conn{})
      resource = Enum.find(result["resources"], &(&1["uri"] == "ui://metrics/test_app.html"))

      assert resource["mimeType"] == "text/html;profile=mcp-app"
      assert resource["description"] == "UI for metrics"
    end

    test "resource serves HTML content" do
      {:ok, result} =
        AppMacroServer.handle_read_resource(
          %Plug.Conn{},
          "ui://metrics/test_app.html"
        )

      assert [content] = result["contents"]
      assert content["mimeType"] == "text/html;profile=mcp-app"
      assert content["text"] == "<html><body>Test App</body></html>"
    end

    test "tool handler works normally" do
      {:ok, result} = AppMacroServer.handle_call_tool(%Plug.Conn{}, "metrics", %{})
      assert [%{"type" => "text", "text" => json_text}] = result["content"]
      assert %{"cpu" => 55, "memory" => 2048} = JSON.decode!(json_text)
    end

    test "other tools in same server work" do
      {:ok, result} = AppMacroServer.handle_call_tool(%Plug.Conn{}, "get_metrics", %{})
      assert [%{"type" => "text", "text" => json_text}] = result["content"]
      assert %{"cpu" => 55} = JSON.decode!(json_text)
    end
  end

  # ============ Tests: Component mode ui: option ============

  describe "Component ui: option" do
    test "component schema includes _meta" do
      schema = DashboardComponent.__component_schema__()

      assert schema["_meta"] == %{
               "ui" => %{"resourceUri" => "ui://dashboard-component/app.html"},
               "ui/resourceUri" => "ui://dashboard-component/app.html"
             }
    end

    test "component without ui: has no _meta" do
      schema = PlainComponent.__component_schema__()
      refute Map.has_key?(schema, "_meta")
    end
  end

  # ============ Tests: Endpoint with ui: components ============

  describe "Endpoint with ui: components" do
    test "handle_list_tools includes _meta from component" do
      {:ok, result} = ComponentEndpoint.handle_list_tools(%Plug.Conn{})
      tools = result["tools"]

      dashboard = Enum.find(tools, &(&1["name"] == "dashboard_component"))

      assert dashboard["_meta"] == %{
               "ui" => %{"resourceUri" => "ui://dashboard-component/app.html"},
               "ui/resourceUri" => "ui://dashboard-component/app.html"
             }
    end

    test "plain component has no _meta in endpoint listing" do
      {:ok, result} = ComponentEndpoint.handle_list_tools(%Plug.Conn{})
      tools = result["tools"]

      plain = Enum.find(tools, &(&1["name"] == "plain_component"))
      refute Map.has_key?(plain, "_meta")
    end

    test "ui:// resource is served through endpoint" do
      {:ok, result} =
        ComponentEndpoint.handle_read_resource(
          %Plug.Conn{},
          "ui://dashboard-component/app.html"
        )

      assert [content] = result["contents"]
      assert content["mimeType"] == "text/html"
      assert content["text"] == "<html><body>Component Dashboard</body></html>"
    end
  end

  # ============ Tests: Handler full flow ============

  describe "Handler full flow" do
    test "tools/list via Handler includes _meta" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      }

      response = ConduitMcp.Handler.handle_request(request, UiToolServer, %Plug.Conn{})
      tools = response["result"]["tools"]
      tool = hd(tools)

      assert tool["_meta"]["ui"]["resourceUri"] == "ui://health/dashboard.html"
    end

    test "resources/read via Handler returns HTML" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "resources/read",
        "params" => %{"uri" => "ui://viewer/app.html"}
      }

      response = ConduitMcp.Handler.handle_request(request, UiResourceServer, %Plug.Conn{})
      contents = response["result"]["contents"]

      assert [%{"mimeType" => "text/html;profile=mcp-app", "text" => html}] = contents
      assert html =~ "<body>Viewer</body>"
    end
  end

  # ============ Tests: SchemaBuilder stringify_keys ============

  describe "SchemaBuilder.stringify_keys/1" do
    test "converts atom keys to strings deeply" do
      input = %{ui: %{resourceUri: "ui://test/app.html"}}

      assert ConduitMcp.DSL.SchemaBuilder.stringify_keys(input) == %{
               "ui" => %{"resourceUri" => "ui://test/app.html"}
             }
    end

    test "passes through non-map values" do
      assert ConduitMcp.DSL.SchemaBuilder.stringify_keys("hello") == "hello"
      assert ConduitMcp.DSL.SchemaBuilder.stringify_keys(42) == 42
      assert ConduitMcp.DSL.SchemaBuilder.stringify_keys(nil) == nil
    end

    test "handles mixed atom and string keys" do
      input = %{ui: %{"already_string" => true, nested: "val"}}
      result = ConduitMcp.DSL.SchemaBuilder.stringify_keys(input)
      assert result == %{"ui" => %{"already_string" => true, "nested" => "val"}}
    end

    test "handles empty map" do
      assert ConduitMcp.DSL.SchemaBuilder.stringify_keys(%{}) == %{}
    end
  end
end

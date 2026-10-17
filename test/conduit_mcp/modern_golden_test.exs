defmodule ConduitMcp.ModernGoldenTest do
  # Golden tests: every modern (2026-07-28) response the handler produces is
  # validated against the vendored MCP JSON Schema.
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Protocol.Modern
  alias ConduitMcp.Test.McpSchema

  @version "2026-07-28"

  defmodule DslServer do
    use ConduitMcp.Server, instructions: "Use the echo tool."

    tool "echo", "Echo back the input" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => msg} -> text(msg) end)
    end

    resource "test://resource1" do
      description("Static resource")
      mime_type("text/plain")
      read(fn _conn, _params, _opts -> text("Test content") end)
    end

    resource "item://{id}" do
      description("Item by id")
      mime_type("application/json")
      read(fn _conn, params, _opts -> json(%{id: params["id"]}) end)
    end

    prompt "greeting", "A greeting prompt" do
      arg(:name, :string, "Name")
      get(fn _conn, args -> [user("Hello, #{args["name"] || "World"}!")] end)
    end
  end

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, name: "echo", description: "Echo back the input"

    schema do
      field(:message, :string, "Message", required: true)
    end

    @impl true
    def execute(%{message: msg}, _conn), do: text(msg)
  end

  defmodule StaticResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "test://resource1",
      description: "Static resource",
      mime_type: "text/plain"

    @impl true
    def execute(_params, _conn),
      do: {:ok, %{"contents" => [%{"uri" => "test://resource1", "text" => "Test content"}]}}
  end

  defmodule ItemResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "item://{id}",
      description: "Item by id",
      mime_type: "application/json"

    @impl true
    def execute(%{id: id}, _conn),
      do: {:ok, %{"contents" => [%{"uri" => "item://#{id}", "text" => ~s({"id":"#{id}"})}]}}
  end

  defmodule GreetingPrompt do
    use ConduitMcp.Component, type: :prompt, name: "greeting", description: "A greeting prompt"

    schema do
      field(:name, :string, "Name")
    end

    @impl true
    def execute(params, _conn) do
      {:ok,
       %{
         "messages" => [
           %{
             "role" => "user",
             "content" => %{"type" => "text", "text" => "Hello, #{params[:name] || "World"}!"}
           }
         ]
       }}
    end
  end

  defmodule EndpointServer do
    use ConduitMcp.Endpoint, name: "Golden Endpoint", version: "1.2.3"

    component(EchoTool)
    component(StaticResource)
    component(ItemResource)
    component(GreetingPrompt)
  end

  @servers [ConduitMcp.TestServer, DslServer, EndpointServer]

  @cacheable ~w(server/discover tools/list resources/list resources/templates/list resources/read prompts/list)

  # method => {params, result def}
  @cases [
    {"server/discover", %{}, "DiscoverResultResponse"},
    {"tools/list", %{}, "ListToolsResultResponse"},
    {"tools/call", %{"name" => "echo", "arguments" => %{"message" => "hi"}},
     "CallToolResultResponse"},
    {"resources/list", %{}, "ListResourcesResultResponse"},
    {"resources/read", %{"uri" => "test://resource1"}, "ReadResourceResultResponse"},
    {"resources/templates/list", %{}, "ListResourceTemplatesResultResponse"},
    {"prompts/list", %{}, "ListPromptsResultResponse"},
    {"prompts/get", %{"name" => "greeting", "arguments" => %{"name" => "Ada"}},
     "GetPromptResultResponse"},
    {"completion/complete",
     %{
       "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
       "argument" => %{"name" => "name", "value" => "A"}
     }, "CompleteResultResponse"}
  ]

  defp modern_meta,
    do: %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

  defp modern(method, params \\ %{}, meta \\ nil) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta || modern_meta())
    }
  end

  defp reply!(request, server) do
    assert {:reply, response} = Handler.dispatch(request, server, %Plug.Conn{})
    response
  end

  # MethodNotFoundError / InvalidParamsError are error *objects* in the schema;
  # the envelope is a JSONRPCErrorResponse.
  defp assert_error_valid(def_name, response) do
    assert_valid("JSONRPCErrorResponse", response)
    assert_valid(def_name, response["error"])
  end

  defp assert_valid(def_name, data, version \\ @version) do
    case McpSchema.validate(version, def_name, data) do
      :ok ->
        :ok

      {:error, errors} ->
        flunk("#{def_name} invalid: #{inspect(errors, pretty: true)}\n#{inspect(data)}")
    end
  end

  for server <- @servers do
    describe "#{inspect(server)} results" do
      @server server

      for {method, params, def_name} <- @cases do
        @method method
        @params params
        @def_name def_name

        test "#{method} validates as #{def_name}" do
          response = reply!(modern(@method, @params), @server)
          refute Map.has_key?(response, "error"), inspect(response)
          assert_valid(@def_name, response)
          assert Modern.http_status(response) == 200

          result = response["result"]
          assert result["resultType"] == "complete"
          assert is_map(result["_meta"]["io.modelcontextprotocol/serverInfo"])
          refute Map.has_key?(result["_meta"], "io.modelcontextprotocol/protocolVersion")

          if @method in unquote(@cacheable) do
            assert is_integer(result["ttlMs"]) and result["ttlMs"] >= 0
            assert result["cacheScope"] in ["private", "public"]
          else
            refute Map.has_key?(result, "ttlMs")
            refute Map.has_key?(result, "cacheScope")
          end
        end
      end

      test "server/discover without _meta is era-exempt and validates" do
        request = %{"jsonrpc" => "2.0", "id" => 7, "method" => "server/discover"}
        response = reply!(request, @server)
        assert_valid("DiscoverResultResponse", response)
        assert response["id"] == 7
        assert response["result"]["resultType"] == "complete"
        assert @version in response["result"]["supportedVersions"]
      end

      test "tools/call echoes the message" do
        response =
          reply!(
            modern("tools/call", %{"name" => "echo", "arguments" => %{"message" => "zz"}}),
            @server
          )

        assert [%{"type" => "text", "text" => "zz"}] = response["result"]["content"]
      end

      test "unknown method is MethodNotFoundError with 404" do
        response = reply!(modern("nope/never"), @server)
        assert_error_valid("MethodNotFoundError", response)
        assert response["error"]["code"] == -32601
        assert Modern.http_status(response) == 404
      end

      for removed <- ["initialize", "ping"] do
        @removed removed
        test "removed method #{removed} is MethodNotFoundError" do
          response = reply!(modern(@removed), @server)
          assert_error_valid("MethodNotFoundError", response)
          assert Modern.http_status(response) == 404
        end
      end

      test "unsupported _meta version is UnsupportedProtocolVersionError" do
        meta = Map.put(modern_meta(), "io.modelcontextprotocol/protocolVersion", "1999-01-01")
        response = reply!(modern("tools/list", %{}, meta), @server)
        assert_valid("UnsupportedProtocolVersionError", response)
        assert response["error"]["code"] == -32022
        assert "1999-01-01" == response["error"]["data"]["requested"]
        assert @version in response["error"]["data"]["supported"]
        assert Modern.http_status(response) == 400
      end

      test "unknown resource is InvalidParamsError -32602, never -32002" do
        response = reply!(modern("resources/read", %{"uri" => "test://missing"}), @server)
        assert_error_valid("InvalidParamsError", response)
        assert response["error"]["code"] == -32602
      end

      test "unknown tool is InvalidParamsError" do
        response = reply!(modern("tools/call", %{"name" => "nope", "arguments" => %{}}), @server)
        assert_error_valid("InvalidParamsError", response)
        assert response["error"]["code"] == -32602
      end

      test "version without capabilities is InvalidParamsError" do
        meta = %{"io.modelcontextprotocol/protocolVersion" => @version}
        response = reply!(modern("tools/list", %{}, meta), @server)
        assert_error_valid("InvalidParamsError", response)
        assert response["error"]["code"] == -32602
      end

      test "legacy initialize result validates as 2025-11-25 InitializeResult" do
        request = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "golden", "version" => "1.0.0"}
          }
        }

        response = reply!(request, @server)
        assert %{"result" => result} = response
        assert_valid("InitializeResult", result, "2025-11-25")
        refute Map.has_key?(result, "resultType")
      end
    end
  end

  describe "DSL server specifics" do
    test "templated resource reads and is listed as a template" do
      response = reply!(modern("resources/read", %{"uri" => "item://42"}), DslServer)
      assert_valid("ReadResourceResultResponse", response)

      response = reply!(modern("resources/templates/list"), DslServer)
      assert_valid("ListResourceTemplatesResultResponse", response)

      assert Enum.any?(
               response["result"]["resourceTemplates"],
               &(&1["uriTemplate"] == "item://{id}")
             )
    end

    test "discover carries instructions" do
      response = reply!(modern("server/discover"), DslServer)
      assert response["result"]["instructions"] == "Use the echo tool."
    end
  end

  describe "Endpoint server specifics" do
    test "templated resource reads" do
      response = reply!(modern("resources/read", %{"uri" => "item://42"}), EndpointServer)
      assert_valid("ReadResourceResultResponse", response)
    end
  end
end

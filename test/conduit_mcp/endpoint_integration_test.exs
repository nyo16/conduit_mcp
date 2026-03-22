defmodule ConduitMcp.EndpointIntegrationTest do
  @moduledoc """
  Full HTTP integration tests for the Endpoint + Component mode.
  Tests the complete request flow: HTTP → Transport → Handler → Endpoint → Component.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.Transport.StreamableHTTP

  # --- Components ---

  defmodule EchoComponent do
    use ConduitMcp.Component, type: :tool, description: "Echoes text"

    schema do
      field(:text, :string, "Text to echo", required: true)
    end

    @impl true
    def execute(%{text: text}, _conn), do: text(text)
  end

  defmodule UpperComponent do
    use ConduitMcp.Component, type: :tool, description: "Uppercases text"

    schema do
      field(:text, :string, "Text to uppercase", required: true)
    end

    @impl true
    def execute(%{text: text}, _conn), do: text(String.upcase(text))
  end

  defmodule UserComponent do
    use ConduitMcp.Component,
      type: :resource,
      uri: "user://{id}",
      description: "User by ID",
      mime_type: "application/json"

    @impl true
    def execute(%{id: id}, _conn) do
      {:ok,
       %{
         "contents" => [
           %{
             "uri" => "user://#{id}",
             "mimeType" => "application/json",
             "text" => JSON.encode!(%{id: id, name: "User #{id}"})
           }
         ]
       }}
    end
  end

  defmodule GreetPrompt do
    use ConduitMcp.Component, type: :prompt, description: "Greeting prompt"

    schema do
      field(:name, :string, "Name to greet", required: true)
    end

    @impl true
    def execute(%{name: name}, _conn) do
      {:ok,
       %{
         "messages" => [
           %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello #{name}!"}}
         ]
       }}
    end
  end

  defmodule ConnAwareComponent do
    use ConduitMcp.Component, type: :tool, description: "Uses conn context"

    @impl true
    def execute(_params, conn) do
      user = conn.assigns[:current_user]
      text("user: #{inspect(user)}")
    end
  end

  # --- Endpoint ---

  defmodule TestEndpoint do
    use ConduitMcp.Endpoint,
      name: "Integration Test Server",
      version: "1.2.3"

    component(EchoComponent)
    component(UpperComponent)
    component(UserComponent)
    component(GreetPrompt)
    component(ConnAwareComponent)
  end

  # --- Transport Setup ---

  @opts StreamableHTTP.init(server_module: TestEndpoint)

  # Helper to send JSON-RPC request
  defp json_rpc_request(method, params \\ %{}, id \\ 1) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    conn(:post, "/")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> StreamableHTTP.call(@opts)
  end

  defp parse_response(conn) do
    JSON.decode!(conn.resp_body)
  end

  # === Tests ===

  describe "initialize" do
    test "returns server name and version from endpoint config" do
      conn =
        json_rpc_request("initialize", %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0"},
          "capabilities" => %{}
        })

      assert conn.status == 200
      result = parse_response(conn)["result"]

      assert result["serverInfo"]["name"] == "Integration Test Server"
      assert result["serverInfo"]["version"] == "1.2.3"
    end

    test "capabilities reflect registered component types" do
      conn =
        json_rpc_request("initialize", %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0"},
          "capabilities" => %{}
        })

      caps = parse_response(conn)["result"]["capabilities"]

      assert Map.has_key?(caps, "tools")
      assert Map.has_key?(caps, "resources")
      assert Map.has_key?(caps, "prompts")
    end
  end

  describe "tools/list" do
    test "returns all registered tool components" do
      conn = json_rpc_request("tools/list")

      assert conn.status == 200
      tools = parse_response(conn)["result"]["tools"]

      names = Enum.map(tools, & &1["name"])
      assert "echo_component" in names
      assert "upper_component" in names
      assert "conn_aware_component" in names
    end

    test "tool schemas have inputSchema" do
      conn = json_rpc_request("tools/list")
      tools = parse_response(conn)["result"]["tools"]

      echo = Enum.find(tools, &(&1["name"] == "echo_component"))
      assert echo["inputSchema"]["type"] == "object"
      assert echo["inputSchema"]["properties"]["text"]
    end
  end

  describe "tools/call" do
    test "executes echo component" do
      conn =
        json_rpc_request("tools/call", %{
          "name" => "echo_component",
          "arguments" => %{"text" => "integration test"}
        })

      assert conn.status == 200
      result = parse_response(conn)["result"]
      assert hd(result["content"])["text"] == "integration test"
    end

    test "executes upper component" do
      conn =
        json_rpc_request("tools/call", %{
          "name" => "upper_component",
          "arguments" => %{"text" => "hello"}
        })

      result = parse_response(conn)["result"]
      assert hd(result["content"])["text"] == "HELLO"
    end

    test "returns error for unknown tool" do
      conn =
        json_rpc_request("tools/call", %{
          "name" => "nonexistent",
          "arguments" => %{}
        })

      response = parse_response(conn)
      assert response["error"]
    end

    test "validates required params" do
      Application.put_env(:conduit_mcp, :validation,
        runtime_validation: true,
        strict_mode: true,
        type_coercion: true
      )

      conn =
        json_rpc_request("tools/call", %{
          "name" => "echo_component",
          "arguments" => %{}
        })

      response = parse_response(conn)
      assert response["error"]["code"] == -32602
    after
      Application.delete_env(:conduit_mcp, :validation)
    end
  end

  describe "resources/list" do
    test "returns registered resource components" do
      conn = json_rpc_request("resources/list")

      assert conn.status == 200
      resources = parse_response(conn)["result"]["resources"]
      assert length(resources) == 1

      user_resource = hd(resources)
      assert user_resource["uri"] == "user://{id}"
      assert user_resource["mimeType"] == "application/json"
    end
  end

  describe "resources/read" do
    test "reads a resource by URI template matching" do
      conn = json_rpc_request("resources/read", %{"uri" => "user://42"})

      assert conn.status == 200
      contents = parse_response(conn)["result"]["contents"]
      assert hd(contents)["uri"] == "user://42"

      user = JSON.decode!(hd(contents)["text"])
      assert user["id"] == "42"
    end

    test "returns error for unmatched URI" do
      conn = json_rpc_request("resources/read", %{"uri" => "unknown://thing"})

      response = parse_response(conn)
      assert response["error"]
    end
  end

  describe "prompts/list" do
    test "returns registered prompt components" do
      conn = json_rpc_request("prompts/list")

      assert conn.status == 200
      prompts = parse_response(conn)["result"]["prompts"]
      assert length(prompts) == 1
      assert hd(prompts)["name"] == "greet_prompt"
    end
  end

  describe "prompts/get" do
    test "gets a prompt with arguments" do
      conn =
        json_rpc_request("prompts/get", %{
          "name" => "greet_prompt",
          "arguments" => %{"name" => "World"}
        })

      assert conn.status == 200
      messages = parse_response(conn)["result"]["messages"]
      assert hd(messages)["content"]["text"] == "Hello World!"
    end

    test "returns error for unknown prompt" do
      conn =
        json_rpc_request("prompts/get", %{
          "name" => "nonexistent",
          "arguments" => %{}
        })

      response = parse_response(conn)
      assert response["error"]
    end
  end

  describe "endpoint config auto-extraction by transport" do
    test "transport extracts server_name from endpoint config" do
      # When no explicit server_name is passed, transport reads from endpoint
      opts = StreamableHTTP.init(server_module: TestEndpoint)

      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "test", "version" => "1.0"},
            "capabilities" => %{}
          }
        })
        |> StreamableHTTP.call(opts)

      result = parse_response(conn)["result"]
      assert result["serverInfo"]["name"] == "Integration Test Server"
      assert result["serverInfo"]["version"] == "1.2.3"
    end

    test "explicit transport opts override endpoint config" do
      opts =
        StreamableHTTP.init(
          server_module: TestEndpoint,
          server_name: "Overridden Name",
          server_version: "9.9.9"
        )

      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "test", "version" => "1.0"},
            "capabilities" => %{}
          }
        })
        |> StreamableHTTP.call(opts)

      result = parse_response(conn)["result"]
      assert result["serverInfo"]["name"] == "Overridden Name"
      assert result["serverInfo"]["version"] == "9.9.9"
    end
  end

  describe "ping" do
    test "ping works through endpoint" do
      conn = json_rpc_request("ping")

      assert conn.status == 200
      result = parse_response(conn)["result"]
      assert result == %{}
    end
  end

  describe "backward compatibility" do
    test "DSL mode server still works through transport" do
      # TestServer uses dsl: false mode — verify it still works
      dsl_opts = StreamableHTTP.init(server_module: ConduitMcp.TestServer)

      conn =
        conn(:post, "/")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })
        |> StreamableHTTP.call(dsl_opts)

      assert conn.status == 200
      result = parse_response(conn)["result"]
      assert is_list(result["tools"])
    end
  end
end

defmodule ConduitMcp.TestServer do
  @moduledoc """
  Test MCP server for unit tests.

  Uses manual implementation (dsl: false) to test the non-DSL path.
  """
  use ConduitMcp.Server, dsl: false

  @tools [
    %{
      "name" => "echo",
      "description" => "Echo back the input",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string"}
        },
        "required" => ["message"]
      }
    },
    %{
      "name" => "fail",
      "description" => "Always fails",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  ]

  @resources [
    %{
      "uri" => "test://resource1",
      "name" => "Test Resource",
      "mimeType" => "text/plain"
    }
  ]

  @prompts [
    %{
      "name" => "greeting",
      "description" => "A greeting prompt"
    }
  ]

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "echo", %{"message" => msg}) do
    result = %{
      "content" => [
        %{"type" => "text", "text" => msg}
      ]
    }

    {:ok, result}
  end

  def handle_call_tool(_conn, "fail", _params) do
    {:error, %{"code" => -32000, "message" => "Tool execution failed"}}
  end

  def handle_call_tool(_conn, _name, _params) do
    # Matches the library's manual-mode default (ConduitMcp.Errors.invalid_params/0).
    # This fixture backs handler_test, security_test and both transport tests, so
    # a stale code here is what every request-level miss in the suite observes.
    {:error, %{"code" => ConduitMcp.Errors.invalid_params(), "message" => "Tool not found"}}
  end

  @impl true
  def handle_list_resources(_conn) do
    {:ok, %{"resources" => @resources}}
  end

  @impl true
  def handle_read_resource(_conn, "test://resource1") do
    result = %{
      "contents" => [
        %{"uri" => "test://resource1", "mimeType" => "text/plain", "text" => "Test content"}
      ]
    }

    {:ok, result}
  end

  def handle_read_resource(_conn, _uri) do
    {:error,
     %{"code" => ConduitMcp.Errors.resource_not_found(), "message" => "Resource not found"}}
  end

  @impl true
  def handle_list_prompts(_conn) do
    {:ok, %{"prompts" => @prompts}}
  end

  @impl true
  def handle_get_prompt(_conn, "greeting", args) do
    name = Map.get(args, "name", "World")

    result = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => %{"type" => "text", "text" => "Hello, #{name}!"}
        }
      ]
    }

    {:ok, result}
  end

  def handle_get_prompt(_conn, _name, _args) do
    {:error, %{"code" => ConduitMcp.Errors.invalid_params(), "message" => "Prompt not found"}}
  end
end

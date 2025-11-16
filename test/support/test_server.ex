defmodule ConduitMcp.TestServer do
  @moduledoc """
  Test MCP server for unit tests.
  """
  use ConduitMcp.Server

  @impl true
  def mcp_init(opts) do
    config = %{
      tools: [
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
      ],
      resources: [
        %{
          "uri" => "test://resource1",
          "name" => "Test Resource",
          "mimeType" => "text/plain"
        }
      ],
      prompts: [
        %{
          "name" => "greeting",
          "description" => "A greeting prompt"
        }
      ]
    }

    {:ok, Map.merge(config, Map.new(opts))}
  end

  @impl true
  def handle_list_tools(config) do
    {:ok, %{"tools" => config.tools}}
  end

  @impl true
  def handle_call_tool("echo", %{"message" => msg}, _config) do
    result = %{
      "content" => [
        %{"type" => "text", "text" => msg}
      ]
    }

    {:ok, result}
  end

  def handle_call_tool("fail", _params, _config) do
    {:error, %{"code" => -32000, "message" => "Tool execution failed"}}
  end

  def handle_call_tool(_name, _params, _config) do
    {:error, %{"code" => -32601, "message" => "Tool not found"}}
  end

  @impl true
  def handle_list_resources(config) do
    {:ok, %{"resources" => config.resources}}
  end

  @impl true
  def handle_read_resource("test://resource1", _config) do
    result = %{
      "contents" => [
        %{"uri" => "test://resource1", "mimeType" => "text/plain", "text" => "Test content"}
      ]
    }

    {:ok, result}
  end

  def handle_read_resource(_uri, _config) do
    {:error, %{"code" => -32601, "message" => "Resource not found"}}
  end

  @impl true
  def handle_list_prompts(config) do
    {:ok, %{"prompts" => config.prompts}}
  end

  @impl true
  def handle_get_prompt("greeting", args, _config) do
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

  def handle_get_prompt(_name, _args, _config) do
    {:error, %{"code" => -32601, "message" => "Prompt not found"}}
  end
end

defmodule ConduitMcp.TestServer do
  @moduledoc """
  Test MCP server for unit tests.
  """
  use ConduitMcp.Server

  @impl true
  def mcp_init(opts) do
    state = %{
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
      ],
      call_count: 0
    }

    {:ok, Map.merge(state, Map.new(opts))}
  end

  @impl true
  def handle_list_tools(state) do
    {:reply, %{"tools" => state.tools}, state}
  end

  @impl true
  def handle_call_tool("echo", %{"message" => msg}, state) do
    result = %{
      "content" => [
        %{"type" => "text", "text" => msg}
      ]
    }

    new_state = Map.update!(state, :call_count, &(&1 + 1))
    {:reply, result, new_state}
  end

  def handle_call_tool("fail", _params, state) do
    {:error, %{code: -32000, message: "Tool execution failed"}, state}
  end

  def handle_call_tool(_name, _params, state) do
    {:error, %{code: -32601, message: "Tool not found"}, state}
  end

  @impl true
  def handle_list_resources(state) do
    {:reply, %{"resources" => state.resources}, state}
  end

  @impl true
  def handle_read_resource("test://resource1", state) do
    result = %{
      "contents" => [
        %{"uri" => "test://resource1", "mimeType" => "text/plain", "text" => "Test content"}
      ]
    }

    {:reply, result, state}
  end

  def handle_read_resource(_uri, state) do
    {:error, %{code: -32601, message: "Resource not found"}, state}
  end

  @impl true
  def handle_list_prompts(state) do
    {:reply, %{"prompts" => state.prompts}, state}
  end

  @impl true
  def handle_get_prompt("greeting", args, state) do
    name = Map.get(args, "name", "World")

    result = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => %{"type" => "text", "text" => "Hello, #{name}!"}
        }
      ]
    }

    {:reply, result, state}
  end

  def handle_get_prompt(_name, _args, state) do
    {:error, %{code: -32601, message: "Prompt not found"}, state}
  end
end

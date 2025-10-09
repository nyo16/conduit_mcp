defmodule PhoenixMcp.MCPServer do
  @moduledoc """
  MCP Server implementation for Phoenix app.

  Provides echo and reverse_string tools integrated into the Phoenix application.
  """

  use ConduitMcp.Server

  @impl true
  def mcp_init(_opts) do
    tools = [
      %{
        "name" => "echo",
        "description" => "Echoes back the input message",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{
              "type" => "string",
              "description" => "The message to echo back"
            }
          },
          "required" => ["message"]
        }
      },
      %{
        "name" => "reverse_string",
        "description" => "Reverses a string",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "text" => %{
              "type" => "string",
              "description" => "The text to reverse"
            }
          },
          "required" => ["text"]
        }
      }
    ]

    state = %{tools: tools}
    {:ok, state}
  end

  @impl true
  def handle_list_tools(state) do
    {:reply, %{"tools" => state.tools}, state}
  end

  @impl true
  def handle_call_tool("echo", %{"message" => message}, state) do
    result = %{
      "content" => [
        %{
          "type" => "text",
          "text" => message
        }
      ]
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call_tool("reverse_string", %{"text" => text}, state) do
    reversed = String.reverse(text)

    result = %{
      "content" => [
        %{
          "type" => "text",
          "text" => reversed
        }
      ]
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call_tool(tool_name, _params, state) do
    error = %{
      code: -32602,
      message: "Unknown tool: #{tool_name}"
    }

    {:error, error, state}
  end
end

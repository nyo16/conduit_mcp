defmodule Examples.SimpleToolsServer do
  @moduledoc """
  Example MCP server with simple tools: echo and reverse_string.

  This server demonstrates:
  - Defining tools with input schemas
  - Handling tool calls
  - Returning structured responses
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

    config = %{tools: tools}
    {:ok, config}
  end

  @impl true
  def handle_list_tools(config) do
    {:ok, %{"tools" => config.tools}}
  end

  @impl true
  def handle_call_tool("echo", %{"message" => message}, _config) do
    result = %{
      "content" => [
        %{
          "type" => "text",
          "text" => message
        }
      ]
    }

    {:ok, result}
  end

  @impl true
  def handle_call_tool("reverse_string", %{"text" => text}, _config) do
    reversed = String.reverse(text)

    result = %{
      "content" => [
        %{
          "type" => "text",
          "text" => reversed
        }
      ]
    }

    {:ok, result}
  end

  @impl true
  def handle_call_tool(tool_name, _params, _config) do
    error = %{
      "code" => -32602,
      "message" => "Unknown tool: #{tool_name}"
    }

    {:error, error}
  end
end

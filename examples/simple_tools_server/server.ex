defmodule Examples.SimpleToolsServer do
  @moduledoc """
  Example MCP server with simple tools: echo and reverse_string.

  This server demonstrates:
  - Defining tools with input schemas
  - Handling tool calls
  - Returning structured responses
  """

  use ConduitMcp.Server

  @tools [
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

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "echo", %{"message" => message}) do
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
  def handle_call_tool(_conn, "reverse_string", %{"text" => text}) do
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
  def handle_call_tool(_conn, tool_name, _params) do
    error = %{
      "code" => -32602,
      "message" => "Unknown tool: #{tool_name}"
    }

    {:error, error}
  end
end

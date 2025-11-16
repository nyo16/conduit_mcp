defmodule Examples.SimpleToolsServer do
  @moduledoc """
  Example MCP server with simple tools: echo and reverse_string.

  This server demonstrates:
  - Using the ConduitMcp.Server DSL for clean tool definitions
  - Handling tool calls with inline functions
  - Returning structured responses using helpers (text/1)
  """

  use ConduitMcp.Server

  tool "echo", "Echoes back the input message" do
    param :message, :string, "The message to echo back", required: true

    handle fn _conn, %{"message" => message} ->
      text(message)
    end
  end

  tool "reverse_string", "Reverses a string" do
    param :text, :string, "The text to reverse", required: true

    handle fn _conn, %{"text" => text} ->
      text(String.reverse(text))
    end
  end
end

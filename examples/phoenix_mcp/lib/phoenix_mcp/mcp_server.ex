defmodule PhoenixMcp.MCPServer do
  @moduledoc """
  MCP Server implementation for Phoenix app.

  Demonstrates using the ConduitMcp.Server DSL for clean tool definitions
  integrated directly into a Phoenix application.
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

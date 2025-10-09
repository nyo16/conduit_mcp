#!/usr/bin/env elixir

# Simple runner script for the MCP server example
# Usage: elixir examples/simple_tools_server/run.exs

# Add the lib path
Code.append_path("_build/dev/lib/conduit_mcp/ebin")
Code.append_path("_build/dev/lib/jason/ebin")
Code.append_path("_build/dev/lib/plug/ebin")
Code.append_path("_build/dev/lib/bandit/ebin")
Code.append_path("_build/dev/lib/thousand_island/ebin")
Code.append_path("_build/dev/lib/telemetry/ebin")
Code.append_path("_build/dev/lib/plug_crypto/ebin")
Code.append_path("_build/dev/lib/mime/ebin")
Code.append_path("_build/dev/lib/hpax/ebin")
Code.append_path("_build/dev/lib/websock/ebin")

# Compile the example files
Code.compile_file("examples/simple_tools_server/server.ex")
Code.compile_file("examples/simple_tools_server/application.ex")

# Start the application
{:ok, _} = Examples.SimpleToolsServer.Application.start(:normal, [])

transport = System.get_env("TRANSPORT", "streamable_http")
port = System.get_env("PORT", "4001")

{endpoints, inspector_url, inspector_transport} =
  case transport do
    "sse" ->
      {
        """
          - SSE Stream: http://localhost:#{port}/sse
          - Messages: http://localhost:#{port}/message
        """,
        "http://localhost:#{port}/sse",
        "SSE"
      }

    _ ->
      {
        """
          - Streamable HTTP: http://localhost:#{port}/
        """,
        "http://localhost:#{port}/",
        "Streamable HTTP"
      }
  end

IO.puts("""

🚀 Simple Tools MCP Server is running!

Transport: #{transport}
#{endpoints}  - Health: http://localhost:#{port}/health

Available Tools:
  - echo: Echoes back a message
  - reverse_string: Reverses a string

For MCP Inspector:
  - URL: #{inspector_url}
  - Transport: #{inspector_transport}

Press Ctrl+C to stop the server.
""")

# Keep the process alive
Process.sleep(:infinity)

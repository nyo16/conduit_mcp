#!/usr/bin/env elixir

# Example: Monitor MCP tool response times with telemetry
# Run this before starting the MCP server to see telemetry events

defmodule TelemetryExample do
  require Logger

  def setup do
    # Attach handler to capture tool response times
    :telemetry.attach(
      "tool-response-time-monitor",
      [:conduit_mcp, :tool, :execute],
      &handle_tool_execution/4,
      nil
    )

    # Attach handler for all requests
    :telemetry.attach(
      "request-monitor",
      [:conduit_mcp, :request, :stop],
      &handle_request/4,
      nil
    )

    IO.puts("""

    ✅ Telemetry handlers attached!

    Monitoring:
    - Tool execution times
    - Request durations
    - Error rates

    Start your MCP server and make requests to see telemetry events.
    """)
  end

  defp handle_tool_execution(_event, %{duration: duration}, metadata, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    status_icon = if metadata.status == :ok, do: "✓", else: "✗"

    IO.puts("""

    🔧 Tool Executed: #{metadata.tool_name}
       Status: #{status_icon} #{metadata.status}
       Response Time: #{duration_ms}ms
       Server: #{inspect(metadata.server_module)}
    """)

    # Alert on slow tools
    cond do
      duration_ms > 5000 ->
        Logger.error("🚨 CRITICAL: Tool #{metadata.tool_name} took #{duration_ms}ms!")

      duration_ms > 1000 ->
        Logger.warning("⚠️  SLOW: Tool #{metadata.tool_name} took #{duration_ms}ms")

      true ->
        :ok
    end
  end

  defp handle_request(_event, %{duration: duration}, metadata, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.debug("Request: #{metadata.method} completed in #{duration_ms}ms (#{metadata.status})")
  end
end

# Run setup
TelemetryExample.setup()

# Keep the script running
IO.puts("\nPress Ctrl+C to exit...\n")
Process.sleep(:infinity)

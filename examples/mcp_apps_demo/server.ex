# MCP Apps Demo Server
#
# This example shows how to build an MCP server with interactive UI
# using the MCP Apps extension. Tools can link to HTML resources that
# hosts render as sandboxed iframes.
#
# Run with: elixir examples/mcp_apps_demo/server.ex
# (Requires conduit_mcp as a dependency in your project)

defmodule McpAppsDemo.Server do
  use ConduitMcp.Server

  # ---- Option 1: Explicit tool + resource pair ----

  # Tool with ui/1 — declares that this tool has a linked UI
  tool "server_health", "Live server health dashboard" do
    ui("ui://server-health/dashboard.html")

    handle(fn _conn, _params ->
      metrics = %{
        memory_mb: div(:erlang.memory(:total), 1_048_576),
        processes: :erlang.system_info(:process_count),
        uptime_sec: div(elem(:erlang.statistics(:wall_clock), 0), 1000),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      json(metrics)
    end)
  end

  # The matching ui:// resource serves the bundled HTML file
  resource "ui://server-health/dashboard.html" do
    description("Server health dashboard UI")
    mime_type("text/html")

    read(fn _conn, _params, _opts ->
      html = File.read!(Path.join(__DIR__, "priv/mcp_apps/dashboard.html"))
      raw_resource(html, "text/html")
    end)
  end

  # A tool the UI can call back into for live data
  tool "get_live_metrics", "Get current server metrics" do
    handle(fn _conn, _params ->
      json(%{
        memory_mb: div(:erlang.memory(:total), 1_048_576),
        processes: :erlang.system_info(:process_count),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end

  # ---- Option 2: app/2 convenience macro ----
  # (Uncomment below to try the shorthand version)
  #
  # app "quick_metrics", "Quick metrics view" do
  #   view "examples/mcp_apps_demo/priv/mcp_apps/dashboard.html"
  #
  #   handle fn _conn, _params ->
  #     json(%{
  #       memory_mb: div(:erlang.memory(:total), 1_048_576),
  #       processes: :erlang.system_info(:process_count)
  #     })
  #   end
  # end
end

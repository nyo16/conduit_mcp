defmodule McpAppsDemo.Server do
  use ConduitMcp.Server

  # Tool with linked UI — the host sees _meta.ui.resourceUri and renders the iframe
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
    mime_type("text/html;profile=mcp-app")

    read(fn _conn, _params, _opts ->
      html = File.read!(Application.app_dir(:mcp_apps_demo, "priv/mcp_apps/dashboard.html"))
      app_html(html)
    end)
  end

  # A tool the UI can call back into for live data
  tool "get_live_metrics", "Get current server metrics" do
    handle(fn _conn, _params ->
      json(%{
        memory_mb: div(:erlang.memory(:total), 1_048_576),
        processes: :erlang.system_info(:process_count),
        uptime_sec: div(elem(:erlang.statistics(:wall_clock), 0), 1000),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end
end

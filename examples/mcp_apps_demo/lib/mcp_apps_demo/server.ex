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

  # ---- Process Explorer: sortable table of BEAM processes ----

  tool "process_explorer", "Interactive BEAM process explorer" do
    ui("ui://process-explorer/app.html")

    handle(fn _conn, _params ->
      procs =
        Process.list()
        |> Enum.take(50)
        |> Enum.map(fn pid ->
          info =
            Process.info(pid, [:registered_name, :memory, :message_queue_len, :current_function])

          case info do
            nil ->
              nil

            info ->
              %{
                pid: inspect(pid),
                name:
                  case info[:registered_name] do
                    [] -> nil
                    name -> to_string(name)
                  end,
                memory_kb: div(info[:memory] || 0, 1024),
                msg_queue: info[:message_queue_len] || 0,
                current_fn: inspect(info[:current_function])
              }
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.memory_kb, :desc)

      json(%{processes: procs, total: length(Process.list())})
    end)
  end

  resource "ui://process-explorer/app.html" do
    description("Process explorer UI")
    mime_type("text/html;profile=mcp-app")

    read(fn _conn, _params, _opts ->
      html =
        File.read!(Application.app_dir(:mcp_apps_demo, "priv/mcp_apps/process_explorer.html"))

      app_html(html)
    end)
  end

  # ---- Notepad: create and manage notes with form submission ----

  tool "notepad", "Interactive notepad — create and manage notes" do
    ui("ui://notepad/app.html")

    handle(fn _conn, _params ->
      notes = :persistent_term.get(:mcp_notes, [])
      json(%{notes: notes})
    end)
  end

  tool "save_note", "Save a note" do
    param(:title, :string, "Note title", required: true)
    param(:content, :string, "Note content", required: true)

    handle(fn _conn, params ->
      notes = :persistent_term.get(:mcp_notes, [])

      note = %{
        id: System.unique_integer([:positive]),
        title: params["title"],
        content: params["content"],
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      :persistent_term.put(:mcp_notes, [note | notes])
      json(%{saved: note, total: length(notes) + 1})
    end)
  end

  tool "delete_note", "Delete a note by ID" do
    param(:id, :integer, "Note ID", required: true)

    handle(fn _conn, params ->
      notes = :persistent_term.get(:mcp_notes, [])
      updated = Enum.reject(notes, &(&1.id == params["id"]))
      :persistent_term.put(:mcp_notes, updated)
      json(%{deleted: params["id"], remaining: length(updated)})
    end)
  end

  resource "ui://notepad/app.html" do
    description("Notepad UI")
    mime_type("text/html;profile=mcp-app")

    read(fn _conn, _params, _opts ->
      html = File.read!(Application.app_dir(:mcp_apps_demo, "priv/mcp_apps/notepad.html"))
      app_html(html)
    end)
  end

  # ---- Unit Converter: live conversion with dropdowns ----

  tool "unit_converter", "Interactive unit converter" do
    ui("ui://converter/app.html")

    handle(fn _conn, _params ->
      json(%{
        categories: %{
          length: %{
            units: ["meters", "feet", "inches", "centimeters", "kilometers", "miles"],
            rates: %{
              meters: 1,
              feet: 3.28084,
              inches: 39.3701,
              centimeters: 100,
              kilometers: 0.001,
              miles: 0.000621371
            }
          },
          weight: %{
            units: ["kilograms", "pounds", "ounces", "grams"],
            rates: %{kilograms: 1, pounds: 2.20462, ounces: 35.274, grams: 1000}
          },
          temperature: %{
            units: ["celsius", "fahrenheit", "kelvin"],
            rates: "special"
          }
        }
      })
    end)
  end

  resource "ui://converter/app.html" do
    description("Unit converter UI")
    mime_type("text/html;profile=mcp-app")

    read(fn _conn, _params, _opts ->
      html = File.read!(Application.app_dir(:mcp_apps_demo, "priv/mcp_apps/converter.html"))
      app_html(html)
    end)
  end
end

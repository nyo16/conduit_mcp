defmodule Examples.ObanTasksServer do
  @moduledoc """
  MCP server demonstrating the 2025-11-25 tasks lifecycle backed by Oban
  + SQLite.

  Real tools (`slow_render`, `ask_then_render`, `provide_render_input`)
  land in the next commits — scaffold ships with a single sync `ping`
  tool so the example boots end-to-end on port 4041 while the rest of
  the wiring is built up.
  """

  use ConduitMcp.Server

  tool "ping", "Sync round-trip — proves the server is alive." do
    handle(fn _conn, _params -> text("pong") end)
  end
end

defmodule ConduitMcp.Test.Client.StdioMrtrServer do
  @moduledoc """
  A DSL server whose `approve` tool asks the client for an elicitation
  (`{:input_required, ...}`) before it answers, and whose `touch` tool
  announces a tools change (`ConduitMcp.notify_tools_changed/0`) to the
  fixture's listens; the stdio fixture serves it with `--server
  ConduitMcp.Test.Client.StdioMrtrServer`.
  """
  use ConduitMcp.Server

  tool "echo", "Echoes the message" do
    param(:message, :string, "Message", required: true)
    handle(fn _conn, %{"message" => message} -> text(message) end)
  end

  tool "touch", "Announces a tools change" do
    handle(fn _conn, _params ->
      ConduitMcp.notify_tools_changed()
      text("touched")
    end)
  end

  tool "approve", "Answers after the user approves" do
    handle(fn conn, _params ->
      case conn.assigns[:mcp_input] do
        nil ->
          {:input_required,
           %{
             "ok" =>
               ConduitMcp.MRTR.elicit("Approve?", %{"type" => "object", "properties" => %{}})
           }, %{"step" => 1}}

        %{state: %{"step" => 1}, responses: %{"ok" => %{"action" => action}}} ->
          text("approval: " <> action)
      end
    end)
  end
end

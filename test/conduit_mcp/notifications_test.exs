defmodule ConduitMcp.NotificationsTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Notifications
  alias ConduitMcp.Test.McpSchema

  # The shapes are identical in both schemas (only `_meta` typing and the
  # delivery wording differ), so every builder is checked against both.
  @versions ["2025-11-25", "2026-07-28"]

  defp assert_valid(def_name, message) do
    for version <- @versions do
      assert :ok == McpSchema.validate(version, def_name, message), "#{version} #{def_name}"
    end
  end

  test "progress_notification/3 carries token, progress and optional fields" do
    n = Notifications.progress_notification("token-1", 50, total: 100, message: "Half done")

    assert n["method"] == "notifications/progress"

    assert n["params"] == %{
             "progressToken" => "token-1",
             "progress" => 50,
             "total" => 100,
             "message" => "Half done"
           }

    refute Map.has_key?(n, "id")
    assert_valid("ProgressNotification", n)
  end

  test "progress_notification/3 omits unset options" do
    n = Notifications.progress_notification(7, 1)
    assert n["params"] == %{"progressToken" => 7, "progress" => 1}
    assert_valid("ProgressNotification", n)
  end

  test "log_notification/3" do
    n = Notifications.log_notification("info", %{"k" => 1}, logger: "my-server")

    assert n["method"] == "notifications/message"
    assert n["params"] == %{"level" => "info", "data" => %{"k" => 1}, "logger" => "my-server"}
    assert_valid("LoggingMessageNotification", n)
  end

  test "resource_updated_notification/1" do
    n = Notifications.resource_updated_notification("file:///test.txt")
    assert n["method"] == "notifications/resources/updated"
    assert n["params"] == %{"uri" => "file:///test.txt"}
    assert_valid("ResourceUpdatedNotification", n)
  end

  test "list_changed notifications" do
    for {n, method, def_name} <- [
          {Notifications.resource_list_changed_notification(),
           "notifications/resources/list_changed", "ResourceListChangedNotification"},
          {Notifications.tool_list_changed_notification(), "notifications/tools/list_changed",
           "ToolListChangedNotification"},
          {Notifications.prompt_list_changed_notification(), "notifications/prompts/list_changed",
           "PromptListChangedNotification"}
        ] do
      assert n == %{"jsonrpc" => "2.0", "method" => method}
      assert_valid(def_name, n)
    end
  end
end

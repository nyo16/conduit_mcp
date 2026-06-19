defmodule ConduitMcp.Tasks.OwnerExtractorTest do
  # async: false — the override test mutates the global :task_owner_fun
  # application env, which must not run concurrently with other modules.
  use ExUnit.Case, async: false

  alias ConduitMcp.Tasks

  test "owner/1 uses the default extractor (conn.assigns[:current_user])" do
    assert Tasks.owner(Plug.Conn.assign(%Plug.Conn{}, :current_user, "alice")) == "alice"
    assert Tasks.owner(%Plug.Conn{}) == nil
    assert Tasks.owner(nil) == nil
  end

  test ":task_owner_fun config overrides the extractor" do
    # Snapshot + restore the real prior value so we don't leak global state.
    prev = Application.get_env(:conduit_mcp, :task_owner_fun)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:conduit_mcp, :task_owner_fun, prev),
        else: Application.delete_env(:conduit_mcp, :task_owner_fun)
    end)

    Application.put_env(:conduit_mcp, :task_owner_fun, fn conn -> conn.assigns[:tenant] end)

    assert Tasks.owner(Plug.Conn.assign(%Plug.Conn{}, :tenant, "acme")) == "acme"
  end
end

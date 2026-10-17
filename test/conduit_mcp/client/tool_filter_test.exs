defmodule ConduitMcp.Client.ToolFilterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.{Tool, ToolFilter}

  defp tool(server_id, name) do
    {:ok, tool} = Tool.from_wire(server_id, %{"name" => name, "inputSchema" => %{}})
    tool
  end

  defp visible?(opts, server_id, name, ctx \\ %{}),
    do: ToolFilter.visible?(ToolFilter.compile(opts), tool(server_id, name), ctx)

  describe "string patterns" do
    test "an empty filter shows everything" do
      assert visible?([], "gh", "anything")
    end

    test "include restricts to matching tools" do
      opts = [include: ["github/*", "fs/read_*"]]

      assert visible?(opts, "github", "create_issue")
      assert visible?(opts, "fs", "read_file")
      refute visible?(opts, "fs", "write_file")
      refute visible?(opts, "other", "read_file")
    end

    test "a bare name means any server" do
      assert visible?([include: ["read_file"]], "a", "read_file")
      assert visible?([include: ["read_file"]], "b", "read_file")
      refute visible?([include: ["read_file"]], "b", "read_files")
    end

    test "* globs within one segment only" do
      opts = [include: ["git*/get_*"]]

      assert visible?(opts, "github", "get_x")
      assert visible?(opts, "git", "get_")
      refute visible?(opts, "gitlab", "list_x")
      refute visible?(opts, "xgit", "get_x")
      # A bare pattern globs the tool name, never the server.
      refute visible?([include: ["gh*"]], "gh", "list")
      assert visible?([include: ["*/*_issue*"]], "a", "create_issue_comment")
      assert visible?([include: ["a*b*c"]], "s", "abc")
      refute visible?([include: ["a*b*c"]], "s", "acb")
    end

    test "exclude wins over include" do
      opts = [include: ["github/*"], exclude: ["github/delete_*"]]

      assert visible?(opts, "github", "get_repo")
      refute visible?(opts, "github", "delete_repo")
    end

    test "exclude matches loosely, include exactly" do
      for name <- ["delete_repo", "Delete_Repo", "delete-repo", "DELETE.REPO"] do
        refute visible?([exclude: ["*/delete_repo"]], "gh", name), name
      end

      assert visible?([include: ["gh/delete_repo"]], "gh", "delete_repo")
      refute visible?([include: ["gh/delete_repo"]], "gh", "Delete_Repo")
    end

    test "matching is on the {server, tool} tuple, never the concatenation" do
      opts = [exclude: ["a_b/c"]]

      refute visible?(opts, "a_b", "c")
      assert visible?(opts, "a", "b_c")
      assert visible?([exclude: ["a/b_c"]], "a_b", "c")
    end
  end

  describe "regex and function patterns" do
    test "{server, regex} matches the tool name" do
      opts = [include: [{"fs", ~r/^read/}], exclude: [{"*", ~r/secret/}]]

      assert visible?(opts, "fs", "read_file")
      refute visible?(opts, "db", "read_file")
      refute visible?(opts, "fs", "read_secret")
    end

    test "a loose regex exclude also tries the folded name" do
      refute visible?([exclude: [{"*", ~r/^delete_/}]], "gh", "Delete-Repo")
    end

    test "functions see the tool and ctx" do
      only_admins = fn %Tool{name: name}, ctx -> name != "admin" or ctx.assigns.admin? end
      opts = [exclude: [fn tool, ctx -> not only_admins.(tool, ctx) end]]

      assert visible?(opts, "s", "admin", %{assigns: %{admin?: true}})
      refute visible?(opts, "s", "admin", %{assigns: %{admin?: false}})
      assert visible?(opts, "s", "other", %{assigns: %{admin?: false}})
    end

    test "a failing function hides via exclude and does not include" do
      raising = fn _tool, _ctx -> raise "boom" end
      garbage = fn _tool, _ctx -> :yes end

      refute visible?([exclude: [raising]], "s", "t")
      refute visible?([exclude: [garbage]], "s", "t")
      refute visible?([include: [raising]], "s", "t")
      refute visible?([include: [garbage]], "s", "t")
      assert visible?([include: [garbage, "s/t"]], "s", "t")
    end
  end

  describe "static_visible?/2" do
    test "applies only string and regex patterns" do
      filter = ToolFilter.compile(exclude: ["*/drop_*", fn _, _ -> true end])

      assert ToolFilter.static_visible?(filter, tool("db", "select"))
      refute ToolFilter.static_visible?(filter, tool("db", "drop_table"))
      refute ToolFilter.visible?(filter, tool("db", "select"), %{})
    end

    test "keeps tools a function include might show" do
      dynamic = ToolFilter.compile(include: ["fs/*", fn _, ctx -> ctx[:all?] == true end])
      static = ToolFilter.compile(include: ["fs/*"])

      assert ToolFilter.static_visible?(dynamic, tool("db", "x"))
      refute ToolFilter.static_visible?(static, tool("db", "x"))
      assert ToolFilter.static_visible?(static, tool("fs", "x"))
    end

    property "never hides a tool visible?/3 would show" do
      check all(
              opts <- filter_opts(),
              server <- member_of(["fs", "db", "gh"]),
              name <- member_of(["read", "write", "Read-X", "drop_all", "x.y"]),
              flag <- boolean()
            ) do
        filter = ToolFilter.compile(opts)
        tool = tool(server, name)

        if ToolFilter.visible?(filter, tool, %{flag: flag}),
          do: assert(ToolFilter.static_visible?(filter, tool))
      end
    end
  end

  describe "compile/1" do
    test "raises naming the bad entry" do
      for {opts, fragment} <- [
            {[include: [""]], ~s(invalid tool filter :include entry "")},
            {[exclude: ["/x"]], ~s(entry "/x")},
            {[exclude: ["x/"]], ~s(entry "x/")},
            {[include: [:atom]], "entry :atom"},
            {[include: [fn _ -> true end]], "2 arguments"},
            {[include: [{:annotation, :read_only, true}]], ":annotation rules are not accepted"},
            {[include: [{"a:b", ~r/x/}]], "cannot contain"},
            {[include: "x"], ":include must be a list"},
            {[filter: []], "unknown tool filter option"}
          ] do
        error = assert_raise ArgumentError, fn -> ToolFilter.compile(opts) end
        assert error.message =~ fragment
      end
    end
  end

  defp filter_opts do
    pattern =
      one_of([
        member_of(["*", "fs/*", "read", "*/read*", "db/drop_*", "x_y", "*/read-x"]),
        constant({"gh", ~r/^w/}),
        constant(fn _tool, ctx -> ctx.flag end),
        constant(fn %Tool{name: name}, _ctx -> String.length(name) > 4 end)
      ])

    fixed_map(%{
      include: list_of(pattern, max_length: 3),
      exclude: list_of(pattern, max_length: 3)
    })
    |> map(&Map.to_list/1)
  end
end

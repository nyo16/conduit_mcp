defmodule ConduitMcp.Client.Adapters.SharedRulesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.Adapters.{Anthropic, Gemini, OpenAI}
  alias ConduitMcp.Client.{Naming, Tool}

  defp tool(server_id, name, description) do
    {:ok, tool} =
      Tool.from_wire(server_id, %{
        "name" => name,
        "description" => description,
        "inputSchema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
      })

    tool
  end

  defp encoded_outputs(toolset) do
    {chat, _} = OpenAI.tools(toolset, api: :chat)
    {responses, _} = OpenAI.tools(toolset, api: :responses, strict: false)
    {strict, _} = OpenAI.tools(toolset, api: :responses, strict: true)

    [
      Anthropic.tools(toolset, cache_control: :last),
      chat,
      responses,
      strict,
      Gemini.function_declarations(toolset)
    ]
    |> Enum.map(&JSON.encode!/1)
  end

  test "PO-7: adapter output contains no excluded tool names or descriptions" do
    listed = [
      tool("files", "visible", "VISIBLE_DESC"),
      tool("files", "dup.name", "COLLIDER_ONE_DESC"),
      tool("files", "dup_name", "COLLIDER_TWO_DESC"),
      tool("files", "bad name", "INVALID_NAME_DESC"),
      tool("files", "filtered_out", "FILTERED_DESC")
    ]

    # The selection filter runs before naming; collisions and invalid names
    # are excluded by `Naming.build/2` itself.
    selected = Enum.reject(listed, &(&1.name == "filtered_out"))
    {toolset, report} = Naming.build([{"files", selected}])

    assert length(report.rejected) == 3

    for json <- encoded_outputs(toolset) do
      assert json =~ "files__visible"
      assert json =~ "VISIBLE_DESC"

      for excluded <- ["dup", "bad name", "filtered_out", "COLLIDER", "INVALID_NAME", "FILTERED"],
          do: refute(json =~ excluded, "#{inspect(excluded)} leaked into #{json}")
    end
  end

  test "PI-1: every adapter strips bidi, zero-width and tag characters from descriptions" do
    dirty = "Safe\u200B tool\u202E\u2067 text\u{E0049}\u{E0047}\uFEFF.\u00AD"
    {toolset, _} = Naming.build([{"files", [tool("files", "t", dirty)]}])

    for json <- encoded_outputs(toolset) do
      decoded = JSON.decode!(json)

      descriptions =
        for entry <- decoded, do: entry["description"] || entry["function"]["description"]

      assert descriptions == ["Safe tool text."]
    end
  end

  property "PI-1: sanitized descriptions are valid UTF-8, at most 4 KiB, without invisible characters" do
    invisible = [0x200B, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069, 0xFEFF, 0xE0001, 0xE007F, 0x061C]

    check all(
            chunks <-
              list_of(
                one_of([
                  string(:printable, max_length: 400),
                  member_of(invisible) |> map(&<<&1::utf8>>)
                ]),
                max_length: 40
              )
          ) do
      description = Enum.join(chunks)
      {toolset, _} = Naming.build([{"files", [tool("files", "t", description)]}])
      [%{"description" => clean}] = Anthropic.tools(toolset)

      assert String.valid?(clean)
      assert byte_size(clean) <= 4096
      refute Enum.any?(invisible, &String.contains?(clean, <<&1::utf8>>))
    end
  end
end

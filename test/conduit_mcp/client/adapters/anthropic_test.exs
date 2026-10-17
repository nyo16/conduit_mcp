defmodule ConduitMcp.Client.Adapters.AnthropicTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.Adapters.Anthropic
  alias ConduitMcp.Client.{Error, Naming, Tool, ToolCall, ToolResult}

  @read_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"},
      "limit" => %{"type" => "integer", "minimum" => 1}
    },
    "required" => ["path"]
  }

  defp tool(server_id, raw) do
    {:ok, tool} = Tool.from_wire(server_id, raw)
    tool
  end

  defp toolset do
    {toolset, _} =
      Naming.build([
        {"files",
         [
           tool("files", %{
             "name" => "read",
             "description" => "Read a file.",
             "inputSchema" => @read_schema
           }),
           tool("files", %{"name" => "fs.search", "inputSchema" => %{"type" => "object"}})
         ]},
        {"web",
         [
           tool("web", %{
             "name" => "fetch",
             "description" => "Fetch\u200B a URL.\u202E\u{E0041}",
             "inputSchema" => %{"type" => "object"}
           })
         ]}
      ])

    toolset
  end

  describe "tools/2" do
    test "golden: definitions in toolset order, cache marker on the last" do
      golden = """
      [
        {"name": "files__read", "description": "Read a file.",
         "input_schema": {"type": "object",
                          "properties": {"path": {"type": "string"},
                                         "limit": {"type": "integer", "minimum": 1}},
                          "required": ["path"]}},
        {"name": "files__fs_search", "input_schema": {"type": "object"}},
        {"name": "web__fetch", "description": "Fetch a URL.",
         "input_schema": {"type": "object"},
         "cache_control": {"type": "ephemeral"}}
      ]
      """

      assert Anthropic.tools(toolset(), cache_control: :last) == JSON.decode!(golden)
    end

    test "no cache marker by default; empty toolset gives []" do
      refute Enum.any?(Anthropic.tools(toolset()), &Map.has_key?(&1, "cache_control"))
      {empty, _} = Naming.build([])
      assert Anthropic.tools(empty, cache_control: :last) == []
    end

    test "PI-1: descriptions are capped at 4 KiB on a character boundary" do
      long = String.duplicate("é", 3000)

      {set, _} =
        Naming.build([
          {"a", [tool("a", %{"name" => "t", "description" => long, "inputSchema" => %{}})]}
        ])

      [%{"description" => description}] = Anthropic.tools(set)

      assert byte_size(description) <= 4096
      assert String.valid?(description)
      assert String.ends_with?(description, "…")
    end

    test "rejects an unknown :cache_control" do
      assert_raise ArgumentError, ~r/:cache_control/, fn ->
        Anthropic.tools(toolset(), cache_control: :first)
      end
    end
  end

  describe "tool_calls/2" do
    test "golden: tool_use blocks become ToolCalls; unknown names become is_error results" do
      response =
        JSON.decode!("""
        {"role": "assistant", "stop_reason": "tool_use",
         "content": [
           {"type": "text", "text": "Let me look."},
           {"type": "tool_use", "id": "toolu_01", "name": "files__fs_search", "input": {"q": "x"}},
           {"type": "tool_use", "id": "toolu_02", "name": "files__delete", "input": {}},
           {"type": "tool_use", "id": "toolu_03", "name": "web__fetch", "input": "nope"},
           {"type": "tool_use", "id": "toolu_04", "name": "files__read"}
         ]}
        """)

      {calls, rejected} = Anthropic.tool_calls(response, toolset())

      assert [
               %ToolCall{
                 server_id: "files",
                 name: "fs.search",
                 args: %{"q" => "x"},
                 call_id: "toolu_01",
                 meta: %{}
               },
               %ToolCall{server_id: "files", name: "read", args: %{}, call_id: "toolu_04"}
             ] = calls

      assert rejected ==
               JSON.decode!("""
               [
                 {"type": "tool_result", "tool_use_id": "toolu_02", "is_error": true,
                  "content": [{"type": "text",
                               "text": "Error: unknown tool \\"files__delete\\". Only the tools listed in this request can be called."}]},
                 {"type": "tool_result", "tool_use_id": "toolu_03", "is_error": true,
                  "content": [{"type": "text", "text": "Error: the tool arguments must be a JSON object."}]}
               ]
               """)
    end

    test "accepts a bare block list and ignores non-tool blocks" do
      blocks = [
        %{"type" => "text", "text" => "hi"},
        %{"type" => "tool_use", "id" => "t", "name" => "web__fetch", "input" => %{}}
      ]

      assert {[%ToolCall{server_id: "web", name: "fetch"}], []} =
               Anthropic.tool_calls(blocks, toolset())

      assert Anthropic.tool_calls(%{"content" => []}, toolset()) == {[], []}
    end
  end

  describe "tool_result/3" do
    test "golden: content mapping" do
      {:ok, result} =
        ToolResult.from_wire(
          JSON.decode!("""
          {"content": [
            {"type": "text", "text": "hello"},
            {"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"},
            {"type": "image", "data": "PHN2Zz4=", "mimeType": "image/svg+xml"},
            {"type": "audio", "data": "UklGRg==", "mimeType": "audio/wav"},
            {"type": "resource_link", "uri": "file:///a.txt", "name": "a.txt", "mimeType": "text/plain"},
            {"type": "resource", "resource": {"uri": "file:///b.md", "mimeType": "text/markdown", "text": "# B"}},
            {"type": "resource", "resource": {"uri": "file:///c.jpg", "mimeType": "image/jpeg", "blob": "/9j/"}},
            {"type": "resource", "resource": {"uri": "file:///d.pdf", "mimeType": "application/pdf", "blob": "JVBERi0="}},
            {"type": "hologram"}
          ],
          "structuredContent": {"ignored": true}}
          """)
        )

      golden = """
      {"type": "tool_result", "tool_use_id": "toolu_9", "is_error": false,
       "content": [
         {"type": "text", "text": "hello"},
         {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}},
         {"type": "text", "text": "[image: image/svg+xml, 5 bytes]"},
         {"type": "text", "text": "[audio: audio/wav, 4 bytes]"},
         {"type": "text", "text": "[resource] a.txt <file:///a.txt> (text/plain)"},
         {"type": "text", "text": "[resource: file:///b.md (text/markdown)]\\n# B"},
         {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "/9j/"}},
         {"type": "text", "text": "[resource: file:///d.pdf (application/pdf), 5 bytes]"},
         {"type": "text", "text": "[unsupported content: hologram]"}
       ]}
      """

      assert Anthropic.tool_result("toolu_9", result) == JSON.decode!(golden)
    end

    test "isError results and client errors set is_error" do
      {:ok, failed} =
        ToolResult.from_wire(%{
          "content" => [%{"type" => "text", "text" => "boom"}],
          "isError" => true
        })

      assert Anthropic.tool_result("t", failed) == %{
               "type" => "tool_result",
               "tool_use_id" => "t",
               "is_error" => true,
               "content" => [%{"type" => "text", "text" => "boom"}]
             }

      assert Anthropic.tool_result("t", Error.new(:denied, :no_rule)) == %{
               "type" => "tool_result",
               "tool_use_id" => "t",
               "is_error" => true,
               "content" => [%{"type" => "text", "text" => "MCP client error (denied): no_rule"}]
             }
    end

    test "structuredContent is used when content is empty, or as asked" do
      {:ok, only_structured} = ToolResult.from_wire(%{"structuredContent" => %{"n" => 1}})

      {:ok, both} =
        ToolResult.from_wire(%{
          "content" => [%{"type" => "text", "text" => "one"}],
          "structuredContent" => %{"n" => 1}
        })

      text = fn block -> Enum.map(block["content"], & &1["text"]) end

      assert text.(Anthropic.tool_result("t", only_structured)) == [~s({"n":1})]
      assert text.(Anthropic.tool_result("t", both)) == ["one"]
      assert text.(Anthropic.tool_result("t", both, structured: :prefer)) == [~s({"n":1})]
      assert text.(Anthropic.tool_result("t", both, structured: :append)) == ["one", ~s({"n":1})]
      assert text.(Anthropic.tool_result("t", only_structured, structured: :ignore)) == []
    end
  end
end

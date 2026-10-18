defmodule ConduitMcp.Client.Adapters.GeminiTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.Adapters.Gemini
  alias ConduitMcp.Client.{Error, Naming, Tool, ToolCall, ToolResult, ToolSet}

  @read_schema %{
    "type" => "object",
    "properties" => %{"path" => %{"type" => "string"}},
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
             "description" => "Read\u2066 a file.",
             "inputSchema" => @read_schema
           }),
           tool("files", %{"name" => "fs.list", "inputSchema" => %{"type" => "object"}})
         ]}
      ])

    toolset
  end

  test "golden: function_declarations/1 sends the schema as parametersJsonSchema" do
    golden = """
    [
      {"name": "files__read", "description": "Read a file.",
       "parametersJsonSchema": {"type": "object",
                                "properties": {"path": {"type": "string"}},
                                "required": ["path"]}},
      {"name": "files__fs_list", "description": "",
       "parametersJsonSchema": {"type": "object"}}
    ]
    """

    assert Gemini.function_declarations(toolset()) == JSON.decode!(golden)
  end

  describe "function_calls/2" do
    test "golden: functionCall parts become ToolCalls; unknown names get an error response" do
      response =
        JSON.decode!("""
        {"candidates": [{"content": {"role": "model", "parts": [
          {"text": "Checking."},
          {"functionCall": {"id": "fc-1", "name": "files__read", "args": {"path": "/a"}}},
          {"functionCall": {"name": "files__fs_list"}},
          {"functionCall": {"id": "fc-3", "name": "files__rm", "args": {}}},
          {"functionCall": {"name": "files__read", "args": [1]}}
        ]}}]}
        """)

      {calls, rejected} = Gemini.function_calls(response, toolset())

      assert [
               %ToolCall{
                 server_id: "files",
                 name: "read",
                 args: %{"path" => "/a"},
                 call_id: "fc-1"
               },
               %ToolCall{server_id: "files", name: "fs.list", args: %{}, call_id: nil}
             ] = calls

      assert rejected ==
               JSON.decode!("""
               [
                 {"functionResponse": {"id": "fc-3", "name": "files__rm",
                  "response": {"error": "Error: unknown tool \\"files__rm\\". Only the tools listed in this request can be called."}}},
                 {"functionResponse": {"name": "files__read",
                  "response": {"error": "Error: the tool arguments must be a JSON object."}}}
               ]
               """)
    end

    test "accepts a Content or a part list; no candidates gives nothing" do
      part = %{"functionCall" => %{"name" => "files__read", "args" => %{"path" => "/"}}}

      assert {[%ToolCall{name: "read"}], []} =
               Gemini.function_calls(%{"parts" => [part]}, toolset())

      assert {[%ToolCall{name: "read"}], []} = Gemini.function_calls([part], toolset())
      assert Gemini.function_calls(%{"candidates" => []}, toolset()) == {[], []}
    end
  end

  describe "function_response/3" do
    test "golden: structuredContent is the output; else text with media placeholders" do
      {:ok, structured} =
        ToolResult.from_wire(%{
          "content" => [%{"type" => "text", "text" => ~s({"n":1})}],
          "structuredContent" => %{"n" => 1}
        })

      {:ok, media} =
        ToolResult.from_wire(%{
          "content" => [
            %{"type" => "text", "text" => "chart:"},
            %{"type" => "image", "data" => "iVBORw0KGgo=", "mimeType" => "image/png"}
          ]
        })

      assert Gemini.function_response("files__read", structured, id: "fc-1") ==
               JSON.decode!("""
               {"functionResponse": {"id": "fc-1", "name": "files__read",
                                     "response": {"output": {"n": 1}}}}
               """)

      assert Gemini.function_response("files__read", media) ==
               JSON.decode!("""
               {"functionResponse": {"name": "files__read",
                                     "response": {"output": "chart:\\n\\n[image: image/png, 8 bytes]"}}}
               """)

      assert Gemini.function_response("files__read", structured, structured: :ignore) ==
               %{
                 "functionResponse" => %{
                   "name" => "files__read",
                   "response" => %{"output" => ~s({"n":1})}
                 }
               }
    end

    test "errors go under response.error" do
      {:ok, failed} =
        ToolResult.from_wire(%{
          "content" => [%{"type" => "text", "text" => "boom"}],
          "structuredContent" => %{"code" => 7},
          "isError" => true
        })

      assert Gemini.function_response("t", failed) ==
               %{"functionResponse" => %{"name" => "t", "response" => %{"error" => "boom"}}}

      assert Gemini.function_response("t", Error.new(:unavailable)) ==
               %{
                 "functionResponse" => %{
                   "name" => "t",
                   "response" => %{"error" => "MCP client error (unavailable)"}
                 }
               }
    end
  end

  test "exposed names round-trip through ToolSet.exposed_name/3" do
    {[call], []} =
      Gemini.function_calls([%{"functionCall" => %{"name" => "files__fs_list"}}], toolset())

    assert ToolSet.exposed_name(toolset(), call.server_id, call.name) == {:ok, "files__fs_list"}
  end
end

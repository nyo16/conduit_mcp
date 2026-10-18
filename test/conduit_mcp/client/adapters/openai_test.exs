defmodule ConduitMcp.Client.Adapters.OpenAITest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.Adapters.OpenAI
  alias ConduitMcp.Client.{Error, Naming, Tool, ToolCall, ToolResult}

  doctest ConduitMcp.Client.Adapters.OpenAI

  @read_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"},
      "limit" => %{"type" => "integer", "minimum" => 1}
    },
    "required" => ["path"]
  }

  @search_schema %{
    "type" => "object",
    "properties" => %{"q" => %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}},
    "required" => ["q"]
  }

  @fetch_schema %{
    "type" => "object",
    "properties" => %{"url" => %{"type" => "string", "format" => "uri"}},
    "required" => ["url"]
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
           tool("files", %{"name" => "fs.search", "inputSchema" => @search_schema})
         ]},
        {"web",
         [
           tool("web", %{
             "name" => "fetch",
             "description" => "Fetch\u200B a URL.",
             "inputSchema" => @fetch_schema
           })
         ]}
      ])

    toolset
  end

  @strict_read """
  {"type": "object",
   "properties": {"path": {"type": "string"},
                  "limit": {"type": ["integer", "null"], "minimum": 1}},
   "required": ["limit", "path"],
   "additionalProperties": false}
  """

  @strict_fetch """
  {"type": "object", "properties": {"url": {"type": "string"}},
   "required": ["url"], "additionalProperties": false}
  """

  describe "tools/2" do
    test "golden (chat, strict: :auto): convertible tools strict, the rest fall back" do
      golden = """
      [
        {"type": "function",
         "function": {"name": "files__read", "description": "Read a file.",
                      "parameters": #{@strict_read}, "strict": true}},
        {"type": "function",
         "function": {"name": "files__fs_search", "parameters": #{JSON.encode!(@search_schema)},
                      "strict": false}},
        {"type": "function",
         "function": {"name": "web__fetch", "description": "Fetch a URL.",
                      "parameters": #{@strict_fetch}, "strict": true}}
      ]
      """

      {tools, report} = OpenAI.tools(toolset(), api: :chat)

      assert tools == JSON.decode!(golden)

      assert report == %{
               null_paths: %{"files__read" => [["limit"]], "web__fetch" => []},
               fallbacks: [{"files__fs_search", {:unsupported, ["properties", "q"], "oneOf"}}],
               excluded: []
             }
    end

    test "golden (responses, strict: true): flat definitions, non-convertible tools excluded" do
      golden = """
      [
        {"type": "function", "name": "files__read", "description": "Read a file.",
         "parameters": #{@strict_read}, "strict": true},
        {"type": "function", "name": "web__fetch", "description": "Fetch a URL.",
         "parameters": #{@strict_fetch}, "strict": true}
      ]
      """

      {tools, report} = OpenAI.tools(toolset(), api: :responses, strict: true)

      assert tools == JSON.decode!(golden)

      assert report.excluded == [
               {"files__fs_search", {:unsupported, ["properties", "q"], "oneOf"}}
             ]

      assert report.fallbacks == []
    end

    test "strict: false sends every schema unchanged with an explicit \"strict\": false" do
      {tools, report} = OpenAI.tools(toolset(), api: :responses, strict: false)

      assert Enum.map(tools, &{&1["name"], &1["parameters"], &1["strict"]}) == [
               {"files__read", @read_schema, false},
               {"files__fs_search", @search_schema, false},
               {"web__fetch", @fetch_schema, false}
             ]

      assert report == %{null_paths: %{}, fallbacks: [], excluded: []}
    end

    test "options are validated" do
      assert_raise ArgumentError, ~r/:api option is required/, fn ->
        OpenAI.tools(toolset(), [])
      end

      assert_raise ArgumentError, ~r/:api must be/, fn ->
        OpenAI.tools(toolset(), api: :legacy)
      end

      assert_raise ArgumentError, ~r/:strict must be/, fn ->
        OpenAI.tools(toolset(), api: :chat, strict: :maybe)
      end
    end
  end

  describe "tool_calls/3" do
    test "golden (chat completion): decodes arguments and strips strict nulls" do
      {_tools, report} = OpenAI.tools(toolset(), api: :chat)

      completion =
        JSON.decode!("""
        {"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [
          {"id": "call_1", "type": "function",
           "function": {"name": "files__read", "arguments": "{\\"path\\": \\"/a\\", \\"limit\\": null}"}},
          {"id": "call_2", "type": "function",
           "function": {"name": "files__rm", "arguments": "{}"}},
          {"id": "call_3", "type": "function",
           "function": {"name": "web__fetch", "arguments": "{not json"}},
          {"id": "call_4", "type": "function",
           "function": {"name": "files__fs_search", "arguments": ""}}
        ]}}]}
        """)

      {calls, rejected} = OpenAI.tool_calls(completion, toolset(), report.null_paths)

      assert [
               %ToolCall{
                 server_id: "files",
                 name: "read",
                 args: %{"path" => "/a"},
                 call_id: "call_1"
               },
               %ToolCall{server_id: "files", name: "fs.search", args: %{}, call_id: "call_4"}
             ] = calls

      assert rejected ==
               JSON.decode!("""
               [
                 {"role": "tool", "tool_call_id": "call_2",
                  "content": "Error: unknown tool \\"files__rm\\". Only the tools listed in this request can be called."},
                 {"role": "tool", "tool_call_id": "call_3",
                  "content": "Error: the tool arguments must be a JSON object."}
               ]
               """)
    end

    test "golden (responses): function_call items, other items ignored" do
      {_tools, report} = OpenAI.tools(toolset(), api: :responses)

      response =
        JSON.decode!("""
        {"output": [
          {"type": "reasoning", "id": "rs_1", "summary": []},
          {"type": "function_call", "id": "fc_1", "call_id": "call_a", "name": "files__read",
           "arguments": "{\\"path\\": \\"/b\\", \\"limit\\": 5}"},
          {"type": "function_call", "id": "fc_2", "call_id": "call_b", "name": "nope", "arguments": "{}"},
          {"type": "message", "role": "assistant", "content": []}
        ]}
        """)

      {calls, rejected} = OpenAI.tool_calls(response, toolset(), report.null_paths)

      assert [%ToolCall{name: "read", args: %{"path" => "/b", "limit" => 5}, call_id: "call_a"}] =
               calls

      assert [
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_b",
                 "output" => "Error: unknown tool \"nope\"." <> _
               }
             ] = rejected
    end

    test "without null paths, nulls are kept" do
      items = [
        %{
          "type" => "function_call",
          "call_id" => "c",
          "name" => "files__read",
          "arguments" => ~s({"path":"/a","limit":null})
        }
      ]

      assert {[%ToolCall{args: %{"path" => "/a", "limit" => nil}}], []} =
               OpenAI.tool_calls(items, toolset())
    end

    test "a message without tool calls yields nothing" do
      assert OpenAI.tool_calls(%{"role" => "assistant", "content" => "hi"}, toolset()) == {[], []}
      assert OpenAI.tool_calls(%{"choices" => []}, toolset()) == {[], []}
    end
  end

  describe "tool_output/3" do
    setup do
      {:ok, result} =
        ToolResult.from_wire(%{
          "content" => [
            %{"type" => "text", "text" => "see image"},
            %{"type" => "image", "data" => "iVBORw0KGgo=", "mimeType" => "image/png"},
            %{"type" => "audio", "data" => "UklGRg==", "mimeType" => "audio/wav"}
          ]
        })

      %{result: result}
    end

    test "golden (chat): text only, media as placeholders", %{result: result} do
      assert OpenAI.tool_output("call_1", result, api: :chat) ==
               JSON.decode!("""
               {"role": "tool", "tool_call_id": "call_1",
                "content": "see image\\n\\n[image: image/png, 8 bytes]\\n\\n[audio: audio/wav, 4 bytes]"}
               """)
    end

    test "golden (responses): images become input_image items", %{result: result} do
      assert OpenAI.tool_output("call_1", result, api: :responses) ==
               JSON.decode!("""
               {"type": "function_call_output", "call_id": "call_1",
                "output": [
                  {"type": "input_text", "text": "see image"},
                  {"type": "input_image", "image_url": "data:image/png;base64,iVBORw0KGgo="},
                  {"type": "input_text", "text": "[audio: audio/wav, 4 bytes]"}
                ]}
               """)
    end

    test "text-only responses output is a string; errors are prefixed" do
      {:ok, failed} =
        ToolResult.from_wire(%{
          "content" => [%{"type" => "text", "text" => "boom"}],
          "isError" => true
        })

      assert OpenAI.tool_output("c", failed, api: :responses) ==
               %{"type" => "function_call_output", "call_id" => "c", "output" => "Error: boom"}

      assert OpenAI.tool_output("c", failed, api: :chat, error_prefix: "TOOL FAILED: ") ==
               %{"role" => "tool", "tool_call_id" => "c", "content" => "TOOL FAILED: boom"}

      assert OpenAI.tool_output("c", Error.new(:timeout, :deadline), api: :chat)["content"] ==
               "Error: MCP client error (timeout): deadline"
    end

    test "an error with an image keeps the prefix as the first item" do
      {:ok, failed} =
        ToolResult.from_wire(%{
          "content" => [%{"type" => "image", "data" => "AA==", "mimeType" => "image/gif"}],
          "isError" => true
        })

      assert %{
               "output" => [
                 %{"type" => "input_text", "text" => "Error: "},
                 %{"type" => "input_image"}
               ]
             } =
               OpenAI.tool_output("c", failed, api: :responses)
    end
  end
end

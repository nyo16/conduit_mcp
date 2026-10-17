defmodule ConduitMcp.Client.StructsTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.{
    DiscoverResult,
    Error,
    Prompt,
    Resource,
    Secret,
    ServerInfo,
    Tool,
    ToolCall,
    ToolResult
  }

  alias ConduitMcp.Test.McpSchema

  doctest ConduitMcp.Client.Error
  doctest ConduitMcp.Client.ServerInfo
  doctest ConduitMcp.Client.Tool
  doctest ConduitMcp.Client.ToolCall
  doctest ConduitMcp.Client.ToolResult
  doctest ConduitMcp.Client.Resource
  doctest ConduitMcp.Client.Prompt
  doctest ConduitMcp.Client.DiscoverResult

  @modern "2026-07-28"

  describe "Error" do
    test "kinds/0 is the closed set and new/3 rejects anything else" do
      assert length(Error.kinds()) == 17
      assert :mrtr_round_limit in Error.kinds()

      assert_raise ArgumentError, ~r/unknown ConduitMcp.Client.Error kind/, fn ->
        Error.new(:bogus)
      end
    end

    test "is raisable and its message names kind and reason, never data" do
      error = Error.new(:auth, :token_expired, %{"token" => "sk-live-123"})

      assert_raise Error, "MCP client error (auth): token_expired", fn -> raise error end
      refute Exception.message(error) =~ "sk-live-123"
    end

    test "message redacts a Secret inside the reason and truncates long reasons" do
      secret_reason = Error.new(:transport, {:bad_header, Secret.new("sk-live-123")})
      refute Exception.message(secret_reason) =~ "sk-live-123"
      assert Exception.message(secret_reason) =~ "#Secret<redacted>"

      long = Error.new(:protocol, String.duplicate("x", 5_000))
      assert byte_size(Exception.message(long)) < 300
    end

    test "message without a reason" do
      assert Exception.message(Error.new(:closed)) == "MCP client error (closed)"
    end

    test "from_rpc_error keeps the error object in data" do
      object = %{"code" => -32_602, "message" => "bad", "data" => %{"field" => "x"}}

      assert %Error{kind: :protocol, reason: {:jsonrpc, -32_602}, data: ^object} =
               Error.from_rpc_error(object)

      assert %Error{reason: :invalid_error_object} = Error.from_rpc_error("nope")
    end
  end

  describe "Tool" do
    @tool %{
      "name" => "read.file",
      "title" => "Read",
      "description" => "Reads a file",
      "inputSchema" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}},
      "outputSchema" => %{"type" => "object"},
      "annotations" => %{"readOnlyHint" => true, "title" => "Annotated"},
      "execution" => %{"taskSupport" => "optional"},
      "icons" => [%{"src" => "https://x/icon.png"}],
      "_meta" => %{"vendor/x" => 1},
      "x-future-key" => "kept"
    }

    test "lifts fields from a schema-valid definition and keeps the raw map" do
      assert :ok = McpSchema.validate("2025-11-25", "Tool", @tool)

      assert {:ok, tool} = Tool.from_wire("files", @tool, fingerprint: "abc")

      assert %Tool{
               server_id: "files",
               name: "read.file",
               title: "Read",
               description: "Reads a file",
               output_schema: %{"type" => "object"},
               annotations: %{"readOnlyHint" => true},
               execution: %{"taskSupport" => "optional"},
               meta: %{"vendor/x" => 1},
               fingerprint: "abc",
               raw: @tool
             } = tool

      assert tool.input_schema == @tool["inputSchema"]
      assert tool.raw["x-future-key"] == "kept"
    end

    test "display_name follows title > annotations.title > name" do
      {:ok, tool} = Tool.from_wire("s", @tool)
      assert Tool.display_name(tool) == "Read"
      assert Tool.display_name(%{tool | title: nil}) == "Annotated"
      assert Tool.display_name(%{tool | title: nil, annotations: nil}) == "read.file"
    end

    test "wrong-typed optional fields read as nil, missing required fields are rejected" do
      {:ok, tool} = Tool.from_wire("s", %{"name" => "t", "inputSchema" => %{}, "title" => 5})
      assert tool.title == nil
      assert tool.meta == %{}

      assert {:error, %Error{kind: :protocol, reason: :invalid_tool}} =
               Tool.from_wire("s", %{"name" => "t"})

      assert {:error, %Error{reason: :invalid_tool}} =
               Tool.from_wire("s", %{"name" => 1, "inputSchema" => %{}})
    end
  end

  describe "ToolCall" do
    test "args_digest ignores key order and key type, and tracks every value" do
      a = ToolCall.new("s", "t", %{"b" => [1, %{"y" => 2, "x" => 1}], "a" => "v"})
      b = ToolCall.new("s", "t", %{a: "v", b: [1, %{x: 1, y: 2}]})
      c = ToolCall.new("s", "t", %{"a" => "v ", "b" => [1, %{"x" => 1, "y" => 2}]})

      assert a.args_digest == b.args_digest
      refute a.args_digest == c.args_digest
      assert a.args_digest =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "put_args recomputes the digest so a rewrite is detectable" do
      call = ToolCall.new("s", "t", %{"path" => "/tmp/a"}, meta: %{"k" => 1})
      rewritten = ToolCall.put_args(call, %{"path" => "/etc/passwd"})

      refute rewritten.args_digest == call.args_digest
      assert rewritten.meta == %{"k" => 1}
    end

    test "refuses to digest a Secret" do
      assert_raise ArgumentError, fn -> ToolCall.new("s", "t", %{"key" => Secret.new("x")}) end
    end
  end

  describe "ToolResult" do
    test "from_wire on a schema-valid CallToolResult" do
      wire = %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => "hi"}],
        "structuredContent" => %{"n" => 1},
        "isError" => false,
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "s", "version" => "1"}},
        "x-extra" => true
      }

      assert :ok = McpSchema.validate(@modern, "CallToolResult", wire)
      assert {:ok, result} = ToolResult.from_wire(wire)
      assert result.content == wire["content"]
      assert result.structured == %{"n" => 1}
      assert result.is_error == false
      assert result.meta == wire["_meta"]
      assert result.extra == %{"x-extra" => true}
    end

    test "isError true stays an ok result; null and absent mean false" do
      assert {:ok, %ToolResult{is_error: true}} =
               ToolResult.from_wire(%{"content" => [], "isError" => true})

      assert {:ok, %ToolResult{is_error: false, content: []}} =
               ToolResult.from_wire(%{"isError" => nil})
    end

    test "malformed results are protocol errors" do
      for bad <- [%{"content" => "text"}, %{"content" => [], "isError" => "yes"}, [], nil] do
        assert {:error, %Error{kind: :protocol, reason: :invalid_tool_result}} =
                 ToolResult.from_wire(bad)
      end
    end
  end

  describe "Resource and Prompt" do
    test "resource from a schema-valid wire map" do
      wire = %{
        "uri" => "file:///a.md",
        "name" => "a",
        "mimeType" => "text/markdown",
        "size" => 12,
        "annotations" => %{"priority" => 0.5}
      }

      assert :ok = McpSchema.validate(@modern, "Resource", wire)
      assert {:ok, res} = Resource.from_wire("docs", wire)

      assert {res.server_id, res.mime_type, res.size, res.raw} ==
               {"docs", "text/markdown", 12, wire}

      assert {:ok, %Resource{size: nil}} =
               Resource.from_wire("docs", %{"uri" => "u", "name" => "n", "size" => -1})

      assert {:error, %Error{reason: :invalid_resource}} =
               Resource.from_wire("docs", %{"uri" => "u"})
    end

    test "prompt keeps only well-formed arguments" do
      wire = %{
        "name" => "p",
        "arguments" => [%{"name" => "a", "required" => true}, %{"title" => "no name"}, "junk"]
      }

      assert {:ok, prompt} = Prompt.from_wire("s", wire)
      assert prompt.arguments == [%{"name" => "a", "required" => true}]
      assert prompt.raw == wire
      assert {:error, %Error{reason: :invalid_prompt}} = Prompt.from_wire("s", %{})
    end
  end

  describe "DiscoverResult and ServerInfo" do
    @discover %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28", "2025-11-25"],
      "capabilities" => %{"tools" => %{"listChanged" => true}},
      "instructions" => "Be nice",
      "ttlMs" => 30_000,
      "cacheScope" => "public",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => "srv",
          "version" => "2.0",
          "websiteUrl" => "https://example.com",
          "icons" => []
        }
      }
    }

    test "golden: parses a schema-valid DiscoverResult" do
      assert :ok = McpSchema.validate(@modern, "DiscoverResult", @discover)
      assert {:ok, result} = DiscoverResult.from_wire(@discover)

      assert %DiscoverResult{
               supported_versions: ["2026-07-28", "2025-11-25"],
               capabilities: %{"tools" => %{"listChanged" => true}},
               instructions: "Be nice",
               ttl_ms: 30_000,
               cache_scope: :public,
               server_info: %ServerInfo{
                 name: "srv",
                 version: "2.0",
                 website_url: "https://example.com"
               },
               raw: @discover
             } = result
    end

    test "ttlMs absent or negative reads as 0; unknown scope reads as private" do
      base = Map.drop(@discover, ["ttlMs", "cacheScope", "_meta"])

      assert {:ok, %DiscoverResult{ttl_ms: 0, cache_scope: :private, server_info: nil}} =
               DiscoverResult.from_wire(base)

      assert {:ok, %DiscoverResult{ttl_ms: 0, cache_scope: :private}} =
               DiscoverResult.from_wire(
                 Map.merge(base, %{"ttlMs" => -5, "cacheScope" => "shared"})
               )
    end

    test "malformed serverInfo is dropped, not fatal" do
      wire =
        put_in(@discover, ["_meta", "io.modelcontextprotocol/serverInfo"], %{"version" => "1"})

      assert {:ok, %DiscoverResult{server_info: nil}} = DiscoverResult.from_wire(wire)
    end

    test "rejects results that are not a complete DiscoverResult" do
      for bad <- [
            Map.delete(@discover, "supportedVersions"),
            Map.put(@discover, "supportedVersions", [1]),
            Map.delete(@discover, "capabilities"),
            Map.put(@discover, "resultType", "input_required")
          ] do
        assert {:error, %Error{kind: :protocol, reason: :invalid_discover_result}} =
                 DiscoverResult.from_wire(bad)
      end
    end

    test "ServerInfo tolerates a missing version but needs a name" do
      assert {:ok, %ServerInfo{name: "x", version: nil}} = ServerInfo.from_wire(%{"name" => "x"})
      assert {:error, %Error{reason: :invalid_server_info}} = ServerInfo.from_wire(%{})
    end
  end
end

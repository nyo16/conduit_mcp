defmodule ConduitMcp.Client.IntakeTest do
  # Tool intake (PO-4, HT-12): a bad tool is dropped from the listing, never
  # the whole listing, with telemetry and a sanitized warning.
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness
  import ExUnit.CaptureLog

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Fingerprint
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Test.Client.FakeHTTPTransport

  @rejected [:conduit_mcp, :client, :tool, :rejected]

  setup do
    {:ok, name: {__MODULE__, make_ref()}}
  end

  defp tool(name, schema \\ %{"type" => "object"}),
    do: %{"name" => name, "inputSchema" => schema}

  defp header_schema(header) do
    %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => header}}
    }
  end

  defp list(name, conn, tools) do
    task = Task.async(fn -> Client.list_tools(name) end)
    {id, _message, _opts} = expect_request(conn, "tools/list")
    reply(conn, id, %{"tools" => tools})
    Task.await(task)
  end

  @bad_names [
    {"homoglyph", "d\u0435lete_repo"},
    {"zero-width space", "read\u200Bfile"},
    {"right-to-left override", "abc\u202Edef"},
    {"129 characters", String.duplicate("a", 129)},
    {"empty", ""},
    {"space", "read file"}
  ]

  for {label, bad} <- @bad_names do
    test "a #{label} name is excluded with telemetry", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)
      ref = attach(name, [@rejected])

      log =
        capture_log(fn ->
          assert {:ok, %{tools: [%Tool{name: "ok"}]}} =
                   list(name, conn, [tool(unquote(bad)), tool("ok")])
        end)

      assert_receive {@rejected, ^ref, %{count: 1}, %{reason: :invalid_name, tool_name: shown}}
      assert shown == nil or shown =~ ~r/\A[A-Za-z0-9_\-]*\z/
      assert log =~ "excluded a tool"
      refute log =~ unquote(bad) and unquote(bad) != ""
      assert_no_leaks(name, conn)
    end
  end

  test "128 characters of the spec charset are accepted", %{name: name} do
    conn = start_client(name)
    ready_modern(name, conn)
    long = String.duplicate("a.b-c_", 21) <> "ab"
    assert byte_size(long) == 128
    assert {:ok, %{tools: [%Tool{name: ^long}]}} = list(name, conn, [tool(long)])
  end

  test "malformed and duplicate tools are dropped, the rest kept and fingerprinted",
       %{name: name} do
    conn = start_client(name)
    ready_modern(name, conn)
    ref = attach(name, [@rejected])

    capture_log(fn ->
      assert {:ok, %{tools: [%Tool{name: "a"} = a, %Tool{name: "b"}]}} =
               list(name, conn, [
                 tool("a"),
                 %{"name" => "no_schema"},
                 "not a tool",
                 tool("b"),
                 tool("a", %{"type" => "object", "description" => "again"})
               ])

      assert a.fingerprint == Fingerprint.compute(tool("a"))
    end)

    assert_receive {@rejected, ^ref, _, %{reason: :invalid_definition, tool_name: "no_schema"}}
    assert_receive {@rejected, ^ref, _, %{reason: :invalid_name, tool_name: nil}}
    assert_receive {@rejected, ^ref, _, %{reason: :duplicate_name, tool_name: "a"}}
  end

  describe "x-mcp-header (HTTP only)" do
    test "an invalid annotation excludes the tool over HTTP", %{name: name} do
      conn = start_client(name, transport: FakeHTTPTransport)
      ready_modern(name, conn)
      ref = attach(name, [@rejected])

      capture_log(fn ->
        assert {:ok, %{tools: [%Tool{name: "good"}]}} =
                 list(name, conn, [
                   tool("crlf", header_schema("Region\r\nX-Evil: 1")),
                   tool("good", header_schema("Region"))
                 ])
      end)

      assert_receive {@rejected, ^ref, _, %{reason: :invalid_x_mcp_header, tool_name: "crlf"}}
      assert_no_leaks(name, conn)
    end

    test "stdio ignores x-mcp-header", %{name: name} do
      conn = start_client(name)
      ready_modern(name, conn)

      assert {:ok, %{tools: [%Tool{name: "crlf"}]}} =
               list(name, conn, [tool("crlf", header_schema("Region\r\nX-Evil: 1"))])
    end
  end
end

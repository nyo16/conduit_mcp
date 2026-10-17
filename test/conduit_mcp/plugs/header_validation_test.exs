defmodule ConduitMcp.Plugs.HeaderValidationTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ConduitMcp.Ctx
  alias ConduitMcp.Headers
  alias ConduitMcp.Plugs.HeaderValidation
  alias ConduitMcp.Test.McpSchema

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  defmodule ParamServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn) do
      {:ok,
       %{
         "tools" => [
           %{
             "name" => "lookup",
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{
                 "region" => %{"type" => "string", "x-mcp-header" => "Region"},
                 "count" => %{"type" => "integer", "x-mcp-header" => "Count"},
                 "filter" => %{
                   "type" => "object",
                   "properties" => %{
                     "zone" => %{"type" => "string", "x-mcp-header" => "Zone"}
                   }
                 }
               }
             }
           },
           %{
             "name" => "bad",
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{
                 "ratio" => %{"type" => "number", "x-mcp-header" => "Ratio"}
               }
             }
           },
           %{"name" => "héllo", "inputSchema" => %{"type" => "object"}}
         ]
       }}
    end

    @impl true
    def handle_call_tool(_conn, _name, _args), do: {:ok, %{"content" => []}}
  end

  defmodule DynamicServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn) do
      header = :persistent_term.get({__MODULE__, :header}, nil)

      props =
        if header,
          do: %{"region" => %{"type" => "string", "x-mcp-header" => header}},
          else: %{"region" => %{"type" => "string"}}

      {:ok,
       %{
         "tools" => [
           %{"name" => "dyn", "inputSchema" => %{"type" => "object", "properties" => props}}
         ]
       }}
    end

    @impl true
    def handle_call_tool(_conn, _name, _args), do: {:ok, %{"content" => []}}
  end

  defp req(method, params, meta \\ @meta) do
    params = if meta, do: Map.put(params, "_meta", meta), else: params
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp run(request, headers, server \\ ParamServer) do
    conn =
      Enum.reduce(headers, conn(:post, "/", ""), fn {k, v}, c ->
        %{c | req_headers: c.req_headers ++ [{k, v}]}
      end)

    %{conn | body_params: request}
    |> put_private(:server_module, server)
    |> HeaderValidation.call(HeaderValidation.init([]))
  end

  defp std(method, extra \\ []),
    do: [{"mcp-protocol-version", @version}, {"mcp-method", method} | extra]

  defp error!(conn, code) do
    assert conn.halted
    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert %{"code" => ^code, "message" => msg} = body["error"]
    assert is_binary(msg)
    body
  end

  defp mismatch!(conn) do
    body = error!(conn, -32020)
    assert McpSchema.validate(@version, "HeaderMismatchError", body) == :ok
    body
  end

  defp call_req(args, name \\ "lookup"),
    do: req("tools/call", %{"name" => name, "arguments" => args})

  describe "pass-through" do
    test "legacy request passes untouched without headers" do
      conn = run(req("tools/list", %{}, nil), [])
      refute conn.halted
      assert conn.status == nil
    end

    test "era-exempt server/discover without _meta passes without headers" do
      conn = run(req("server/discover", %{}, nil), [])
      refute conn.halted
    end

    test "valid modern tools/call passes and stores modern Ctx" do
      conn =
        run(
          call_req(%{"region" => "eu", "count" => 3}),
          std("tools/call", [
            {"mcp-name", "lookup"},
            {"mcp-param-region", "eu"},
            {"mcp-param-count", "3"}
          ])
        )

      refute conn.halted
      assert %Ctx{era: :modern, version: @version} = Ctx.from_conn(conn)
    end
  end

  describe "MCP-Protocol-Version" do
    test "missing ⇒ -32020" do
      mismatch!(run(req("tools/list", %{}), [{"mcp-method", "tools/list"}]))
    end

    test "duplicated ⇒ -32020" do
      mismatch!(
        run(req("tools/list", %{}), [{"mcp-protocol-version", @version} | std("tools/list")])
      )
    end

    test "mismatch takes precedence over unsupported version" do
      meta = Map.put(@meta, "io.modelcontextprotocol/protocolVersion", "2099-01-01")

      mismatch!(
        run(req("tools/list", %{}, meta), [
          {"mcp-protocol-version", "2098-01-01"},
          {"mcp-method", "tools/list"}
        ])
      )
    end

    test "matching but unsupported ⇒ -32022 with supported/requested" do
      meta = Map.put(@meta, "io.modelcontextprotocol/protocolVersion", "2099-01-01")

      conn =
        run(req("tools/list", %{}, meta), [
          {"mcp-protocol-version", "2099-01-01"},
          {"mcp-method", "tools/list"}
        ])

      body = error!(conn, -32022)
      assert body["error"]["data"]["requested"] == "2099-01-01"
      assert @version in body["error"]["data"]["supported"]
      assert McpSchema.validate(@version, "UnsupportedProtocolVersionError", body) == :ok
    end
  end

  describe "Mcp-Method" do
    test "missing ⇒ -32020" do
      mismatch!(run(req("tools/list", %{}), [{"mcp-protocol-version", @version}]))
    end

    test "mismatched ⇒ -32020" do
      mismatch!(run(req("tools/list", %{}), std("prompts/list")))
    end

    test "duplicated ⇒ -32020" do
      mismatch!(run(req("tools/list", %{}), std("tools/list", [{"mcp-method", "tools/list"}])))
    end
  end

  describe "Mcp-Name" do
    test "not required on tools/list or completion/complete" do
      refute run(req("tools/list", %{}), std("tools/list")).halted

      complete =
        req("completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
          "argument" => %{"name" => "x", "value" => "y"}
        })

      refute run(complete, std("completion/complete")).halted
    end

    test "required on tools/call, prompts/get, resources/read" do
      mismatch!(run(call_req(%{}, "héllo"), std("tools/call")))
      mismatch!(run(req("prompts/get", %{"name" => "greeting"}), std("prompts/get")))
      mismatch!(run(req("resources/read", %{"uri" => "test://r"}), std("resources/read")))
    end

    test "matches params.name / params.uri" do
      refute run(
               req("prompts/get", %{"name" => "greeting"}),
               std("prompts/get", [{"mcp-name", "greeting"}])
             ).halted

      refute run(
               req("resources/read", %{"uri" => "test://r"}),
               std("resources/read", [{"mcp-name", "test://r"}])
             ).halted

      mismatch!(
        run(
          req("prompts/get", %{"name" => "greeting"}),
          std("prompts/get", [{"mcp-name", "other"}])
        )
      )
    end

    test "sentinel-encoded non-ASCII name and uri match" do
      enc = Headers.encode_value("héllo")
      assert String.starts_with?(enc, "=?base64?")
      refute run(call_req(%{}, "héllo"), std("tools/call", [{"mcp-name", enc}])).halted

      uri = "file:///tmp/ünï"

      refute run(
               req("resources/read", %{"uri" => uri}),
               std("resources/read", [{"mcp-name", Headers.encode_value(uri)}])
             ).halted
    end

    test "malformed sentinel ⇒ -32020" do
      mismatch!(run(call_req(%{}, "héllo"), std("tools/call", [{"mcp-name", "=?base64?!!!?="}])))
    end

    test "duplicated ⇒ -32020" do
      mismatch!(
        run(
          req("prompts/get", %{"name" => "greeting"}),
          std("prompts/get", [{"mcp-name", "greeting"}, {"mcp-name", "greeting"}])
        )
      )
    end
  end

  describe "Mcp-Param-*" do
    defp lookup(args, extra),
      do: run(call_req(args), std("tools/call", [{"mcp-name", "lookup"} | extra]))

    test "argument present without header ⇒ -32020" do
      mismatch!(lookup(%{"region" => "eu"}, []))
    end

    test "header present with absent or null argument ⇒ -32020" do
      mismatch!(lookup(%{}, [{"mcp-param-region", "eu"}]))
      mismatch!(lookup(%{"region" => nil}, [{"mcp-param-region", "eu"}]))
    end

    test "null argument with no header passes" do
      refute lookup(%{"region" => nil}, []).halted
    end

    test "integer compares numerically: header 42 vs body 42.0" do
      refute lookup(%{"count" => 42.0}, [{"mcp-param-count", "42"}]).halted
      refute lookup(%{"count" => 42}, [{"mcp-param-count", "42"}]).halted
    end

    test "value mismatch ⇒ -32020" do
      mismatch!(lookup(%{"region" => "eu"}, [{"mcp-param-region", "us"}]))
      mismatch!(lookup(%{"count" => 42}, [{"mcp-param-count", "43"}]))
    end

    test "duplicated param header ⇒ -32020" do
      mismatch!(
        lookup(%{"region" => "eu"}, [{"mcp-param-region", "eu"}, {"mcp-param-region", "eu"}])
      )
    end

    test "nested annotated property is enforced" do
      mismatch!(lookup(%{"filter" => %{"zone" => "z1"}}, []))
      refute lookup(%{"filter" => %{"zone" => "z1"}}, [{"mcp-param-zone", "z1"}]).halted
    end

    test "sentinel-encoded non-ASCII param value matches" do
      refute lookup(%{"region" => "zürich"}, [
               {"mcp-param-region", Headers.encode_value("zürich")}
             ]).halted
    end

    test "tool with invalid annotation is ignored" do
      refute run(
               call_req(%{"ratio" => 1.5}, "bad"),
               std("tools/call", [{"mcp-name", "bad"}])
             ).halted
    end
  end

  describe "invalidate/1" do
    setup do
      on_exit(fn ->
        :persistent_term.erase({DynamicServer, :header})
        HeaderValidation.invalidate(DynamicServer)
      end)
    end

    test "a changed tool list takes effect after invalidate" do
      HeaderValidation.invalidate(DynamicServer)
      request = call_req(%{"region" => "eu"}, "dyn")
      hdrs = std("tools/call", [{"mcp-name", "dyn"}])

      refute run(request, hdrs, DynamicServer).halted

      :persistent_term.put({DynamicServer, :header}, "Region")
      # cached: still no requirement
      refute run(request, hdrs, DynamicServer).halted

      HeaderValidation.invalidate(DynamicServer)
      mismatch!(run(request, hdrs, DynamicServer))
      refute run(request, hdrs ++ [{"mcp-param-region", "eu"}], DynamicServer).halted
    end
  end

  describe "SV-14 no value echo" do
    test "error messages never contain header or body values" do
      conns = [
        lookup(%{"region" => "SECRETBODY"}, [{"mcp-param-region", "SECRETVALUE"}]),
        run(
          req("prompts/get", %{"name" => "SECRETBODY"}),
          std("prompts/get", [{"mcp-name", "SECRETVALUE"}])
        ),
        run(req("tools/list", %{}), std("SECRETVALUE")),
        run(req("tools/list", %{}), [
          {"mcp-protocol-version", "SECRETVALUE"},
          {"mcp-method", "tools/list"}
        ])
      ]

      for conn <- conns do
        assert conn.halted
        refute conn.resp_body =~ "SECRET"
      end
    end
  end

  test "invalid modern _meta (version without clientCapabilities) ⇒ 400 -32602" do
    meta = %{"io.modelcontextprotocol/protocolVersion" => @version}
    error!(run(req("tools/list", %{}, meta), std("tools/list")), -32602)
  end
end

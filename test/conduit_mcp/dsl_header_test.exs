defmodule ConduitMcp.DSLHeaderTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ConduitMcp.Handler
  alias ConduitMcp.Plugs.HeaderValidation

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  defmodule HeaderServer do
    use ConduitMcp.Server

    tool "execute_sql", "Runs SQL in a region" do
      # No description: the keywords must still land in opts.
      param(:region, :string, header: "Region")
      param(:query, :string, "The query", required: true)

      param :options, :object, "Options" do
        field(:shard, :integer, "Shard", header: "Shard")
      end

      handle(fn _conn, params -> text("#{params["region"]}:#{params["query"]}") end)
    end
  end

  defmodule HeaderComponent do
    use ConduitMcp.Component, type: :tool, description: "Looks up a tenant"

    schema do
      field(:tenant, :string, header: "Tenant")
      field(:verbose, :boolean, "Verbose", header: "Verbose")
    end

    @impl true
    def execute(%{tenant: tenant}, _conn), do: text(tenant)
  end

  defp compile_server(body) do
    Code.compile_string("""
    defmodule HeaderServer#{System.unique_integer([:positive])} do
      use ConduitMcp.Server
    #{body}
    end
    """)
  end

  defp compile_component(type, body) do
    Code.compile_string("""
    defmodule HeaderComponent#{System.unique_integer([:positive])} do
      use ConduitMcp.Component, type: #{inspect(type)}, description: "d"

      schema do
    #{body}
      end

      @impl true
      def execute(_params, _conn), do: text("ok")
    end
    """)
  end

  describe "header: in the DSL" do
    test "is published as x-mcp-header through modern tools/list" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => @meta}
      }

      assert %{"result" => %{"tools" => [tool]}} = Handler.handle_request(request, HeaderServer)

      properties = tool["inputSchema"]["properties"]
      assert properties["region"] == %{"type" => "string", "x-mcp-header" => "Region"}
      assert properties["query"] == %{"type" => "string", "description" => "The query"}

      assert properties["options"]["properties"]["shard"] == %{
               "type" => "integer",
               "description" => "Shard",
               "x-mcp-header" => "Shard"
             }

      assert ConduitMcp.Headers.validate_x_mcp_header(tool["inputSchema"]) == :ok
    end

    test "does not change validation: the argument is accepted and passed through" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "execute_sql",
          "arguments" => %{"region" => "eu", "query" => "select 1"}
        }
      }

      assert %{"result" => %{"content" => [%{"text" => "eu:select 1"}]}} =
               Handler.handle_request(request, HeaderServer)
    end

    test "is enforced on modern requests by Plugs.HeaderValidation" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "execute_sql",
          "arguments" => %{"region" => "eu", "query" => "q"},
          "_meta" => @meta
        }
      }

      run = fn headers ->
        Enum.reduce(headers, conn(:post, "/", ""), fn {k, v}, c -> put_req_header(c, k, v) end)
        |> Map.put(:body_params, request)
        |> put_private(:server_module, HeaderServer)
        |> HeaderValidation.call([])
      end

      base = [
        {"mcp-protocol-version", @version},
        {"mcp-method", "tools/call"},
        {"mcp-name", "execute_sql"}
      ]

      assert run.(base).status == 400
      refute run.([{"mcp-param-region", "eu"} | base]).halted
    end

    test "a number param fails the build" do
      assert_raise CompileError,
                   ~r/x-mcp-header "Ratio".*"string", "integer" or "boolean"/s,
                   fn ->
                     compile_server("""
                     tool "t", "d" do
                       param :ratio, :number, "Ratio", header: "Ratio"
                       handle fn _conn, _params -> text("ok") end
                     end
                     """)
                   end
    end

    test "an array item fails the build" do
      assert_raise CompileError, ~r/x-mcp-header "Id".*not statically reachable/s, fn ->
        compile_server("""
        tool "t", "d" do
          param :rows, :array, "Rows" do
            items :object do
              field :id, :string, "Id", header: "Id"
            end
          end

          handle fn _conn, _params -> text("ok") end
        end
        """)
      end
    end

    test "a duplicate name, compared case-insensitively, fails the build" do
      assert_raise CompileError, ~r/duplicate x-mcp-header name/, fn ->
        compile_server("""
        tool "t", "d" do
          param :a, :string, "A", header: "Region"
          param :b, :string, "B", header: "region"
          handle fn _conn, _params -> text("ok") end
        end
        """)
      end
    end

    test "a name that is not an RFC 9110 token fails the build" do
      assert_raise CompileError, ~r/"Bad Name".*not a valid HTTP field-name token/s, fn ->
        compile_server("""
        tool "t", "d" do
          param :a, :string, "A", header: "Bad Name"
          handle fn _conn, _params -> text("ok") end
        end
        """)
      end
    end

    test "a prompt argument cannot carry one" do
      assert_raise CompileError, ~r/header: option is only valid on tool parameters/, fn ->
        compile_server("""
        prompt "p", "d" do
          arg :topic, :string, "Topic", header: "Topic"
          get fn _conn, _args -> [] end
        end
        """)
      end
    end
  end

  describe "header: in a Component" do
    test "is published as x-mcp-header" do
      properties = HeaderComponent.__component_schema__()["inputSchema"]["properties"]

      assert properties["tenant"] == %{"type" => "string", "x-mcp-header" => "Tenant"}
      assert properties["verbose"]["x-mcp-header"] == "Verbose"
    end

    test "a duplicate name fails the build" do
      assert_raise CompileError, ~r/duplicate x-mcp-header name/, fn ->
        compile_component(:tool, """
        field :a, :string, "A", header: "Tenant"
        field :b, :string, "B", header: "TENANT"
        """)
      end
    end

    test "a number field fails the build" do
      assert_raise CompileError, ~r/x-mcp-header "Ratio"/, fn ->
        compile_component(:tool, ~s(field :ratio, :number, "Ratio", header: "Ratio"))
      end
    end

    test "a prompt component cannot carry one" do
      assert_raise CompileError, ~r/header: option is only valid on tool parameters/, fn ->
        compile_component(:prompt, ~s(field :topic, :string, "Topic", header: "Topic"))
      end
    end
  end
end

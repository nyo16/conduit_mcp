defmodule ConduitMcp.CacheHintsTest do
  # async: false — sets the global :cache_ttl_ms / :cache_scope env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.CacheHints
  alias ConduitMcp.Handler
  alias ConduitMcp.Test.McpSchema

  @version "2026-07-28"

  defmodule DslServer do
    use ConduitMcp.Server

    tool "catalog", "Public catalog" do
      cache(ttl_ms: 5_000, scope: :public)
      handle(fn _conn, _params -> text("catalog") end)
    end

    tool "news", "Short-lived and public" do
      cache(ttl_ms: 2_000, scope: :public)
      handle(fn _conn, _params -> text("news") end)
    end

    tool "plain", "No hints" do
      handle(fn _conn, _params -> text("plain") end)
    end

    prompt "greeting", "Public prompt" do
      cache(scope: :public)
      get(fn _conn, _args -> [user("hi")] end)
    end

    resource "doc://public" do
      cache(ttl_ms: 1_000, scope: :public)

      read(fn _conn, _params, _opts ->
        {:ok, %{"contents" => [%{"uri" => "doc://public", "text" => "p"}]}}
      end)
    end

    resource "item://{id}" do
      cache(ttl_ms: 30_000, scope: :public)

      read(fn _conn, %{"id" => id}, _opts ->
        {:ok, %{"contents" => [%{"uri" => "item://" <> id, "text" => id}]}}
      end)
    end
  end

  defmodule ScopedServer do
    use ConduitMcp.Server

    tool "public_one", "Public" do
      cache(ttl_ms: 5_000, scope: :public)
      handle(fn _conn, _params -> text("1") end)
    end

    tool "admin", "Scoped, no cache hint" do
      scope("admin")
      handle(fn _conn, _params -> text("2") end)
    end

    resource "secret://{id}" do
      scope("secrets:read")
      cache(ttl_ms: 10_000)
      read(fn _conn, _params, _opts -> {:ok, %{"contents" => []}} end)
    end
  end

  defmodule CatalogTool do
    use ConduitMcp.Component,
      type: :tool,
      description: "Catalog",
      cache: [ttl_ms: 4_000, scope: :public]

    @impl true
    def execute(_params, _conn), do: text("c")
  end

  defmodule OtherTool do
    use ConduitMcp.Component, type: :tool, description: "Other", cache: [scope: :public]

    @impl true
    def execute(_params, _conn), do: text("o")
  end

  defmodule ThirdTool do
    use ConduitMcp.Component, type: :tool, description: "Third", cache: [ttl_ms: 9_000]

    @impl true
    def execute(_params, _conn), do: text("t")
  end

  defmodule Endpoint do
    use ConduitMcp.Endpoint, name: "cache-test"

    component(OtherTool)
    component(CatalogTool)
    component(ThirdTool)
  end

  defmodule PublicEndpoint do
    use ConduitMcp.Endpoint, name: "cache-test-public"

    component(OtherTool)
    component(CatalogTool)
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:conduit_mcp, :cache_ttl_ms)
      Application.delete_env(:conduit_mcp, :cache_scope)
    end)
  end

  defp modern(server, method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }

    assert {:reply, %{"result" => result}} =
             Handler.dispatch(request, server, conn(:post, "/", ""))

    result
  end

  describe "list results" do
    test "tools/list takes the minimum TTL; one default (private) item makes it private" do
      result = modern(DslServer, "tools/list")

      assert :ok == McpSchema.validate(@version, "ListToolsResult", result)
      assert result["ttlMs"] == 2_000
      assert result["cacheScope"] == "private"
    end

    test "with a public global default the declared public hints win" do
      Application.put_env(:conduit_mcp, :cache_scope, :public)

      assert %{"ttlMs" => 2_000, "cacheScope" => "public"} = modern(DslServer, "tools/list")
    end

    test "SV-9: a scoped item forces private even when every hint and the default are public" do
      Application.put_env(:conduit_mcp, :cache_scope, :public)
      Application.put_env(:conduit_mcp, :cache_ttl_ms, 60_000)

      assert %{"ttlMs" => 5_000, "cacheScope" => "private"} = modern(ScopedServer, "tools/list")

      assert %{"ttlMs" => 10_000, "cacheScope" => "private"} =
               modern(ScopedServer, "resources/templates/list")
    end

    test "prompts/list, resources/list and resources/templates/list use their items' hints" do
      Application.put_env(:conduit_mcp, :cache_ttl_ms, 60_000)

      assert %{"ttlMs" => 60_000, "cacheScope" => "public"} = modern(DslServer, "prompts/list")
      assert %{"ttlMs" => 1_000, "cacheScope" => "public"} = modern(DslServer, "resources/list")

      assert %{"ttlMs" => 30_000, "cacheScope" => "public"} =
               modern(DslServer, "resources/templates/list")
    end

    test "resources/read uses the matched resource's hint (static, then template)" do
      assert %{"ttlMs" => 1_000, "cacheScope" => "public"} =
               modern(DslServer, "resources/read", %{"uri" => "doc://public"})

      assert %{"ttlMs" => 30_000, "cacheScope" => "public"} =
               modern(DslServer, "resources/read", %{"uri" => "item://7"})
    end

    test "server/discover and manual servers use the global default" do
      Application.put_env(:conduit_mcp, :cache_ttl_ms, 7_000)

      assert %{"ttlMs" => 7_000, "cacheScope" => "private"} =
               modern(DslServer, "server/discover")

      assert %{"ttlMs" => 7_000, "cacheScope" => "private"} =
               modern(ConduitMcp.TestServer, "tools/list")
    end

    test "tools/call carries no cache hints" do
      result = modern(DslServer, "tools/call", %{"name" => "catalog"})
      refute Map.has_key?(result, "ttlMs")
    end
  end

  describe "Endpoint" do
    test "aggregates component :cache options" do
      # ThirdTool declares no scope, so the (private) default makes the list private.
      assert %{"ttlMs" => 4_000, "cacheScope" => "private"} = modern(Endpoint, "tools/list")
      # Every component declares public.
      assert %{"ttlMs" => 4_000, "cacheScope" => "public"} = modern(PublicEndpoint, "tools/list")

      Application.put_env(:conduit_mcp, :cache_scope, :public)
      assert %{"cacheScope" => "public"} = modern(Endpoint, "tools/list")

      assert Endpoint.__cache_hints__().tools == %{
               "catalog_tool" => %{ttl_ms: 4_000, scope: :public},
               "other_tool" => %{ttl_ms: nil, scope: :public},
               "third_tool" => %{ttl_ms: 9_000, scope: nil}
             }
    end
  end

  describe "deterministic ordering" do
    test "DSL tools/list is in declaration order, stable across calls" do
      names = fn -> Enum.map(modern(DslServer, "tools/list")["tools"], & &1["name"]) end

      assert names.() == ["catalog", "news", "plain"]
      assert names.() == names.()
    end

    test "Endpoint tools/list is in registration order" do
      assert Enum.map(modern(Endpoint, "tools/list")["tools"], & &1["name"]) ==
               ["other_tool", "catalog_tool", "third_tool"]
    end
  end

  describe "compile-time validation" do
    test "scope + cache scope: :public is a compile error (DSL and Component)" do
      assert_raise CompileError, ~r/SV-9/, fn ->
        defmodule BadDsl do
          use ConduitMcp.Server

          tool "t", "t" do
            scope("admin")
            cache(scope: :public)
            handle(fn _conn, _params -> text("x") end)
          end
        end
      end

      assert_raise CompileError, ~r/SV-9/, fn ->
        defmodule BadComponent do
          use ConduitMcp.Component,
            type: :tool,
            description: "x",
            scope: "admin",
            cache: [scope: :public]

          @impl true
          def execute(_params, _conn), do: text("x")
        end
      end
    end

    test "malformed cache options are compile errors" do
      for opts <- [[ttl_ms: -1], [scope: :shared], [ttl: 5], :public] do
        assert_raise CompileError, ~r/cache expects/, fn ->
          CacheHints.validate!(opts, :subject, nil)
        end
      end
    end

    test "cache/1 outside a declaration is a compile error" do
      assert_raise CompileError, ~r/cache\/1 must be called inside/, fn ->
        defmodule Stray do
          use ConduitMcp.Server
          cache(ttl_ms: 1)
        end
      end
    end
  end

  describe "validate_config!/0" do
    test "accepts valid values and rejects the rest naming the key" do
      Application.put_env(:conduit_mcp, :cache_ttl_ms, 0)
      Application.put_env(:conduit_mcp, :cache_scope, :public)
      assert :ok = CacheHints.validate_config!()

      Application.put_env(:conduit_mcp, :cache_ttl_ms, -5)
      assert_raise ArgumentError, ~r/:cache_ttl_ms/, &CacheHints.validate_config!/0

      Application.put_env(:conduit_mcp, :cache_ttl_ms, 5)
      Application.put_env(:conduit_mcp, :cache_scope, "public")
      assert_raise ArgumentError, ~r/:cache_scope/, &CacheHints.validate_config!/0
    end
  end
end

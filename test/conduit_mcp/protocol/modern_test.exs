defmodule ConduitMcp.Protocol.ModernTest do
  # Not async: two tests set the global :cache_ttl_ms / :cache_scope env.
  use ExUnit.Case, async: false

  alias ConduitMcp.Protocol.Modern

  doctest ConduitMcp.Protocol.Modern

  @server_info %{"name" => "acme", "version" => "1.2.3"}

  @cacheable [
    "server/discover",
    "tools/list",
    "prompts/list",
    "resources/list",
    "resources/templates/list",
    "resources/read"
  ]

  describe "to_response/4 results" do
    test "every result is complete" do
      for method <- @cacheable ++ ["tools/call", "prompts/get", "completion/complete"] do
        assert %{"result" => %{"resultType" => "complete"}} =
                 Modern.to_response(1, method, {:ok, %{}})
      end
    end

    test "only the six cacheable results carry cache hints, defaulting to 60 s private" do
      for method <- @cacheable do
        result = Modern.to_response(1, method, {:ok, %{}})["result"]
        assert result["ttlMs"] == 60_000, method
        assert result["cacheScope"] == "private", method
      end

      for method <- ["tools/call", "prompts/get", "completion/complete"] do
        result = Modern.to_response(1, method, {:ok, %{}})["result"]
        refute Map.has_key?(result, "ttlMs"), method
        refute Map.has_key?(result, "cacheScope"), method
      end
    end

    test "cache hints follow the application env" do
      Application.put_env(:conduit_mcp, :cache_ttl_ms, 5_000)
      Application.put_env(:conduit_mcp, :cache_scope, :public)

      on_exit(fn ->
        Application.delete_env(:conduit_mcp, :cache_ttl_ms)
        Application.delete_env(:conduit_mcp, :cache_scope)
      end)

      assert %{"ttlMs" => 5_000, "cacheScope" => "public"} =
               Modern.to_response(1, "tools/list", {:ok, %{}})["result"]
    end

    test "an invalid configured scope fails loudly instead of emitting junk" do
      Application.put_env(:conduit_mcp, :cache_scope, :shared)
      on_exit(fn -> Application.delete_env(:conduit_mcp, :cache_scope) end)

      assert_raise ArgumentError, ~r/:cache_scope/, fn ->
        Modern.to_response(1, "tools/list", {:ok, %{}})
      end
    end

    test "the :cache option overrides the default for one response" do
      assert %{"ttlMs" => 0, "cacheScope" => "private"} =
               Modern.to_response(1, "resources/read", {:ok, %{}},
                 cache: %{ttl_ms: 0, scope: :private}
               )["result"]
    end

    test "puts serverInfo in _meta and keeps non-reserved keys" do
      result =
        Modern.to_response(
          1,
          "tools/call",
          {:ok, %{"content" => [], "_meta" => %{"progressToken" => "p1"}}},
          server_info: @server_info
        )["result"]

      assert result["_meta"] == %{
               "progressToken" => "p1",
               "io.modelcontextprotocol/serverInfo" => @server_info
             }
    end

    # `Handler.Tools` echoes the request `_meta` into a tools/call result. On
    # the modern path that `_meta` carries the client's per-request metadata,
    # which has no business in a result.
    test "strips the request's per-request metadata from a result _meta" do
      echoed = %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "io.modelcontextprotocol/clientInfo" => %{"name" => "c", "version" => "1"},
        "io.modelcontextprotocol/logLevel" => "info"
      }

      assert %{"result" => result} =
               Modern.to_response(1, "tools/call", {:ok, %{"content" => [], "_meta" => echoed}})

      refute Map.has_key?(result, "_meta")
    end
  end

  describe "to_response/4 errors" do
    test "-32002 is never emitted: it becomes -32602" do
      for method <- ["resources/read", "tools/call"] do
        assert %{"error" => %{"code" => -32602, "message" => "Resource not found: x"}} =
                 Modern.to_response(1, method, {:error, -32002, "Resource not found: x", nil})
      end
    end

    test "other codes and data pass through" do
      data = %{"supported" => ["2026-07-28"], "requested" => "1999-01-01"}

      assert Modern.to_response(7, "tools/list", {:error, -32022, "Unsupported", data}) ==
               %{
                 "jsonrpc" => "2.0",
                 "id" => 7,
                 "error" => %{"code" => -32022, "message" => "Unsupported", "data" => data}
               }
    end
  end

  describe "http_status/1" do
    test "maps the modern metadata errors to 400 and method-not-found to 404" do
      assert Modern.http_status(-32020) == 400
      assert Modern.http_status(-32021) == 400
      assert Modern.http_status(-32022) == 400
      assert Modern.http_status(-32601) == 404
    end

    test "is 200 for results and for method-level errors such as an unknown tool" do
      assert Modern.http_status(%{"result" => %{}}) == 200
      assert Modern.http_status(%{"error" => %{"code" => -32602}}) == 200
      assert Modern.http_status(%{"error" => %{"code" => -32603}}) == 200
      assert Modern.http_status(%{"error" => %{"code" => -32601}}) == 404
    end
  end
end

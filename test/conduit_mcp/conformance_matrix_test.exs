defmodule ConduitMcp.ConformanceMatrixTest do
  # Every routed method (union of both eras' tables) × era × server kind.
  # The method list comes from `Handler.methods/0`: a newly routed method
  # without an entry in `params_for/2` raises, failing the matrix.
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Protocol.Modern

  @version "2026-07-28"

  defmodule DslServer do
    use ConduitMcp.Server, instructions: "Matrix DSL server."

    tool "echo", "Echo back the input" do
      param(:message, :string, "Message", required: true)
      handle(fn _conn, %{"message" => msg} -> text(msg) end)
    end

    resource "test://resource1" do
      description("Static resource")
      mime_type("text/plain")
      read(fn _conn, _params, _opts -> text("Test content") end)
    end

    resource "item://{id}" do
      description("Item by id")
      read(fn _conn, params, _opts -> json(%{id: params["id"]}) end)
    end

    prompt "greeting", "A greeting prompt" do
      arg(:name, :string, "Name")
      get(fn _conn, args -> [user("Hello, #{args["name"] || "World"}!")] end)
    end
  end

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, name: "echo", description: "Echo back the input"

    schema do
      field(:message, :string, "Message", required: true)
    end

    @impl true
    def execute(%{message: msg}, _conn), do: text(msg)
  end

  defmodule StaticResource do
    use ConduitMcp.Component,
      type: :resource,
      uri: "test://resource1",
      description: "Static resource",
      mime_type: "text/plain"

    @impl true
    def execute(_params, _conn),
      do: {:ok, %{"contents" => [%{"uri" => "test://resource1", "text" => "Test content"}]}}
  end

  defmodule GreetingPrompt do
    use ConduitMcp.Component, type: :prompt, name: "greeting", description: "A greeting prompt"

    schema do
      field(:name, :string, "Name")
    end

    @impl true
    def execute(params, _conn) do
      {:ok,
       %{
         "messages" => [
           %{
             "role" => "user",
             "content" => %{"type" => "text", "text" => "Hello, #{params[:name] || "World"}!"}
           }
         ]
       }}
    end
  end

  defmodule EndpointServer do
    use ConduitMcp.Endpoint, name: "Matrix Endpoint", version: "1.0.0"

    component(EchoTool)
    component(StaticResource)
    component(GreetingPrompt)
  end

  @servers [ConduitMcp.TestServer, DslServer, EndpointServer]
  @eras [:legacy, :modern]

  # Valid params for each routed method. `raise` on anything else, so a
  # method added to a routing table without a matrix entry fails here.
  defp params_for("initialize", _ctx),
    do: %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "matrix", "version" => "1.0.0"}
    }

  defp params_for("ping", _ctx), do: %{}
  defp params_for("server/discover", _ctx), do: %{}
  defp params_for("tools/list", _ctx), do: %{}

  defp params_for("tools/call", _ctx),
    do: %{"name" => "echo", "arguments" => %{"message" => "hi"}}

  defp params_for("resources/list", _ctx), do: %{}
  defp params_for("resources/templates/list", _ctx), do: %{}
  defp params_for("resources/read", _ctx), do: %{"uri" => "test://resource1"}
  defp params_for("resources/subscribe", _ctx), do: %{"uri" => "test://resource1"}
  defp params_for("resources/unsubscribe", _ctx), do: %{"uri" => "test://resource1"}
  defp params_for("prompts/list", _ctx), do: %{}
  defp params_for("prompts/get", _ctx), do: %{"name" => "greeting", "arguments" => %{}}

  defp params_for("completion/complete", _ctx),
    do: %{
      "ref" => %{"type" => "ref/prompt", "name" => "greeting"},
      "argument" => %{"name" => "name", "value" => "A"}
    }

  defp params_for("logging/setLevel", _ctx), do: %{"level" => "info"}
  defp params_for("tasks/list", _ctx), do: %{}
  defp params_for("tasks/get", ctx), do: %{"taskId" => new_task(ctx, %{})}
  defp params_for("tasks/cancel", ctx), do: %{"taskId" => new_task(ctx, %{})}

  defp params_for("tasks/result", ctx),
    do: %{
      "taskId" =>
        new_task(ctx, %{
          "status" => "completed",
          "result" => %{"content" => [%{"type" => "text", "text" => "done"}]}
        })
    }

  defp params_for("notifications/initialized", _ctx), do: %{}
  defp params_for("notifications/cancelled", _ctx), do: %{"requestId" => "not-in-flight"}

  defp params_for(method, _ctx),
    do: raise("conformance matrix has no params entry for routed method #{inspect(method)}")

  defp new_task(ctx, updates) do
    id = "matrix-#{inspect(ctx.server)}-#{ctx.era}-#{System.unique_integer([:positive])}"
    {:ok, _} = ConduitMcp.Tasks.create(id)
    if updates != %{}, do: {:ok, _} = ConduitMcp.Tasks.update(id, updates)
    on_exit(fn -> ConduitMcp.Tasks.delete(id) end)
    id
  end

  defp notification?(method), do: String.starts_with?(method, "notifications/")

  defp build(method, era, ctx) do
    params = params_for(method, ctx)

    params =
      case era do
        :legacy ->
          params

        :modern ->
          Map.put(params, "_meta", %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          })
      end

    request = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    if notification?(method), do: request, else: Map.put(request, "id", 1)
  end

  defp subscriptions?(server, :subscribe) do
    Code.ensure_loaded!(server)
    function_exported?(server, :handle_subscribe_resource, 2)
  end

  defp subscriptions?(server, :unsubscribe) do
    Code.ensure_loaded!(server)
    function_exported?(server, :handle_unsubscribe_resource, 2)
  end

  test "the matrix covers both routing tables" do
    all = Handler.methods()
    assert Map.merge(Handler.methods(:legacy), Handler.methods(:modern)) == all
    # Raises for a routed method without a params entry.
    ctx = %{server: ConduitMcp.TestServer, era: :legacy}
    for method <- Map.keys(all), do: params_for(method, ctx)
  end

  for server <- @servers, era <- @eras do
    describe "#{inspect(server)} × #{era}" do
      @server server
      @era era

      test "every routed method answers per its era's table" do
        ctx = %{server: @server, era: @era}

        for method <- Enum.sort(Map.keys(Handler.methods())) do
          request = build(method, @era, ctx)
          reply = Handler.dispatch(request, @server, %Plug.Conn{})
          check(method, @era, @server, request, reply)
        end
      end
    end
  end

  # --- legacy ---------------------------------------------------------------

  defp check(method, :legacy, server, _request, reply) do
    cond do
      notification?(method) ->
        assert reply == :noreply, "#{method} (legacy): expected :noreply, got #{inspect(reply)}"

      method == "server/discover" ->
        # Era-exempt: no `_meta` still yields a modern result.
        assert {:reply, %{"result" => result} = response} = reply
        assert result["resultType"] == "complete"
        assert @version in result["supportedVersions"]
        assert Modern.http_status(response) == 200

      method in ["resources/subscribe", "resources/unsubscribe"] and
          not subscriptions?(server, subscription_kind(method)) ->
        assert {:reply, %{"error" => error}} = reply
        assert error["code"] == -32601
        assert error["message"] == "Resource subscriptions not supported"

      Map.has_key?(Handler.methods(:legacy), method) ->
        assert {:reply, %{"result" => result}} = reply,
               "#{method} (legacy): expected a result, got #{inspect(reply)}"

        refute Map.has_key?(result, "resultType"), "#{method} (legacy) carries resultType"
        refute Map.has_key?(result, "ttlMs")

      true ->
        assert {:reply, %{"error" => %{"code" => -32601}}} = reply
    end
  end

  # --- modern ---------------------------------------------------------------

  defp check(method, :modern, _server, _request, reply) do
    cond do
      notification?(method) ->
        assert reply == :noreply, "#{method} (modern): expected :noreply, got #{inspect(reply)}"

      Map.has_key?(Handler.methods(:modern), method) ->
        assert {:reply, %{"result" => result} = response} = reply,
               "#{method} (modern): expected a result, got #{inspect(reply)}"

        assert result["resultType"] == "complete"
        assert Modern.http_status(response) == 200

      true ->
        assert {:reply, %{"error" => %{"code" => -32601}} = response} = reply,
               "#{method} (modern): expected -32601, got #{inspect(reply)}"

        assert Modern.http_status(response) == 404
    end
  end

  defp subscription_kind("resources/subscribe"), do: :subscribe
  defp subscription_kind("resources/unsubscribe"), do: :unsubscribe

  describe "spot checks" do
    test "legacy-only methods are exactly the ones modern answers with 404" do
      legacy_only = Map.keys(Handler.methods(:legacy)) -- Map.keys(Handler.methods(:modern))
      assert "initialize" in legacy_only
      assert "ping" in legacy_only
      assert "tasks/get" in legacy_only
      refute "tools/call" in legacy_only
    end

    test "modern tools/call actually runs the tool" do
      ctx = %{server: EndpointServer, era: :modern}
      request = build("tools/call", :modern, ctx)

      assert {:reply, %{"result" => result}} =
               Handler.dispatch(request, EndpointServer, %Plug.Conn{})

      assert [%{"type" => "text", "text" => "hi"}] = result["content"]
    end

    test "legacy tasks/result returns the stored task result" do
      ctx = %{server: ConduitMcp.TestServer, era: :legacy}
      request = build("tasks/result", :legacy, ctx)

      assert {:reply, %{"result" => %{"content" => [%{"text" => "done"}]}}} =
               Handler.dispatch(request, ConduitMcp.TestServer, %Plug.Conn{})
    end
  end
end

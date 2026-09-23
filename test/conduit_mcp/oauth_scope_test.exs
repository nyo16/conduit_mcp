defmodule ConduitMcp.OAuthScopeTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler

  # Test server with scoped tools
  defmodule ScopedServer do
    use ConduitMcp.Server

    tool "public_tool", "No scope required" do
      param(:msg, :string, "Message", required: true)

      handle(fn _conn, %{"msg" => msg} ->
        text(msg)
      end)
    end

    tool "read_data", "Requires read scope" do
      scope("data:read")
      param(:id, :string, "ID", required: true)

      handle(fn _conn, %{"id" => id} ->
        text("Data for #{id}")
      end)
    end

    tool "delete_data", "Requires write scope" do
      scope("data:write")
      param(:id, :string, "ID", required: true)

      handle(fn _conn, %{"id" => id} ->
        text("Deleted #{id}")
      end)
    end

    tool "admin_action", "Requires multiple scopes" do
      scope("admin data:write")
      param(:action, :string, "Action", required: true)

      handle(fn _conn, %{"action" => action} ->
        text("Admin: #{action}")
      end)
    end

    resource "secret://config" do
      scope("config:read")
      description("Static scoped resource")

      read(fn _conn, _params, _opts ->
        {:ok, %{"contents" => [%{"uri" => "secret://config", "text" => "top secret"}]}}
      end)
    end

    resource "vault://{id}" do
      scope("vault:read")
      description("Templated scoped resource")

      read(fn _conn, params, _opts ->
        {:ok, %{"contents" => [%{"uri" => "vault://#{params["id"]}", "text" => "sealed"}]}}
      end)
    end

    resource "public://info" do
      description("Unscoped resource")

      read(fn _conn, _params, _opts ->
        {:ok, %{"contents" => [%{"uri" => "public://info", "text" => "public"}]}}
      end)
    end

    prompt "secret_review", "Requires review scope" do
      scope("review:run")
      arg(:code, :string, "Code")

      get(fn _conn, _args ->
        [%{"role" => "user", "content" => %{"type" => "text", "text" => "x"}}]
      end)
    end

    prompt "public_review", "No scope required" do
      arg(:code, :string, "Code")

      get(fn _conn, _args ->
        [%{"role" => "user", "content" => %{"type" => "text", "text" => "y"}}]
      end)
    end
  end

  describe "scope DSL macro" do
    test "__scope_for_tool__ returns scope for scoped tools" do
      assert ScopedServer.__scope_for_tool__("read_data") == "data:read"
      assert ScopedServer.__scope_for_tool__("delete_data") == "data:write"
      assert ScopedServer.__scope_for_tool__("admin_action") == "admin data:write"
    end

    test "__scope_for_tool__ returns nil for unscoped tools" do
      assert ScopedServer.__scope_for_tool__("public_tool") == nil
    end
  end

  describe "scope enforcement in handler" do
    test "unscoped tool works without OAuth scopes" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "public_tool", "arguments" => %{"msg" => "hello"}}
      }

      response = Handler.handle_request(request, ScopedServer)
      assert response["result"]["content"]
    end

    test "scoped tool fails closed on the 2-arg path (no conn, no oauth_scopes)" do
      # handle_request/2 defaults conn to %Plug.Conn{}, whose assigns carry no
      # :oauth_scopes; verify_scope/2 then treats token scopes as [] and a
      # scoped tool is rejected. Pins the secure default for the no-auth path.
      request = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "read_data", "arguments" => %{"id" => "123"}}
      }

      response = Handler.handle_request(request, ScopedServer)
      assert response["error"]["message"] =~ "Insufficient scope"
      assert response["id"] == 7
    end

    test "scoped tool works when scope is present" do
      conn =
        %Plug.Conn{}
        |> Plug.Conn.assign(:oauth_scopes, ["data:read", "data:write"])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "read_data", "arguments" => %{"id" => "123"}}
      }

      response = Handler.handle_request(request, ScopedServer, conn)
      assert response["result"]["content"]
    end

    test "scoped tool rejected when scope missing" do
      conn =
        %Plug.Conn{}
        |> Plug.Conn.assign(:oauth_scopes, ["data:read"])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "delete_data", "arguments" => %{"id" => "123"}}
      }

      response = Handler.handle_request(request, ScopedServer, conn)
      assert response["error"]
      assert response["error"]["message"] =~ "Insufficient scope"
      # Response MUST preserve the original request id, not return null
      assert response["id"] == 1
    end

    test "multi-scope tool requires all scopes" do
      conn =
        %Plug.Conn{}
        |> Plug.Conn.assign(:oauth_scopes, ["data:write"])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "admin_action", "arguments" => %{"action" => "reset"}}
      }

      response = Handler.handle_request(request, ScopedServer, conn)
      assert response["error"]["message"] =~ "Insufficient scope"
    end

    test "multi-scope tool passes when all scopes present" do
      conn =
        %Plug.Conn{}
        |> Plug.Conn.assign(:oauth_scopes, ["admin", "data:write", "data:read"])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "admin_action", "arguments" => %{"action" => "reset"}}
      }

      response = Handler.handle_request(request, ScopedServer, conn)
      assert response["result"]["content"]
    end
  end

  describe "resource scope enforcement" do
    defp read_resource(uri, conn, server \\ ScopedServer) do
      Handler.handle_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 11,
          "method" => "resources/read",
          "params" => %{"uri" => uri}
        },
        server,
        conn
      )
    end

    defp with_scopes(scopes), do: Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, scopes)

    test "__scope_for_resource__ reports declared scopes, including templated URIs" do
      assert ScopedServer.__scope_for_resource__("secret://config") == "config:read"
      assert ScopedServer.__scope_for_resource__("vault://abc") == "vault:read"
      assert ScopedServer.__scope_for_resource__("public://info") == nil
      assert ScopedServer.__scope_for_resource__("unknown://x") == nil
    end

    test "a scoped static resource is denied without the scope" do
      response = read_resource("secret://config", with_scopes(["other"]))
      assert response["error"]["message"] =~ "Insufficient scope"
      assert response["id"] == 11
    end

    test "a scoped static resource is served with the scope" do
      response = read_resource("secret://config", with_scopes(["config:read"]))
      assert response["result"]["contents"]
    end

    test "a scoped templated resource is denied without the scope" do
      response = read_resource("vault://abc", with_scopes([]))
      assert response["error"]["message"] =~ "Insufficient scope"
    end

    test "a scoped templated resource is served with the scope" do
      response = read_resource("vault://abc", with_scopes(["vault:read"]))
      assert response["result"]["contents"]
    end

    test "fails closed with no principal at all" do
      response = read_resource("secret://config", %Plug.Conn{})
      assert response["error"]["message"] =~ "Insufficient scope"
    end

    test "an unscoped resource is unaffected" do
      assert read_resource("public://info", %Plug.Conn{})["result"]["contents"]
    end
  end

  describe "prompt scope enforcement" do
    defp get_prompt(name, conn, server \\ ScopedServer) do
      Handler.handle_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 12,
          "method" => "prompts/get",
          "params" => %{"name" => name, "arguments" => %{"code" => "x"}}
        },
        server,
        conn
      )
    end

    test "__scope_for_prompt__ reports declared scopes" do
      assert ScopedServer.__scope_for_prompt__("secret_review") == "review:run"
      assert ScopedServer.__scope_for_prompt__("public_review") == nil
    end

    test "a scoped prompt is denied without the scope" do
      response = get_prompt("secret_review", with_scopes(["other"]))
      assert response["error"]["message"] =~ "Insufficient scope"
      assert response["id"] == 12
    end

    test "a scoped prompt is served with the scope" do
      assert get_prompt("secret_review", with_scopes(["review:run"]))["result"]
    end

    test "fails closed with no principal at all" do
      response = get_prompt("secret_review", %Plug.Conn{})
      assert response["error"]["message"] =~ "Insufficient scope"
    end

    test "an unscoped prompt is unaffected" do
      assert get_prompt("public_review", %Plug.Conn{})["result"]
    end
  end

  describe "prompt scope enforcement in Endpoint mode" do
    defmodule ScopedPromptComponent do
      @moduledoc false
      use ConduitMcp.Component,
        type: :prompt,
        name: "endpoint_secret_review",
        description: "Requires review scope",
        scope: "review:run"

      schema do
        field(:code, :string, "Code")
      end

      @impl true
      def execute(_args, _conn) do
        {:ok,
         %{"messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "z"}}]}}
      end
    end

    defmodule ScopedPromptEndpoint do
      @moduledoc false
      use ConduitMcp.Endpoint, name: "scoped prompts", version: "1.0.0"
      component(ScopedPromptComponent)
    end

    test "a scoped prompt component is denied without the scope" do
      response =
        get_prompt("endpoint_secret_review", with_scopes(["other"]), ScopedPromptEndpoint)

      assert response["error"]["message"] =~ "Insufficient scope. Required: review:run"
    end

    test "a scoped prompt component is served with the scope" do
      response =
        get_prompt("endpoint_secret_review", with_scopes(["review:run"]), ScopedPromptEndpoint)

      assert [%{"content" => %{"text" => "z"}}] = response["result"]["messages"]
    end
  end

  # The scope lookup must answer for the resource `handle_read_resource/2`
  # actually dispatches to — including an unscoped one. Otherwise an unscoped
  # resource inherits the scope of an overlapping template it never runs
  # through, and a caller is refused a resource that needs no scope at all.
  describe "the resource scope lookup mirrors dispatch" do
    # --- DSL mode ---

    defmodule PublicMeServer do
      @moduledoc false
      use ConduitMcp.Server

      # Declared before the static on purpose: dispatch serves `user://me`
      # from its static clause whatever the declaration order.
      resource "user://{id}" do
        scope("admin")

        read(fn _c, params, _o ->
          {:ok, %{"contents" => [%{"text" => "user #{params["id"]}"}]}}
        end)
      end

      resource "user://me" do
        read(fn _c, _p, _o -> {:ok, %{"contents" => [%{"text" => "me"}]}} end)
      end
    end

    defmodule OpenTemplateFirstServer do
      @moduledoc false
      use ConduitMcp.Server

      # Unscoped and declared first, so dispatch serves every `doc://…` URI
      # from here even though the scoped template below also matches it.
      resource "doc://{id}" do
        read(fn _c, _p, _o -> {:ok, %{"contents" => [%{"text" => "open doc"}]}} end)
      end

      # Also unscoped and first, and its handler returns nothing usable.
      resource "void://{id}" do
        read(fn _c, _p, _o -> nil end)
      end

      resource "{kind}://{id}" do
        scope("admin")
        read(fn _c, _p, _o -> {:ok, %{"contents" => [%{"text" => "any"}]}} end)
      end
    end

    # --- Endpoint mode ---

    defmodule UserTemplateResource do
      @moduledoc false
      use ConduitMcp.Component,
        type: :resource,
        uri: "user://{id}",
        description: "Admin-only user",
        scope: "admin"

      @impl true
      def execute(%{id: id}, _conn), do: {:ok, %{"contents" => [%{"text" => "user #{id}"}]}}
    end

    defmodule UserMeResource do
      @moduledoc false
      use ConduitMcp.Component, type: :resource, uri: "user://me", description: "Public me"

      @impl true
      def execute(_params, _conn), do: {:ok, %{"contents" => [%{"text" => "me"}]}}
    end

    defmodule OpenDocResource do
      @moduledoc false
      use ConduitMcp.Component, type: :resource, uri: "doc://{id}", description: "Open doc"

      @impl true
      def execute(_params, _conn), do: {:ok, %{"contents" => [%{"text" => "open doc"}]}}
    end

    defmodule VoidResource do
      @moduledoc false
      use ConduitMcp.Component, type: :resource, uri: "void://{id}", description: "Void"

      @impl true
      def execute(_params, _conn), do: nil
    end

    defmodule AnyKindResource do
      @moduledoc false
      use ConduitMcp.Component,
        type: :resource,
        uri: "{kind}://{id}",
        description: "Admin-only anything",
        scope: "admin"

      @impl true
      def execute(_params, _conn), do: {:ok, %{"contents" => [%{"text" => "any"}]}}
    end

    defmodule PublicMeEndpoint do
      @moduledoc false
      use ConduitMcp.Endpoint, name: "public me", version: "1.0.0"
      component(UserTemplateResource)
      component(UserMeResource)
    end

    defmodule OpenTemplateFirstEndpoint do
      @moduledoc false
      use ConduitMcp.Endpoint, name: "open template first", version: "1.0.0"
      component(OpenDocResource)
      component(VoidResource)
      component(AnyKindResource)
    end

    defp read_text(server, uri, conn) do
      case read_resource(uri, conn, server) do
        %{"result" => %{"contents" => [%{"text" => text} | _]}} -> {:ok, text}
        %{"error" => %{"message" => message}} -> {:error, message}
      end
    end

    for {mode, me_server, open_first_server} <- [
          {"DSL", PublicMeServer, OpenTemplateFirstServer},
          {"Endpoint", PublicMeEndpoint, OpenTemplateFirstEndpoint}
        ] do
      @me_server me_server
      @open_first_server open_first_server

      test "#{mode}: an unscoped static resource needs no scope beside a scoped template" do
        assert read_text(@me_server, "user://me", %Plug.Conn{}) == {:ok, "me"}
        assert @me_server.__scope_for_resource__("user://me") == nil
      end

      test "#{mode}: the scoped template is still enforced for the URIs it serves" do
        assert {:error, "Insufficient scope. Required: admin"} =
                 read_text(@me_server, "user://42", %Plug.Conn{})

        assert read_text(@me_server, "user://42", with_scopes(["admin"])) == {:ok, "user 42"}
      end

      test "#{mode}: an unscoped template declared first governs the URIs it dispatches" do
        assert read_text(@open_first_server, "doc://1", %Plug.Conn{}) == {:ok, "open doc"}

        assert {:error, "Insufficient scope. Required: admin"} =
                 read_text(@open_first_server, "other://1", %Plug.Conn{})

        assert read_text(@open_first_server, "other://1", with_scopes(["admin"])) ==
                 {:ok, "any"}
      end

      test "#{mode}: a later template never serves a URI an earlier unscoped one matched" do
        # The lookup answers `nil` for `void://…` because the unscoped
        # template matches first. That is only safe while dispatch also stops
        # there, whatever that template's handler returns.
        assert @open_first_server.__scope_for_resource__("void://1") == nil

        response = read_resource("void://1", %Plug.Conn{}, @open_first_server)

        refute response["result"]
        assert %{"message" => message} = response["error"]
        refute message =~ "Insufficient scope"
      end
    end

    test "Endpoint: a template param with no atom at runtime is served and gated by its scope" do
      # Template param names are atomized when the endpoint compiles, so
      # whether a template dispatches cannot depend on the runtime atom
      # table. The name is built at runtime so this test module cannot
      # create the atom itself.
      n = System.unique_integer([:positive])
      param = "never_an_atom_#{n}"

      Code.compile_string("""
      defmodule UnatomizedScoped#{n} do
        use ConduitMcp.Component,
          type: :resource,
          name: "unatomized",
          uri: "atomize://{#{param}}",
          description: "Scoped, and the one dispatch serves",
          scope: "admin"

        @impl true
        def execute(params, _conn),
          do: {:ok, %{"contents" => [%{"text" => inspect(Map.to_list(params))}]}}
      end

      defmodule LaterOpen#{n} do
        use ConduitMcp.Component,
          type: :resource,
          name: "later_open",
          uri: "atomize://{id}",
          description: "Unscoped, and shadowed by the template above"

        @impl true
        def execute(_params, _conn), do: {:ok, %{"contents" => [%{"text" => "open"}]}}
      end

      defmodule AtomizeEndpoint#{n} do
        use ConduitMcp.Endpoint, name: "atomize", version: "1.0.0"
        component(UnatomizedScoped#{n})
        component(LaterOpen#{n})
      end
      """)

      endpoint = Module.concat(["AtomizeEndpoint#{n}"])

      assert read_text(endpoint, "atomize://x", with_scopes(["admin"])) ==
               {:ok, ~s([#{param}: "x"])}

      assert read_text(endpoint, "atomize://x", %Plug.Conn{}) ==
               {:error, "Insufficient scope. Required: admin"}
    end
  end

  describe "scope/1 outside a declaration" do
    test "raises at compile time" do
      # A silently ignored authorization control is worse than an unsupported
      # one: `scope "admin"` at module level used to compile clean and enforce
      # nothing.
      assert_raise CompileError,
                   ~r/must be called inside a tool, resource, or prompt block/,
                   fn ->
                     Code.compile_string("""
                     defmodule StrayScopeServer#{System.unique_integer([:positive])} do
                       use ConduitMcp.Server
                       scope "admin"

                       tool "t", "d" do
                         handle(fn _conn, _params -> text("ok") end)
                       end
                     end
                     """)
                   end
    end
  end

  describe "a scoped resource with no read handler" do
    defmodule DanglingScopeServer do
      @moduledoc false
      use ConduitMcp.Server

      # Declared first, scoped, and *not* readable — so it contributes no
      # dispatch clause. It used to contribute a scope-scan entry anyway, and
      # its template overlaps the readable one below, so the scan stopped here
      # and enforced "dangling:scope" while handle_read_resource/2 ran the
      # other resource's handler.
      resource "vault2://{id}" do
        scope("dangling:scope")
        description("Declared, scoped, and deliberately not readable")
      end

      resource "vault2://{key}" do
        scope("real:scope")
        description("The one that actually dispatches")

        read(fn _conn, params, _opts ->
          {:ok, %{"contents" => [%{"uri" => "vault2://#{params["key"]}", "text" => "ok"}]}}
        end)
      end
    end

    test "the scope enforced is the one whose handler actually runs" do
      assert DanglingScopeServer.__scope_for_resource__("vault2://a") == "real:scope"
    end

    test "the readable resource is still reachable with its own scope" do
      conn = Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["real:scope"])

      assert {:ok, _result} = DanglingScopeServer.handle_read_resource(conn, "vault2://a")
    end
  end

  # Regression tests for defects found reviewing the S-H1 fix itself.
  describe "overlapping templated resources" do
    defmodule OverlapServer do
      @moduledoc false
      use ConduitMcp.Server

      # Declared first, so `handle_read_resource/2` dispatches this one for
      # "admin://secret" — the scope lookup must agree.
      resource "admin://{id}" do
        scope("admin:read")

        read(fn _c, _p, _o -> {:ok, %{"contents" => [%{"text" => "admin"}]}} end)
      end

      resource "{kind}://{id}" do
        scope("public:read")

        read(fn _c, _p, _o -> {:ok, %{"contents" => [%{"text" => "public"}]}} end)
      end
    end

    test "the scope scan agrees with dispatch order" do
      # A prepending reduce silently reversed the scoped-template list, so the
      # weaker template's scope was enforced while the stronger template's
      # handler ran.
      assert OverlapServer.__scope_for_resource__("admin://secret") == "admin:read"
    end

    test "the weaker scope alone does not unlock the stronger handler" do
      conn = Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["public:read"])

      response =
        Handler.handle_request(
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "resources/read",
            "params" => %{"uri" => "admin://secret"}
          },
          OverlapServer,
          conn
        )

      assert response["error"]["message"] =~ "Insufficient scope"
    end
  end

  describe "scope value validation" do
    test "an empty scope fails the build rather than authorizing everyone" do
      # `String.split("", " ", trim: true)` is [], and `Enum.all?([], _)` is
      # true — a control in the source and not at runtime.
      assert_raise CompileError, ~r/must name at least one scope/, fn ->
        Code.compile_string("""
        defmodule EmptyScopeServer#{System.unique_integer([:positive])} do
          use ConduitMcp.Server

          tool "t", "d" do
            scope ""
            handle(fn _conn, _params -> text("ok") end)
          end
        end
        """)
      end
    end

    test "a non-binary scope fails the build" do
      assert_raise CompileError, ~r/must be a space-separated string/, fn ->
        Code.compile_string("""
        defmodule AtomScopeServer#{System.unique_integer([:positive])} do
          use ConduitMcp.Server

          tool "t", "d" do
            scope :admin
            handle(fn _conn, _params -> text("ok") end)
          end
        end
        """)
      end
    end
  end

  describe "scope enforcement on adjacent resource surfaces" do
    defmodule SubscribableServer do
      @moduledoc false
      use ConduitMcp.Server

      resource "vault://{id}" do
        scope("vault:read")

        read(fn _c, _p, _o -> {:ok, %{"contents" => []}} end)
      end

      @impl true
      def handle_subscribe_resource(_conn, uri), do: {:ok, %{"subscribed" => uri}}

      @impl true
      def handle_unsubscribe_resource(_conn, uri), do: {:ok, %{"unsubscribed" => uri}}

      @impl true
      def handle_complete(_conn, _ref, _argument) do
        {:ok, %{"completion" => %{"values" => ["secret-1"], "total" => 1, "hasMore" => false}}}
      end
    end

    setup do
      ConduitMcp.ServerMeta.clear(SubscribableServer)
      :ok
    end

    defp request(method, params, conn) do
      Handler.handle_request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        SubscribableServer,
        conn
      )
    end

    test "resources/subscribe requires the resource's scope" do
      # Subscribing delivers the resource's change notifications, so it is the
      # same read surface.
      denied = request("resources/subscribe", %{"uri" => "vault://a"}, %Plug.Conn{})
      assert denied["error"]["message"] =~ "Insufficient scope"

      allowed =
        request(
          "resources/subscribe",
          %{"uri" => "vault://a"},
          Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["vault:read"])
        )

      assert allowed["result"]["subscribed"] == "vault://a"
    end

    test "resources/unsubscribe requires the resource's scope" do
      denied = request("resources/unsubscribe", %{"uri" => "vault://a"}, %Plug.Conn{})
      assert denied["error"]["message"] =~ "Insufficient scope"
    end

    test "completion/complete requires the referenced resource's scope" do
      params = %{
        "ref" => %{"type" => "ref/resource", "uri" => "vault://a"},
        "argument" => %{"name" => "id", "value" => "sec"}
      }

      denied = request("completion/complete", params, %Plug.Conn{})
      assert denied["error"]["message"] =~ "Insufficient scope"

      allowed =
        request(
          "completion/complete",
          params,
          Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["vault:read"])
        )

      assert allowed["result"]["completion"]["values"] == ["secret-1"]
    end

    test "completion/complete still validates the ref shape first" do
      denied = request("completion/complete", %{"ref" => %{}}, %Plug.Conn{})
      assert denied["error"]["code"] == ConduitMcp.Errors.invalid_params()
      assert denied["error"]["message"] =~ "missing type"
    end

    test "an unscoped resource is unaffected on all three surfaces" do
      for {method, params} <- [
            {"resources/subscribe", %{"uri" => "open://a"}},
            {"resources/unsubscribe", %{"uri" => "open://a"}},
            {"completion/complete",
             %{
               "ref" => %{"type" => "ref/resource", "uri" => "open://a"},
               "argument" => %{"name" => "id", "value" => ""}
             }}
          ] do
        refute request(method, params, %Plug.Conn{})["error"],
               "#{method} should not be scope-gated for an unscoped resource"
      end
    end
  end
end

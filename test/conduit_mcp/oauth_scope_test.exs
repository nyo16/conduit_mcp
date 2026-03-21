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
end

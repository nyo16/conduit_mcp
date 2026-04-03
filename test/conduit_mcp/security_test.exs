defmodule ConduitMcp.SecurityTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Handler
  alias ConduitMcp.Protocol

  # A server module whose tool handler raises an exception
  defmodule CrashingServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn) do
      {:ok,
       %{
         "tools" => [
           %{
             "name" => "crash",
             "description" => "Always crashes",
             "inputSchema" => %{"type" => "object", "properties" => %{}}
           }
         ]
       }}
    end

    @impl true
    def handle_call_tool(_conn, "crash", _params) do
      raise "sensitive internal error: database connection to 10.0.0.5:5432 failed"
    end

    @impl true
    def handle_list_resources(_conn), do: {:ok, %{"resources" => []}}
    @impl true
    def handle_read_resource(_conn, _uri),
      do: {:error, %{"code" => -32601, "message" => "Not found"}}

    @impl true
    def handle_list_prompts(_conn), do: {:ok, %{"prompts" => []}}
    @impl true
    def handle_get_prompt(_conn, _name, _args),
      do: {:error, %{"code" => -32601, "message" => "Not found"}}
  end

  describe "error information leakage prevention" do
    test "rescue clause does not expose internal error details to clients" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "crash", "arguments" => %{}}
      }

      response = Handler.handle_request(request, CrashingServer)

      assert response["error"]["code"] == Protocol.internal_error()
      assert response["error"]["message"] == "Internal server error"

      # Must NOT contain internal details
      refute response["error"]["message"] =~ "database"
      refute response["error"]["message"] =~ "10.0.0.5"
      refute response["error"]["message"] =~ "sensitive"
      refute response["error"]["message"] =~ "%"
      refute response["error"]["message"] =~ "CrashingServer"
    end

    test "rescue clause returns proper JSON-RPC structure" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "tools/call",
        "params" => %{"name" => "crash", "arguments" => %{}}
      }

      response = Handler.handle_request(request, CrashingServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 42
      assert is_map(response["error"])
      assert is_integer(response["error"]["code"])
    end
  end

  describe "method name handling" do
    test "long method names are truncated in error responses" do
      long_method = String.duplicate("a", 10_000)

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => long_method
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)

      assert response["error"]["code"] == Protocol.method_not_found()
      # The error message should not contain the full 10K string
      assert String.length(response["error"]["message"]) <= 300
    end

    test "method with control characters does not crash handler" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call\x00\x01\x02"
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)
      assert is_map(response)
      assert response["jsonrpc"] == "2.0"
    end
  end

  describe "invalid request handling" do
    test "completely empty map returns error" do
      response = Handler.handle_request(%{}, ConduitMcp.TestServer)

      assert response["error"]["code"] == Protocol.invalid_request()
    end

    test "request with nil method does not crash" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => nil
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)
      assert is_map(response)
    end

    test "request with non-string method does not crash" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => 12345
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)
      assert is_map(response)
    end
  end
end

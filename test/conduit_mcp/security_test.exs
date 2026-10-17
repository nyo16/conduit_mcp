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

  defmodule ScopedResourceServer do
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
      {:ok, %{"completion" => %{"values" => [], "total" => 0, "hasMore" => false}}}
    end
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

    test "control characters are stripped, not reflected" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call\x00\x01\x02"
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)

      # `assert is_map(response)` passed for a *success* response, for `%{}`,
      # and for any regression short of a raise — which is exactly what let the
      # reflected control bytes go unnoticed.
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == Protocol.method_not_found()
      assert response["error"]["message"] == "Method not found: tools/call"
      refute response["error"]["message"] =~ "\x00"
    end
  end

  describe "invalid request handling" do
    test "completely empty map returns error" do
      response = Handler.handle_request(%{}, ConduitMcp.TestServer)

      assert response["error"]["code"] == Protocol.invalid_request()
    end

    test "request with nil method is an invalid request" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => nil}

      response = Handler.handle_request(request, ConduitMcp.TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == Protocol.invalid_request()
      assert response["error"]["message"] == "Invalid JSON-RPC 2.0 request"
    end

    test "request with non-string method is an invalid request" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => 12_345}

      response = Handler.handle_request(request, ConduitMcp.TestServer)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == Protocol.invalid_request()
      assert response["error"]["message"] == "Invalid JSON-RPC 2.0 request"
    end

    test "a non-string protocolVersion returns invalid_params, not internal_error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => %{}}
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)

      assert response["error"]["code"] == Protocol.invalid_params()
      assert response["error"]["message"] =~ "protocolVersion must be a string"
    end

    test "an oversized protocolVersion is neither reflected in full nor logged in full" do
      oversized = String.duplicate("v", 1_000_000)

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => oversized}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          response = Handler.handle_request(request, ConduitMcp.TestServer)
          send(self(), {:response, response})
        end)

      assert_received {:response, response}

      assert response["error"]["code"] == Protocol.invalid_request()
      assert String.length(response["error"]["message"]) <= 300
      refute log =~ String.duplicate("v", 200)
    end

    test "a multibyte method name and protocolVersion get JSON-RPC errors, not a raise" do
      # `Reflect.text/2` byte-clamps before its `/u` regex; a truncated
      # codepoint made the regex raise, and the handler's rescue reflects the
      # method again, so it raised a second time from inside the rescue -
      # producing no response at all and a bare 500 from the adapter.
      multibyte = String.duplicate("€", 300)

      unknown = %{"jsonrpc" => "2.0", "id" => 1, "method" => multibyte}
      response = Handler.handle_request(unknown, ConduitMcp.TestServer)
      assert response["error"]["code"] == Protocol.method_not_found()
      assert String.valid?(response["error"]["message"])

      init = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "initialize",
        "params" => %{"protocolVersion" => multibyte}
      }

      response = Handler.handle_request(init, ConduitMcp.TestServer)
      assert response["error"]["code"] == Protocol.invalid_request()
      assert String.valid?(response["error"]["message"])
    end

    test "a JSON array in any reflected field gets a JSON-RPC reply, not a raise" do
      # `notifications/cancelled` is reached from the `cond` in
      # handle_request/3, *outside* do_handle_method/5's rescue, and it pipes
      # the raw client `reason` through Reflect. An array there used to raise
      # ArgumentError out of handle_request/3 entirely: no JSON-RPC reply, no
      # telemetry, a bare adapter 500 on an unauthenticated POST.
      #
      # The reason is only reflected for a request in flight, so each id is
      # tracked first, as the handler would, in the default conn's scope.
      scope = ConduitMcp.Cancellation.scope(%Plug.Conn{})

      for reason <- [[1.5], [%{}], [-1], [1, 2]] do
        request_id = "arr-#{System.unique_integer([:positive])}"
        :ok = ConduitMcp.Cancellation.track(request_id, scope)

        notification = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{"requestId" => request_id, "reason" => reason}
        }

        assert Handler.handle_request(notification, ConduitMcp.TestServer) == :ok
        assert is_binary(ConduitMcp.Cancellation.reason(request_id, scope))

        ConduitMcp.Cancellation.untrack(request_id, scope)
        ConduitMcp.Cancellation.clear(request_id, scope)
      end

      # The same shape on a request path must be a routed error, not the
      # rescue's -32603.
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/get",
        "params" => %{"taskId" => [1.5]}
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)
      refute response["error"]["code"] == Protocol.internal_error()
      assert String.valid?(response["error"]["message"])
    end

    test "an oversized taskId is not reflected in full" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/get",
        "params" => %{"taskId" => String.duplicate("t", 5_000) <> "\x00"}
      }

      response = Handler.handle_request(request, ConduitMcp.TestServer)

      assert response["error"]["code"] == ConduitMcp.Errors.resource_not_found()
      assert String.length(response["error"]["message"]) <= 300
      refute response["error"]["message"] =~ "\x00"
    end
  end

  describe "malformed notifications/cancelled" do
    # Each shape reached `Map.get/2` on a non-map in the un-rescued
    # notification path: a BadMapError out of handle_request/3 and, through a
    # transport, a bare 500 with no JSON-RPC body.
    @non_map_params [nil, [1], "x", 5]

    defp cancelled_notification(params) do
      %{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => params}
    end

    test "non-map params get invalid_params with a null id" do
      for params <- @non_map_params do
        response = Handler.handle_request(cancelled_notification(params), ConduitMcp.TestServer)

        assert %{"jsonrpc" => "2.0", "id" => nil, "error" => error} = response,
               "params #{inspect(params)} got #{inspect(response)}"

        assert error["code"] == Protocol.invalid_params()
        assert error["message"] =~ "requires a params object"
      end
    end

    test "a notification with no params at all is still accepted" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}

      assert Handler.handle_request(notification, ConduitMcp.TestServer) == :ok
    end

    test "non-map params over StreamableHTTP get a JSON-RPC error body, not a 500" do
      opts = ConduitMcp.Transport.StreamableHTTP.init(server_module: ConduitMcp.TestServer)

      for params <- @non_map_params do
        conn =
          Plug.Test.conn(:post, "/", JSON.encode!(cancelled_notification(params)))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
          |> ConduitMcp.Transport.StreamableHTTP.call(opts)

        # `Shared.dispatch_post/2` sends every response map with 200.
        assert conn.status == 200, "params #{inspect(params)} got #{conn.status}"

        assert %{"id" => nil, "error" => %{"code" => code}} = JSON.decode!(conn.resp_body)
        assert code == Protocol.invalid_params()
      end
    end
  end

  describe "non-binary resource uri on a scoped server" do
    # The scope lookup for a templated resource runs `Regex.run/2` on the uri,
    # which raises for a non-binary; the request-path rescue then answered
    # -32603 and logged "Error handling method" for what is a client mistake.
    #
    # The module is async, so the capture can hold other tests' errors: each
    # request carries a unique id, and the log is formatted with `request_id`
    # metadata so `refute_rescued/2` matches only this request's rescue line.
    defp scoped_request(method, params) do
      id = System.unique_integer([:positive])

      log =
        ExUnit.CaptureLog.capture_log([level: :error, metadata: [:request_id]], fn ->
          response =
            Handler.handle_request(
              %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
              ScopedResourceServer,
              Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["vault:read"])
            )

          send(self(), {:response, response})
        end)

      assert_received {:response, response}
      {response, log, id}
    end

    defp refute_rescued(log, id) do
      refute log =~ "request_id=#{id} [error] Error handling method"
    end

    test "resources/read, subscribe and unsubscribe answer invalid_params" do
      for method <- ["resources/read", "resources/subscribe", "resources/unsubscribe"],
          uri <- [5, %{}] do
        {response, log, id} = scoped_request(method, %{"uri" => uri})

        assert response["error"]["code"] == Protocol.invalid_params(),
               "#{method} uri #{inspect(uri)} got #{inspect(response)}"

        assert response["error"]["message"] =~ "uri must be a string"
        refute_rescued(log, id)
      end
    end

    test "completion/complete with a non-binary ref uri answers invalid_params" do
      for uri <- [5, %{}] do
        params = %{
          "ref" => %{"type" => "ref/resource", "uri" => uri},
          "argument" => %{"name" => "id", "value" => ""}
        }

        {response, log, id} = scoped_request("completion/complete", params)

        assert response["error"]["code"] == Protocol.invalid_params()
        assert response["error"]["message"] =~ "uri must be a string"
        refute_rescued(log, id)
      end
    end

    test "a string uri is still authorized and dispatched" do
      {response, _log, _id} = scoped_request("resources/subscribe", %{"uri" => "vault://a"})

      assert response["result"]["subscribed"] == "vault://a"
    end
  end
end

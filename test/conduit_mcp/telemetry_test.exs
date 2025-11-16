defmodule ConduitMcp.TelemetryTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.{Handler, TestServer, TelemetryTestHelper}
  alias ConduitMcp.Plugs.Auth

  describe "request telemetry events" do
    test "emits telemetry for successful requests" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :request, :stop]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "ping"
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.method == "ping"
      assert metadata.server_module == TestServer
      assert metadata.status == :ok
    end

    test "emits telemetry for failed requests" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :request, :stop]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "unknown/method"
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :request, :stop], ^ref, _measurements, metadata}
      assert metadata.method == "unknown/method"
      assert metadata.status == :error
    end
  end

  describe "tool execution telemetry" do
    test "emits telemetry for successful tool execution" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :tool, :execute]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{"message" => "test"}
        }
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :tool, :execute], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.tool_name == "echo"
      assert metadata.server_module == TestServer
      assert metadata.status == :ok
    end

    test "emits telemetry for failed tool execution" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :tool, :execute]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "fail",
          "arguments" => %{}
        }
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :tool, :execute], ^ref, _measurements, metadata}
      assert metadata.tool_name == "fail"
      assert metadata.status == :error
    end
  end

  describe "resource telemetry events" do
    test "emits telemetry for successful resource read" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :resource, :read]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => "test://resource1"}
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :resource, :read], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.uri == "test://resource1"
      assert metadata.server_module == TestServer
      assert metadata.status == :ok
    end

    test "emits telemetry for failed resource read" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :resource, :read]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => "test://unknown"}
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :resource, :read], ^ref, _measurements, metadata}
      assert metadata.uri == "test://unknown"
      assert metadata.status == :error
    end
  end

  describe "prompt telemetry events" do
    test "emits telemetry for successful prompt get" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :prompt, :get]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "greeting",
          "arguments" => %{"name" => "Alice"}
        }
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :prompt, :get], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.prompt_name == "greeting"
      assert metadata.server_module == TestServer
      assert metadata.status == :ok
    end

    test "emits telemetry for failed prompt get" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :prompt, :get]])

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "unknown_prompt",
          "arguments" => %{}
        }
      }

      Handler.handle_request(request, TestServer)

      assert_receive {[:conduit_mcp, :prompt, :get], ^ref, _measurements, metadata}
      assert metadata.prompt_name == "unknown_prompt"
      assert metadata.status == :error
    end
  end

  describe "authentication telemetry events" do
    test "emits telemetry for successful bearer token auth" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :auth, :verify]])

      opts = Auth.init(strategy: :bearer_token, token: "secret-123")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer secret-123")

      Auth.call(conn, opts)

      assert_receive {[:conduit_mcp, :auth, :verify], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.strategy == :bearer_token
      assert metadata.status == :ok
      refute Map.has_key?(metadata, :reason)
    end

    test "emits telemetry for failed authentication" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :auth, :verify]])

      opts = Auth.init(strategy: :bearer_token, token: "secret-123")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer wrong-token")

      Auth.call(conn, opts)

      assert_receive {[:conduit_mcp, :auth, :verify], ^ref, _measurements, metadata}
      assert metadata.strategy == :bearer_token
      assert metadata.status == :error
      assert metadata.reason == "Invalid token"
    end

    test "emits telemetry for custom verification function" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :auth, :verify]])

      verify_fn = fn token ->
        if token == "valid", do: {:ok, %{user_id: 1}}, else: {:error, "Not found"}
      end

      opts = Auth.init(strategy: :function, verify: verify_fn)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Bearer valid")

      Auth.call(conn, opts)

      assert_receive {[:conduit_mcp, :auth, :verify], ^ref, _measurements, metadata}
      assert metadata.strategy == :function
      assert metadata.status == :ok
    end

    test "emits telemetry for API key authentication" do
      ref = TelemetryTestHelper.attach_event_handlers(self(), [[:conduit_mcp, :auth, :verify]])

      opts = Auth.init(strategy: :api_key, api_key: "key-123", header: "x-api-key")

      conn =
        conn(:get, "/")
        |> put_req_header("x-api-key", "key-123")

      Auth.call(conn, opts)

      assert_receive {[:conduit_mcp, :auth, :verify], ^ref, _measurements, metadata}
      assert metadata.strategy == :api_key
      assert metadata.status == :ok
    end
  end

  describe "Telemetry.events/0" do
    test "returns all event names" do
      events = ConduitMcp.Telemetry.events()

      assert [:conduit_mcp, :request, :stop] in events
      assert [:conduit_mcp, :tool, :execute] in events
      assert [:conduit_mcp, :resource, :read] in events
      assert [:conduit_mcp, :prompt, :get] in events
      assert [:conduit_mcp, :auth, :verify] in events
      assert length(events) == 5
    end
  end

  describe "default handlers" do
    test "can attach and detach default handlers" do
      assert :ok == ConduitMcp.Telemetry.attach_default_handlers()
      assert :ok == ConduitMcp.Telemetry.detach_default_handlers()
    end

    test "returns error when attaching handlers twice" do
      :ok = ConduitMcp.Telemetry.attach_default_handlers()

      assert {:error, :already_exists} = ConduitMcp.Telemetry.attach_default_handlers()

      :ok = ConduitMcp.Telemetry.detach_default_handlers()
    end

    test "returns error when detaching non-existent handlers" do
      assert {:error, :not_found} = ConduitMcp.Telemetry.detach_default_handlers()
    end
  end
end

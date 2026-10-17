defmodule ConduitMcp.TelemetryTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias ConduitMcp.{Handler, TelemetryTestHelper, TestServer}
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
      # A coarse atom, never the verifier's reason: telemetry metadata ships
      # verbatim to metrics backends and a :verify function may embed the
      # credential in its reason.
      assert metadata.reason == :invalid_credential
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
    # The one source-scanning test in the suite, because it guards doc drift:
    # `events/0` is what `attach_default_handlers/0`, the moduledoc and PromEx
    # are kept in step with, and it once listed 7 of the 12 events emitted.
    @lib Path.expand("../../lib", __DIR__)
    @literal_call ~r/:telemetry\.(?:execute|span)\(\s*\[([^\]]*)\]/
    @variable_call ~r/:telemetry\.(?:execute|span)\(\s*([a-z_]\w*)/
    # `ConduitMcp.Session.Janitor` emits a configurable event: its default and
    # every `telemetry_event:` passed to it are the names it can emit.
    @configured_event ~r/(?:@default_event|telemetry_event:)\s*\[([^\]]*)\]/

    defp lib_sources do
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          do: {Path.relative_to(path, @lib), File.read!(path)}
    end

    defp scan_event_lists(regex, source) do
      for [list] <- Regex.scan(regex, source, capture: :all_but_first) do
        list
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":")))
        |> Enum.map(&String.to_existing_atom/1)
      end
    end

    test "lists exactly the events emitted under lib/" do
      sources = lib_sources()

      # An emit through a variable is only allowed where the variable's
      # possible values are themselves literal in the source (scanned below).
      variable_emits =
        for {path, source} <- sources,
            [var] <- Regex.scan(@variable_call, source, capture: :all_but_first),
            do: {path, var}

      assert variable_emits == [{"conduit_mcp/session/janitor.ex", "event"}]

      emitted =
        for {_path, source} <- sources,
            regex <- [@literal_call, @configured_event],
            event <- scan_event_lists(regex, source),
            into: MapSet.new(),
            do: event

      events = ConduitMcp.Telemetry.events()

      assert MapSet.new(events) == emitted
      assert length(events) == MapSet.size(emitted), "events/0 lists an event twice"
    end
  end

  describe "default handlers on every event" do
    setup do
      on_exit(fn -> ConduitMcp.Telemetry.detach_default_handlers() end)
      :ok
    end

    # `:telemetry` detaches a handler that raises, from every event it is
    # attached to; an event in `events/0` without a matching `handle_event/4`
    # clause would silence the whole default logger on its first emission.
    test "the default logger survives each event's real measurements" do
      :ok = ConduitMcp.Telemetry.attach_default_handlers()
      Logger.put_process_level(self(), :debug)

      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        :telemetry.execute([:conduit_mcp, :request, :cancelled], %{count: 1}, %{
          request_id: 1,
          scope: "anon",
          reason: "user\nforged"
        })

        :telemetry.execute(
          [:conduit_mcp, :cancellation, :cleanup],
          %{removed: 1, in_flight_removed: 2},
          %{}
        )

        :telemetry.execute([:conduit_mcp, :cancellation, :janitor], %{removed: 1}, %{
          store: ConduitMcp.Cancellation
        })

        :telemetry.execute([:conduit_mcp, :session, :cleanup], %{removed: 3}, %{
          store: ConduitMcp.Session.EtsStore
        })

        :telemetry.execute([:conduit_mcp, :tasks, :cleanup], %{removed: 0}, %{})

        :telemetry.execute([:conduit_mcp, :mrtr, :input_required], %{count: 2}, %{
          method: "tools/call",
          server_module: __MODULE__,
          round: 1
        })

        client = %{client: {:client, make_ref()}, server_id: "s", transport: :stdio, era: nil}
        span = %{duration: 1, monotonic_time: 2}

        for span_name <- [:request, :tool_call] do
          :telemetry.execute(
            [:conduit_mcp, :client, span_name, :start],
            %{monotonic_time: 1, system_time: 1},
            Map.merge(client, %{method: "tools/call", tool_name: "echo"})
          )

          :telemetry.execute(
            [:conduit_mcp, :client, span_name, :exception],
            span,
            Map.merge(client, %{method: "tools/call", tool_name: "echo", kind: :error})
          )
        end

        :telemetry.execute(
          [:conduit_mcp, :client, :request, :stop],
          span,
          Map.merge(client, %{method: "x\nforged", status: :ok, error_kind: nil, request_id: 1})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :tool_call, :stop],
          Map.put(span, :rounds, 1),
          Map.merge(client, %{
            tool_name: "echo",
            status: :error,
            error_kind: :timeout,
            is_error: nil
          })
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :connection, :transition],
          %{system_time: 1},
          Map.merge(client, %{from: nil, to: :closed, reason: :gave_up, attempt: 3})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :request, :cancel],
          %{count: 1},
          Map.merge(client, %{method: "tools/call", request_id: 4, reason: :timeout})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :response, :dropped],
          %{count: 1},
          Map.put(client, :request_id, nil)
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :notification],
          %{count: 1},
          Map.put(client, :method, "notifications/message")
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :cache, :refresh, :start],
          %{monotonic_time: 1, system_time: 1},
          Map.merge(client, %{kind: :tools, trigger: :demand})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :cache, :refresh, :stop],
          Map.merge(span, %{count: 2, pages: 1, rejected: 1}),
          Map.merge(client, %{kind: :tools, trigger: :demand, status: :ok, error_kind: nil})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :tool, :rejected],
          %{count: 1},
          Map.merge(client, %{tool_name: nil, reason: :invalid_name})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :tool, :definition_changed],
          %{count: 1},
          Map.put(client, :tool_name, "echo")
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :policy, :decision],
          %{count: 1},
          Map.merge(client, %{
            target: :tool,
            tool_name: "echo",
            decision: :deny,
            source: :deny,
            reason: :deny_rule,
            rule_id: {:deny, 0},
            approval: nil
          })
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :hook, :stop],
          Map.delete(span, :rounds),
          Map.merge(client, %{hook_id: :audit, kind: :pre_tool_call, status: :cont})
        )

        :telemetry.execute(
          [:conduit_mcp, :client, :hook, :exception],
          Map.delete(span, :rounds),
          Map.merge(client, %{
            hook_id: {:post_tool_call, 0},
            kind: :post_tool_call,
            reason: :raise
          })
        )

        # The OAuth events, through their real emitter: a stop with an
        # error reason, and an exception.
        oauth = %{client: {:client, make_ref()}, server_id: "s", principal: nil}

        for op <- [:discovery, :registration, :token_exchange, :refresh, :step_up] do
          ConduitMcp.Client.OAuth.Telemetry.span(op, oauth, fn ->
            {{:error, ConduitMcp.Client.OAuth.Error.new(:invalid_grant)}, %{}}
          end)

          assert_raise RuntimeError, fn ->
            ConduitMcp.Client.OAuth.Telemetry.span(op, oauth, fn -> raise "boom" end)
          end
        end

        ConduitMcp.Client.OAuth.Telemetry.authorization_required(oauth, :step_up)
      end)

      for event <- ConduitMcp.Telemetry.events() do
        assert "conduit-mcp-default-logger" in default_logger_ids(event), inspect(event)
      end
    end
  end

  describe "default handlers" do
    # `"conduit-mcp-default-logger"` is a *global* :telemetry handler. Leaking
    # it makes the third test below fail (detach returns :ok instead of
    # {:error, :not_found}) — order-dependent, and reported against the wrong
    # test — and a leaked handler fires for every subsequent [:conduit_mcp, *]
    # event while dot-dereferencing metadata.
    setup do
      on_exit(fn -> ConduitMcp.Telemetry.detach_default_handlers() end)
      :ok
    end

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

    # The default handlers log at :debug, so the level is raised for this
    # process only: the handler runs in the emitting process, which is the test
    # process because `Handler.handle_request/2` is called directly.
    test "a non-string resource uri neither raises in nor detaches the default logger" do
      :ok = ConduitMcp.Telemetry.attach_default_handlers()
      Logger.put_process_level(self(), :debug)

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/read",
        "params" => %{"uri" => %{}}
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert %{"error" => %{"code" => -32_602}} = Handler.handle_request(request, TestServer)
        end)

      assert "conduit-mcp-default-logger" in default_logger_ids([:conduit_mcp, :resource, :read])
      assert "conduit-mcp-default-logger" in default_logger_ids([:conduit_mcp, :request, :stop])
      assert log =~ "Resource read: uri= status=error"
    end

    test "client-sourced metadata cannot forge a log line" do
      :ok = ConduitMcp.Telemetry.attach_default_handlers()
      Logger.put_process_level(self(), :debug)

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "nope\n[error] FORGED", "arguments" => %{}}
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          Handler.handle_request(request, TestServer)
        end)

      assert log =~ "Tool executed: tool=nope[error] FORGED status=error"
      refute log =~ "\n[error] FORGED"
    end
  end

  defp default_logger_ids(event) do
    event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
  end
end

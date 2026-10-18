defmodule ConduitMcp.Client.HandlerRuntimeTest do
  # `ConduitMcp.Client.Handler` at runtime: legacy server requests in
  # supervised tasks, modern MRTR input in the caller, and the safety
  # defaults around both (SC-1..SC-6).
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Input.Elicitation
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Test.Client.FakeTransport

  defmodule Full do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_sampling(params, ctx) do
      send(ctx.assigns.test_pid, {:sampling, params, ctx, self()})

      case params["systemPrompt"] do
        "block" ->
          receive do
            :release -> :ok
          end

        "crash" ->
          raise "boom"

        "hang" ->
          receive do
            :never -> :ok
          end

        _other ->
          :ok
      end

      {:ok,
       %{"role" => "assistant", "content" => %{"type" => "text", "text" => "hi"}, "model" => "m"}}
    end

    @impl true
    def handle_elicitation(params, ctx) do
      send(ctx.assigns.test_pid, {:elicitation, params, ctx, self()})
      {:ok, Map.get(ctx.assigns, :answer, %{"action" => "decline"})}
    end

    @impl true
    def elicitation_modes, do: [:form, :url]

    @impl true
    def list_roots(ctx), do: {:ok, %{"roots" => ctx.assigns.roots}}
  end

  defmodule FormOnly do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(params, ctx) do
      send(ctx.assigns.test_pid, {:elicitation, params, ctx, self()})
      {:ok, %{"action" => "cancel"}}
    end
  end

  setup do
    {:ok, name: {__MODULE__, make_ref()}}
  end

  defp start(name, opts \\ []) do
    {assigns, opts} = Keyword.pop(opts, :assigns, %{})
    opts = Keyword.put_new(opts, :handler, Full)
    start_client(name, [assigns: Map.put(assigns, :test_pid, self())] ++ opts)
  end

  defp server_request(conn, id, method, params, related \\ nil) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    FakeTransport.push(conn, {:server_request, id, message, related})
  end

  defp expect_response(conn, id) do
    assert_receive {:fake_transport, ^conn, {:respond, %{"id" => ^id} = response}}, 1_000
    response
  end

  defp sampling(extra \\ %{}),
    do: Map.merge(%{"messages" => [], "maxTokens" => 100}, extra)

  # A pending legacy call, so server requests are not idle.
  defp pending_call(name, conn, opts \\ []) do
    task = Task.async(fn -> Client.call_tool(name, "slow", %{}, opts) end)
    {id, _message, _opts} = expect_request(conn, "tools/call")
    {task, id}
  end

  defp finish_call(conn, {task, id}) do
    reply(conn, id, %{"content" => []})
    assert {:ok, _} = Task.await(task)
  end

  describe "capabilities (SC-1)" do
    test "no handler advertises nothing; an undeclared input request fails the call",
         %{name: name} do
      conn = start_client(name)
      FakeTransport.push(conn, {:connected, %{}})
      {id, discover, _} = expect_request(conn, "server/discover")
      assert discover["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"] == %{}
      reply(conn, id, discover_result())
      assert :ok = Client.await_ready(name)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}) end)
      {id, _, _} = expect_request(conn, "tools/call")

      reply(conn, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{
          "s" => %{"method" => "sampling/createMessage", "params" => sampling()}
        }
      })

      assert {:error, %Error{kind: :protocol, reason: {:undeclared_input_request, _}}} =
               Task.await(task)

      assert_no_leaks(name, conn)
    end

    test "a handler without sampling never sees a sampling input request", %{name: name} do
      conn = start(name, handler: FormOnly)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}) end)
      {id, message, _} = expect_request(conn, "tools/call")

      assert message["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"] == %{
               "elicitation" => %{"form" => %{}}
             }

      reply(conn, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{
          "s" => %{"method" => "sampling/createMessage", "params" => sampling()}
        }
      })

      assert {:error, %Error{kind: :protocol}} = Task.await(task)
      refute_received {:sampling, _, _, _}
      assert_no_leaks(name, conn)
    end

    test "sampling options shape the advertised capability", %{name: name} do
      conn = start(name, sampling: [context: true, tools: true])
      FakeTransport.push(conn, {:connected, %{}})
      {_id, discover, _} = expect_request(conn, "server/discover")

      assert %{"sampling" => %{"context" => %{}, "tools" => %{}}, "roots" => %{}} =
               discover["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
    end
  end

  describe "modern MRTR input (in the caller)" do
    test "sampling is clamped and coerced, and runs in the calling process", %{name: name} do
      conn = start(name)
      ready_modern(name, conn)
      caller = self()

      task =
        Task.async(fn ->
          Client.call_tool(name, "t", %{}, assigns: %{test_pid: caller, who: :call})
        end)

      {id, _, _} = expect_request(conn, "tools/call")
      params = sampling(%{"maxTokens" => 1_000_000, "includeContext" => "allServers"})

      reply(conn, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{"s" => %{"method" => "sampling/createMessage", "params" => params}},
        "requestState" => "opaque"
      })

      assert_receive {:sampling, seen, ctx, handler_pid}
      assert seen["maxTokens"] == 4_096
      assert seen["includeContext"] == "none"
      assert handler_pid == task.pid
      assert %{era: :modern, assigns: %{who: :call}, server_id: _} = ctx

      {id, retry, _} = expect_request(conn, "tools/call")
      assert %{"s" => %{"role" => "assistant"}} = retry["params"]["inputResponses"]
      assert retry["params"]["requestState"] == "opaque"
      reply(conn, id, %{"content" => [%{"type" => "text", "text" => "done"}]})

      assert {:ok, %Client.ToolResult{content: [%{"text" => "done"}]}} = Task.await(task)
      assert_no_leaks(name, conn)
    end

    test "with sampling context enabled, includeContext passes", %{name: name} do
      conn = start(name, sampling: [context: true, max_tokens: 10])
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}, assigns: %{test_pid: self()}) end)
      {id, _, _} = expect_request(conn, "tools/call")
      params = sampling(%{"maxTokens" => 5, "includeContext" => "thisServer"})

      reply(conn, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{"s" => %{"method" => "sampling/createMessage", "params" => params}}
      })

      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, %{"content" => []})
      assert {:ok, _} = Task.await(task)
    end

    test "an elicitation URL is flagged, never fetched (SC-3)", %{name: name} do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)

      conn = start(name)
      ready_modern(name, conn)
      caller = self()

      task = Task.async(fn -> Client.call_tool(name, "t", %{}, assigns: %{test_pid: caller}) end)
      {id, _, _} = expect_request(conn, "tools/call")

      reply(conn, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{
          "a" => elicit_url("https://127.0.0.1:#{port}/consent?x=1"),
          "b" => elicit_url("https://xn--pple-43d.com/login")
        }
      })

      assert_receive {:elicitation, _, %{url: url, host: "127.0.0.1", idn?: false} = ctx, _}
      assert url =~ "/consent?x=1"
      assert ctx.origin_mismatch? == true
      assert ctx.mode == :url
      assert_receive {:elicitation, _, %{host: "xn--pple-43d.com", idn?: true}, _}

      {id, _, _} = expect_request(conn, "tools/call")
      reply(conn, id, %{"content" => []})
      assert {:ok, _} = Task.await(task)

      # Hit counter: nobody connected to the URL's host.
      assert {:error, :timeout} = :gen_tcp.accept(listen, 0)
      :gen_tcp.close(listen)
      assert_no_leaks(name, conn)
    end

    test "a javascript: URL is refused before the handler", %{name: name} do
      conn = start(name)
      ready_modern(name, conn)

      task = Task.async(fn -> Client.call_tool(name, "t", %{}, assigns: %{test_pid: self()}) end)
      {id, _, _} = expect_request(conn, "tools/call")

      reply(conn, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{"a" => elicit_url("javascript:alert(1)")}
      })

      assert {:error, %Error{kind: :input_handler, data: %{"code" => -32_602}}} =
               Task.await(task)

      refute_received {:elicitation, _, _, _}
    end
  end

  defp elicit_url(url) do
    %{
      "method" => "elicitation/create",
      "params" => %{"mode" => "url", "message" => "Sign in", "url" => url, "elicitationId" => "e"}
    }
  end

  describe "legacy server requests" do
    test "run in a supervised task with the call's assigns, pausing its deadline",
         %{name: name} do
      conn = start(name, protocol: :legacy)
      ready_legacy(name, conn)
      caller = self()

      {task, call_id} =
        pending_call(name, conn, timeout: 500, assigns: %{test_pid: caller, who: :call})

      server_request(
        conn,
        7,
        "sampling/createMessage",
        sampling(%{"systemPrompt" => "block"}),
        call_id
      )

      assert_receive {:sampling, _params, ctx, handler}
      assert %{era: :legacy, related_request_id: ^call_id, assigns: %{who: :call}} = ctx

      {:ok, task_sup, _} = Registry.lookup({:task_sup, name})
      assert handler in Task.Supervisor.children(task_sup)
      assert handler != conn
      assert state(conn).pending[call_id].paused == 1

      # Past the call's 500 ms timeout, the call is still waiting.
      refute_receive {_ref, {:error, %Error{kind: :timeout}}}, 700
      refute_received {:fake_transport, ^conn, {:cancel, ^call_id, _, _}}

      send(handler, :release)
      assert %{"result" => %{"role" => "assistant"}} = expect_response(conn, 7)
      assert state(conn).pending[call_id].paused == 0

      finish_call(conn, {task, call_id})
      assert_no_leaks(name, conn)
    end

    test "a paused deadline still ends at max_total_timeout", %{name: name} do
      conn = start(name, protocol: :legacy)
      ready_legacy(name, conn)

      started = System.monotonic_time(:millisecond)
      {task, call_id} = pending_call(name, conn, timeout: 500, max_total_timeout: 1_000)

      server_request(
        conn,
        1,
        "sampling/createMessage",
        sampling(%{"systemPrompt" => "block"}),
        call_id
      )

      assert_receive {:sampling, _, _, handler}
      assert state(conn).pending[call_id].paused == 1

      assert {:error, %Error{kind: :timeout}} = Task.await(task)
      # The pause outlived the 500 ms timeout; only the total cap ended it.
      assert System.monotonic_time(:millisecond) - started >= 1_000
      assert_receive {:fake_transport, ^conn, {:cancel, ^call_id, _, :timeout}}
      send(handler, :release)
      expect_response(conn, 1)
      assert_no_leaks(name, conn)
    end

    test "an idle sampling request is refused with the rejection code", %{name: name} do
      conn = start(name, protocol: :legacy, sampling: [rejection_code: -7])
      ready_legacy(name, conn)

      server_request(conn, 1, "sampling/createMessage", sampling())
      assert %{"error" => %{"code" => -7}} = expect_response(conn, 1)
      refute_received {:sampling, _, _, _}
      assert_no_leaks(name, conn)
    end

    test "the input rate limit trips", %{name: name} do
      conn = start(name, protocol: :legacy, input_rate_limit: [per_second: 1, burst: 2])
      ready_legacy(name, conn)
      call = pending_call(name, conn)
      {_task, call_id} = call

      for id <- 1..2 do
        server_request(conn, id, "sampling/createMessage", sampling(), call_id)
        assert %{"result" => _} = expect_response(conn, id)
      end

      server_request(conn, 3, "sampling/createMessage", sampling(), call_id)
      assert %{"error" => %{"code" => -1, "message" => message}} = expect_response(conn, 3)
      assert message =~ "rate limit"

      server_request(conn, 4, "roots/list", %{})
      assert %{"error" => %{"code" => -32_000}} = expect_response(conn, 4)

      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "a sampling loop past 5 tool rounds is refused before the handler (SC-2)",
         %{name: name} do
      conn = start(name, protocol: :legacy, sampling: [rejection_code: -7])
      ready_legacy(name, conn)
      call = pending_call(name, conn)
      {_task, call_id} = call

      # One tool round: the model asked for a tool, the server ran it.
      round = fn n ->
        [
          %{
            "role" => "assistant",
            "content" => [%{"type" => "tool_use", "id" => "u#{n}", "name" => "t", "input" => %{}}]
          },
          %{
            "role" => "user",
            "content" => %{"type" => "tool_result", "toolUseId" => "u#{n}", "content" => []}
          }
        ]
      end

      five = Enum.flat_map(1..5, round)
      server_request(conn, 1, "sampling/createMessage", sampling(%{"messages" => five}), call_id)
      assert %{"result" => _} = expect_response(conn, 1)
      assert_received {:sampling, _, _, _}

      six = five ++ round.(6)
      server_request(conn, 2, "sampling/createMessage", sampling(%{"messages" => six}), call_id)
      assert %{"error" => %{"code" => -7, "message" => message}} = expect_response(conn, 2)
      assert message =~ "tool"
      refute_received {:sampling, _, _, _}

      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "sampling: [max_tool_iterations: n] moves the cap (SC-2)", %{name: name} do
      conn = start(name, protocol: :legacy, sampling: [max_tool_iterations: 1])
      ready_legacy(name, conn)
      call = pending_call(name, conn)
      {_task, call_id} = call

      use_and_result = [
        %{
          "role" => "assistant",
          "content" => %{"type" => "tool_use", "id" => "u", "name" => "t"}
        },
        %{"role" => "user", "content" => %{"type" => "tool_result", "toolUseId" => "u"}}
      ]

      messages = use_and_result ++ use_and_result

      server_request(
        conn,
        1,
        "sampling/createMessage",
        sampling(%{"messages" => messages}),
        call_id
      )

      assert %{"error" => %{"code" => -1}} = expect_response(conn, 1)
      refute_received {:sampling, _, _, _}

      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "beyond max_server_requests the server gets busy", %{name: name} do
      conn = start(name, protocol: :legacy, max_server_requests: 1)
      ready_legacy(name, conn)
      call = pending_call(name, conn)
      {_task, call_id} = call

      server_request(
        conn,
        1,
        "sampling/createMessage",
        sampling(%{"systemPrompt" => "block"}),
        call_id
      )

      assert_receive {:sampling, _, _, handler}
      server_request(conn, 2, "sampling/createMessage", sampling(), call_id)
      assert %{"error" => %{"code" => -32_000}} = expect_response(conn, 2)

      send(handler, :release)
      expect_response(conn, 1)
      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "notifications/cancelled kills the handler and nothing is sent", %{name: name} do
      conn = start(name, protocol: :legacy)
      ready_legacy(name, conn)
      call = pending_call(name, conn)
      {_task, call_id} = call

      server_request(
        conn,
        "s1",
        "sampling/createMessage",
        sampling(%{"systemPrompt" => "block"}),
        call_id
      )

      assert_receive {:sampling, _, _, handler}
      ref = Process.monitor(handler)

      FakeTransport.push(conn, {:notification, "notifications/cancelled", %{"requestId" => "s1"}})
      assert_receive {:DOWN, ^ref, :process, ^handler, _}
      _ = state(conn)
      refute_received {:fake_transport, ^conn, {:respond, %{"id" => "s1"}}}
      assert state(conn).pending[call_id].paused == 0

      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "a crash answers -32603 and a timeout kills the task", %{name: name} do
      conn = start(name, protocol: :legacy, handler_timeout: [sampling: 50])
      ready_legacy(name, conn)
      call = pending_call(name, conn)
      {_task, call_id} = call

      server_request(
        conn,
        1,
        "sampling/createMessage",
        sampling(%{"systemPrompt" => "crash"}),
        call_id
      )

      assert %{"error" => %{"code" => -32_603}} = expect_response(conn, 1)

      server_request(
        conn,
        2,
        "sampling/createMessage",
        sampling(%{"systemPrompt" => "hang"}),
        call_id
      )

      assert_receive {:sampling, _, _, handler}
      ref = Process.monitor(handler)
      assert %{"error" => %{"code" => -32_603, "message" => message}} = expect_response(conn, 2)
      assert message =~ "timed out"
      assert_receive {:DOWN, ^ref, :process, ^handler, _}

      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "undeclared capabilities, modes and bad params are refused", %{name: name} do
      conn = start(name, protocol: :legacy, handler: FormOnly)
      ready_legacy(name, conn)

      server_request(conn, 1, "roots/list", %{})
      assert %{"error" => %{"code" => -32_601}} = expect_response(conn, 1)

      server_request(conn, 2, "elicitation/create", %{
        "mode" => "url",
        "url" => "https://a.example"
      })

      assert %{"error" => %{"code" => -32_602}} = expect_response(conn, 2)

      nested = %{
        "message" => "x",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"o" => %{"type" => "object", "properties" => %{}}}
        }
      }

      server_request(conn, 3, "elicitation/create", nested)
      assert %{"error" => %{"code" => -32_602}} = expect_response(conn, 3)
      refute_received {:elicitation, _, _, _}

      server_request(conn, 4, "tasks/list", %{})
      assert %{"error" => %{"code" => -32_601}} = expect_response(conn, 4)
      assert_no_leaks(name, conn)
    end

    test "form elicitation flags secret-looking fields and validates the answer",
         %{name: name} do
      answer = %{"action" => "accept", "content" => %{"user" => "ada"}}
      conn = start(name, protocol: :legacy, assigns: %{answer: answer})
      ready_legacy(name, conn)

      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{"type" => "string", "maxLength" => 10},
          "password" => %{"type" => "string", "title" => "Password"}
        },
        "required" => ["user"]
      }

      server_request(conn, 1, "elicitation/create", %{
        "message" => "m",
        "requestedSchema" => schema
      })

      assert_receive {:elicitation, _, %{mode: :form, fields: fields}, _}
      assert fields["password"].sensitive_suspected
      refute fields["user"].sensitive_suspected
      assert %{"result" => ^answer} = expect_response(conn, 1)

      schema = put_in(schema, ["required"], ["user", "password"])

      server_request(conn, 2, "elicitation/create", %{
        "message" => "m",
        "requestedSchema" => schema
      })

      assert %{"error" => %{"code" => -32_603}} = expect_response(conn, 2)
      assert_no_leaks(name, conn)
    end

    test "roots are file:// only and canonicalized", %{name: name} do
      roots = [
        %{"uri" => "file:///work/../srv/app", "name" => "app"},
        %{"uri" => "https://example.com/"},
        %{"uri" => "file://remote-host/share"},
        %{"uri" => "file:///srv/app"},
        %{"uri" => "file:///tmp/a%20b"},
        "junk"
      ]

      conn = start(name, protocol: :legacy, assigns: %{roots: roots})
      FakeTransport.push(conn, {:connected, %{}})
      {id, init, _} = expect_request(conn, "initialize")
      assert init["params"]["capabilities"]["roots"] == %{"listChanged" => true}

      reply(conn, id, %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "s"}
      })

      assert :ok = Client.await_ready(name)
      server_request(conn, 1, "roots/list", %{})

      assert %{
               "result" => %{
                 "roots" => [
                   %{"uri" => "file:///srv/app", "name" => "app"},
                   %{"uri" => "file:///tmp/a%20b"}
                 ]
               }
             } = expect_response(conn, 1)

      assert_no_leaks(name, conn)
    end

    test "a stdio-style request without related id is tied to the one call in flight",
         %{name: name} do
      conn = start(name, protocol: :legacy)
      ready_legacy(name, conn)
      call = pending_call(name, conn, assigns: %{test_pid: self(), who: :only})
      {_task, call_id} = call

      server_request(conn, 1, "sampling/createMessage", sampling())
      assert_receive {:sampling, _, %{related_request_id: ^call_id, assigns: %{who: :only}}, _}
      expect_response(conn, 1)
      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end

    test "crash-report state hides the client's and the calls' assigns", %{name: name} do
      conn = start(name, protocol: :legacy, assigns: %{api_key: "client-s3cret"})
      ready_legacy(name, conn)
      call = pending_call(name, conn, assigns: %{token: "call-s3cret"})

      status = conn |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
      refute status =~ "client-s3cret"
      refute status =~ "call-s3cret"

      finish_call(conn, call)
      assert_no_leaks(name, conn)
    end
  end

  describe "notification callbacks" do
    defmodule Listener do
      @behaviour ConduitMcp.Client.Handler

      @impl true
      def handle_notification(method, _params, ctx),
        do: send(ctx_pid(ctx), {:notified, method, self()})

      @impl true
      def handle_log(level, _params, ctx), do: send(ctx_pid(ctx), {:log, level, self()})

      defp ctx_pid(%{client: {_module, _ref, pid}}), do: pid
    end

    test "run outside the connection, logs through handle_log/3" do
      name = {__MODULE__, make_ref(), self()}
      conn = start_client(name, handler: Listener)
      ready_modern(name, conn)

      FakeTransport.push(conn, {:notification, "notifications/message", %{"level" => "info"}})
      FakeTransport.push(conn, {:notification, "notifications/resources/updated", %{}})

      assert_receive {:log, "info", pid}
      assert pid != conn
      assert_receive {:notified, "notifications/resources/updated", ^pid}
    end
  end

  describe "elicitation checks" do
    test "schema subset" do
      assert {:ok, _} =
               Elicitation.check_schema(%{
                 "type" => "object",
                 "properties" => %{
                   "a" => %{"type" => "string", "format" => "email"},
                   "b" => %{"type" => "integer", "minimum" => 1},
                   "c" => %{"type" => "boolean", "default" => true},
                   "d" => %{"type" => "string", "oneOf" => [%{"const" => "x", "title" => "X"}]},
                   "e" => %{"type" => "array", "items" => %{"type" => "string", "enum" => ["p"]}}
                 }
               })

      for bad <- [
            %{"type" => "string", "pattern" => ".*"},
            %{"$ref" => "#/defs/x"},
            %{"type" => "string", "format" => "binary"},
            %{"type" => "array", "items" => %{"type" => "object"}}
          ] do
        assert {:error, _} =
                 Elicitation.check_schema(%{"type" => "object", "properties" => %{"x" => bad}})
      end
    end

    test "urls" do
      assert {:error, _} = Elicitation.check_url("http://example.com", nil)
      assert {:error, _} = Elicitation.check_url("https://user@example.com", nil)
      assert {:error, _} = Elicitation.check_url("file:///etc/passwd", nil)

      assert {:ok, %{origin_mismatch?: false}} =
               Elicitation.check_url("https://Example.com/x", "https://example.com")

      assert {:ok, %{origin_mismatch?: true}} =
               Elicitation.check_url("https://example.com:8443/x", "https://example.com")

      assert {:ok, %{idn?: true}} = Elicitation.check_url("https://xn--bcher-kva.example/", nil)
      assert {:error, _} = Elicitation.check_url("https://bücher.example/", nil)
    end
  end
end

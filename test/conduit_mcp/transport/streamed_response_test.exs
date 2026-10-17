defmodule ConduitMcp.Transport.StreamedResponseTest do
  # Real sockets: Bandit on port 0 and a raw HTTP/1.1 client over `:gen_tcp`,
  # so chunk boundaries, keep-alives and a client closing its socket are the
  # real thing rather than Plug.Test's in-memory adapter.
  #
  # `async: true` is safe: every test starts its own listener, the test pid a
  # tool reports to is keyed by a per-test string, and the only test that
  # occupies a `:conduit_mcp_sse_streams` slot does so from this module, whose
  # tests run sequentially.
  use ExUnit.Case, async: true

  alias ConduitMcp.Transport.SSEStream
  alias ConduitMcp.Transport.StreamableHTTP

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  defmodule StreamServer do
    use ConduitMcp.Server, dsl: false

    alias ConduitMcp.Cancellation

    @impl true
    def handle_list_tools(_conn) do
      tools =
        for name <- ~w(progress log wait until_cancelled ignore_cancel boom) do
          %{"name" => name, "inputSchema" => %{"type" => "object"}}
        end

      {:ok, %{"tools" => tools}}
    end

    @impl true
    def handle_call_tool(conn, "progress", _args) do
      ConduitMcp.Progress.report(conn, 1, total: 2, message: "half")
      ConduitMcp.Progress.report(conn, 2, total: 2)
      text("done")
    end

    def handle_call_tool(conn, "log", _args) do
      ConduitMcp.Log.log(conn, :debug, "below the requested level")
      ConduitMcp.Log.log(conn, :warning, %{"step" => 1}, logger: "test")
      text("logged")
    end

    # Emits nothing: only a keep-alive tick can open the stream.
    def handle_call_tool(_conn, "wait", %{"test" => test}) do
      send(test_pid(test), {:tool_started, self()})

      receive do
        :go -> text("went")
      end
    end

    def handle_call_tool(conn, "until_cancelled", %{"test" => test}) do
      ConduitMcp.Progress.report(conn, 0)
      send(test_pid(test), {:tool_started, self()})
      poll_cancelled(conn, test_pid(test))
    end

    def handle_call_tool(conn, "ignore_cancel", %{"test" => test}) do
      ConduitMcp.Progress.report(conn, 0)
      send(test_pid(test), {:tool_started, self()})

      receive do
        :never -> text("unreachable")
      end
    end

    def handle_call_tool(conn, "boom", _args) do
      ConduitMcp.Progress.report(conn, 1)
      raise "boom"
    end

    defp poll_cancelled(conn, test_pid) do
      if Cancellation.cancelled?(conn) do
        send(test_pid, {:tool_saw_cancel, self()})
        text("cancelled")
      else
        receive do
        after
          5 -> poll_cancelled(conn, test_pid)
        end
      end
    end

    defp test_pid(test), do: :persistent_term.get({__MODULE__, test})

    defp text(text), do: {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  # --- server and client helpers -------------------------------------------

  defp start_server(opts \\ []) do
    opts = Keyword.merge([server_module: StreamServer, allowed_origins: "*"], opts)

    pid =
      start_supervised!(
        {Bandit, plug: {StreamableHTTP, opts}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # A key under which a tool finds this test's pid.
  defp register_test do
    key = "test-#{System.unique_integer([:positive])}"
    :persistent_term.put({StreamServer, key}, self())
    on_exit(fn -> :persistent_term.erase({StreamServer, key}) end)
    key
  end

  defp modern_call(tool, args, meta) do
    request(
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => args, "_meta" => Map.merge(@meta, meta)}
      },
      [{"mcp-protocol-version", @version}, {"mcp-method", "tools/call"}, {"mcp-name", tool}]
    )
  end

  defp modern(method, params \\ %{}) do
    request(
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => Map.put(params, "_meta", @meta)
      },
      [{"mcp-protocol-version", @version}, {"mcp-method", method}]
    )
  end

  defp request(body, headers), do: {JSON.encode!(body), headers}

  defp send_request(port, {json, headers}, extra_headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true])

    headers =
      [
        {"host", "localhost"},
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"content-length", Integer.to_string(byte_size(json))}
        | headers
      ] ++ extra_headers

    head = Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end)
    :ok = :gen_tcp.send(socket, ["POST / HTTP/1.1\r\n", head, "\r\n", json])
    socket
  end

  defp post(port, request, extra_headers \\ []) do
    port
    |> send_request(request, extra_headers)
    |> read_until(&complete?/1)
    |> parse()
  end

  defp read_until(socket, done?, acc \\ "") do
    if done?.(acc) do
      acc
    else
      receive do
        {:tcp, ^socket, data} -> read_until(socket, done?, acc <> data)
        {:tcp_closed, ^socket} -> flunk("connection closed; received: #{inspect(acc)}")
      after
        2_000 -> flunk("timed out; received: #{inspect(acc)}")
      end
    end
  end

  defp complete?(acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        head = String.downcase(head)

        case Regex.run(~r/content-length: (\d+)/, head) do
          [_, length] -> byte_size(body) >= String.to_integer(length)
          nil -> String.contains?(head, "chunked") and String.ends_with?(body, "0\r\n\r\n")
        end

      _ ->
        false
    end
  end

  defp parse(acc) do
    [head, body] = String.split(acc, "\r\n\r\n", parts: 2)
    [status_line | lines] = String.split(head, "\r\n")
    [_http, status | _] = String.split(status_line, " ")

    headers =
      for line <- lines, [k, v] = String.split(line, ": ", parts: 2), do: {String.downcase(k), v}

    body = if chunked?(headers), do: dechunk(body), else: body
    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp chunked?(headers), do: {"transfer-encoding", "chunked"} in headers

  defp header(%{headers: headers}, name), do: for({^name, v} <- headers, do: v)

  # Complete chunks only, so a stream still in progress can be inspected.
  defp dechunk(body, acc \\ "") do
    with [size, rest] <- String.split(body, "\r\n", parts: 2),
         {size, ""} when size > 0 <- Integer.parse(size, 16),
         <<data::binary-size(^size), "\r\n", rest::binary>> <- rest do
      dechunk(rest, acc <> data)
    else
      _ -> acc
    end
  end

  defp received_body(acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [_head, body] -> dechunk(body)
      _ -> ""
    end
  end

  # The JSON-RPC messages of an SSE body, in order.
  defp events(body) do
    for "data: " <> json <- String.split(body, ~r/\r\n|\n/), do: JSON.decode!(json)
  end

  # --- streaming ------------------------------------------------------------

  describe "modern tools/call with a progressToken" do
    test "streams progress notifications, then the result, in order" do
      port = start_server()

      response = post(port, modern_call("progress", %{}, %{"progressToken" => "tok"}))

      assert response.status == 200
      assert [content_type] = header(response, "content-type")
      assert content_type =~ "text/event-stream"
      assert header(response, "x-accel-buffering") == ["no"]
      assert header(response, "cache-control") == ["no-cache"]
      assert header(response, "mcp-protocol-version") == [@version]

      assert [first, second, result] = events(response.body)

      assert %{
               "method" => "notifications/progress",
               "params" => %{
                 "progressToken" => "tok",
                 "progress" => 1,
                 "total" => 2,
                 "message" => "half"
               }
             } = first

      assert %{"method" => "notifications/progress", "params" => %{"progress" => 2}} = second
      refute Map.has_key?(first, "id")

      assert %{
               "id" => 1,
               "result" => %{
                 "resultType" => "complete",
                 "content" => [%{"text" => "done"}]
               }
             } = result
    end

    test "a tool that raises ends the stream with a -32603 response event" do
      port = start_server()

      response = post(port, modern_call("boom", %{}, %{"progressToken" => 7}))

      assert response.status == 200
      assert [progress, error] = events(response.body)
      assert progress["params"]["progressToken"] == 7
      assert %{"id" => 1, "error" => %{"code" => -32_603}} = error
    end

    test "a client that does not accept text/event-stream gets JSON without notifications" do
      port = start_server()
      {json, headers} = modern_call("progress", %{}, %{"progressToken" => "tok"})

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true])

      :ok =
        :gen_tcp.send(socket, [
          "POST / HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\n",
          "accept: application/json\r\ncontent-length: #{byte_size(json)}\r\n",
          Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
          "\r\n",
          json
        ])

      response = socket |> read_until(&complete?/1) |> parse()

      assert response.status == 200
      assert [content_type] = header(response, "content-type")
      assert content_type =~ "application/json"

      assert %{"id" => 1, "result" => %{"content" => [%{"text" => "done"}]}} =
               JSON.decode!(response.body)
    end

    test "at :max_streams the response is sent as JSON, without its notifications" do
      port = start_server(max_streams: 1)
      table = SSEStream.streams_table()
      parent = self()

      holder =
        spawn_link(fn ->
          send(parent, {:held, SSEStream.acquire_slot(table, 1_000)})

          receive do
            :release -> SSEStream.release_slot(table)
          end
        end)

      assert_receive {:held, true}

      response = post(port, modern_call("progress", %{}, %{"progressToken" => "tok"}))

      assert [content_type] = header(response, "content-type")
      assert content_type =~ "application/json"
      assert %{"result" => %{"content" => [%{"text" => "done"}]}} = JSON.decode!(response.body)

      send(holder, :release)
    end
  end

  describe "modern tools/call with a logLevel" do
    test "sends only messages at or above the requested level" do
      port = start_server()

      response =
        post(port, modern_call("log", %{}, %{"io.modelcontextprotocol/logLevel" => "info"}))

      assert [message, result] = events(response.body)

      assert message == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/message",
               "params" => %{"level" => "warning", "data" => %{"step" => 1}, "logger" => "test"}
             }

      assert result["result"]["content"] == [%{"type" => "text", "text" => "logged"}]
    end

    test "without a logLevel no notifications/message is sent, even on a stream" do
      port = start_server()

      # The progressToken makes the call stream-eligible; the tool only logs,
      # so nothing is sent before the result and the reply is plain JSON.
      response = post(port, modern_call("log", %{}, %{"progressToken" => "tok"}))

      assert [content_type] = header(response, "content-type")
      assert content_type =~ "application/json"
      refute response.body =~ "notifications/message"

      assert JSON.decode!(response.body)["result"]["content"] == [
               %{"type" => "text", "text" => "logged"}
             ]
    end
  end

  describe "keep-alive" do
    test "a slow tool's stream carries :\\r\\n keep-alive comments until the result" do
      port = start_server(keep_alive_interval: 20)
      test = register_test()

      socket =
        send_request(port, modern_call("wait", %{"test" => test}, %{"progressToken" => "tok"}))

      assert_receive {:tool_started, tool}, 2_000

      acc = read_until(socket, &String.contains?(received_body(&1), ":\r\n"))
      assert acc =~ "text/event-stream"

      send(tool, :go)

      response = socket |> read_until(&complete?/1, acc) |> parse()
      assert response.body =~ ":\r\n"

      assert [%{"id" => 1, "result" => %{"content" => [%{"text" => "went"}]}}] =
               events(response.body)
    end
  end

  describe "client disconnect" do
    test "cancels the request: the tool observes Cancellation.cancelled?/1 and exits" do
      port = start_server(keep_alive_interval: 20)
      test = register_test()

      socket =
        send_request(
          port,
          modern_call("until_cancelled", %{"test" => test}, %{"progressToken" => "tok"})
        )

      assert_receive {:tool_started, tool}, 2_000
      ref = Process.monitor(tool)

      read_until(socket, &(received_body(&1) =~ "notifications/progress"))
      :ok = :gen_tcp.close(socket)

      assert_receive {:tool_saw_cancel, ^tool}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^tool, _reason}, 2_000
    end

    test "a tool that ignores cancellation is killed after :stream_cancel_timeout" do
      port = start_server(keep_alive_interval: 20, stream_cancel_timeout: 50)
      test = register_test()

      socket =
        send_request(
          port,
          modern_call("ignore_cancel", %{"test" => test}, %{"progressToken" => "tok"})
        )

      assert_receive {:tool_started, tool}, 2_000
      ref = Process.monitor(tool)

      read_until(socket, &(received_body(&1) =~ "notifications/progress"))
      :ok = :gen_tcp.close(socket)

      assert_receive {:DOWN, ^ref, :process, ^tool, :killed}, 2_000
    end
  end

  # --- era wiring -------------------------------------------------------------

  describe "eras on one endpoint" do
    test "a legacy tools/call is still answered with JSON, progressToken or not" do
      port = start_server()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "progress",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "tok"}
        }
      }

      response = post(port, request(body, []))

      assert response.status == 200
      assert [content_type] = header(response, "content-type")
      assert content_type =~ "application/json"
      decoded = JSON.decode!(response.body)
      assert decoded["result"]["content"] == [%{"type" => "text", "text" => "done"}]
      refute Map.has_key?(decoded["result"], "resultType")
    end

    test "a legacy request with an unsupported MCP-Protocol-Version is a 400" do
      port = start_server()

      response =
        post(
          port,
          request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, [
            {"mcp-protocol-version", "2024-01-01"}
          ])
        )

      assert response.status == 400
      assert %{"error" => %{"code" => -32_600}} = JSON.decode!(response.body)
    end

    test "a mismatched MCP-Protocol-Version is a 400 -32020, not counted by :message_rate_limit" do
      key = "streamed-msg-rl-#{System.unique_integer([:positive])}"

      port =
        start_server(
          message_rate_limit: [
            backend: ConduitMcp.TestRateLimiter,
            limit: 1,
            scale: 60_000,
            key_func: fn _conn -> key end
          ]
        )

      {json, _headers} = modern("tools/list")
      mismatched = {json, [{"mcp-protocol-version", "2025-11-25"}, {"mcp-method", "tools/list"}]}

      for _ <- 1..3 do
        response = post(port, mismatched)
        assert response.status == 400
        assert %{"error" => %{"code" => -32_020}} = JSON.decode!(response.body)
      end

      # The limit is 1: had the rejections been counted, this would be a 429.
      allowed = post(port, modern("tools/list"))
      assert allowed.status == 200
      assert header(allowed, "mcp-protocol-version") == [@version]

      assert post(port, modern("tools/list")).status == 429
    end

    test "a modern request never creates or requires a session" do
      port = start_server(session: [require_session: true])

      listed = post(port, modern("tools/list"))
      assert listed.status == 200
      assert header(listed, "mcp-session-id") == []

      # A legacy-only method is unknown to the modern era: 404, no session.
      initialize =
        post(
          port,
          modern("initialize", %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "t", "version" => "1"}
          })
        )

      assert initialize.status == 404
      assert %{"error" => %{"code" => -32_601}} = JSON.decode!(initialize.body)
      assert header(initialize, "mcp-session-id") == []

      # An unknown session id is ignored, not a 404.
      unknown = post(port, modern("tools/list"), [{"mcp-session-id", "no-such-session"}])
      assert unknown.status == 200
    end
  end
end

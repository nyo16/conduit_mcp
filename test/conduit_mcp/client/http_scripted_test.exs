defmodule ConduitMcp.Client.HTTPScriptedTest do
  # The Streamable HTTP client transport against scripted servers
  # (`ConduitMcp.Test.Client.ScriptedServer`) on real sockets, for what this
  # library's own server never does: server requests mid-stream, event ids
  # and resumption, the legacy GET stream, session expiry, refusals and
  # hostile bodies (HT-1..HT-4, HT-14).
  use ExUnit.Case, async: true

  @moduletag :integration

  import ConduitMcp.Test.Client.ScriptedServer,
    only: [
      json: 3,
      json: 4,
      accepted: 1,
      sse: 1,
      event: 2,
      event: 3,
      result: 2,
      error: 3,
      initialize_result: 1,
      initialize_result: 2,
      discover_result: 2,
      text_result: 2,
      header: 2
    ]

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.OAuth.Challenge
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.ScriptedServer

  defmodule Sampler do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_sampling(_params, _ctx) do
      {:ok,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => "sampled"},
         "model" => "test-model"
       }}
    end
  end

  defp start_client(url, opts) do
    name = {__MODULE__, make_ref()}
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])

    start_supervised!(
      {Client,
       Keyword.merge(
         [
           name: name,
           transport: {StreamableHTTP, [url: url] ++ transport_opts},
           backoff: fn _attempt -> 0 end
         ],
         opts
       )}
    )

    name
  end

  defp ready(url, opts) do
    name = start_client(url, opts)
    assert :ok = Client.await_ready(name, 2_000)
    name
  end

  defp tstate(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {_state, data} = :sys.get_state(conn)
    data.tstate
  end

  # A legacy server: sessions, no GET stream, 202 for notifications and
  # responses; `calls` answers everything else.
  defp legacy(calls, opts \\ []) do
    sid = Keyword.get(opts, :sid, fn -> "sid-#{System.unique_integer([:positive])}" end)
    capabilities = Keyword.get(opts, :capabilities, %{"tools" => %{}})

    fn conn, message ->
      case {conn.method, message} do
        {"POST", %{"method" => "initialize"} = request} ->
          json(conn, 200, initialize_result(request, capabilities), [{"mcp-session-id", sid.()}])

        {"POST", %{"method" => "notifications/" <> _}} ->
          accepted(conn)

        {"POST", %{"id" => _, "result" => _}} ->
          accepted(conn)

        {"GET", nil} ->
          if header(conn, "last-event-id"),
            do: calls.(conn, message),
            else: Plug.Conn.send_resp(conn, 405, "")

        {"DELETE", nil} ->
          Plug.Conn.send_resp(conn, 200, "")

        _other ->
          calls.(conn, message)
      end
    end
  end

  # A modern server: `server/discover`; `calls` answers everything else.
  defp modern(calls, capabilities \\ %{"tools" => %{}}) do
    fn conn, message ->
      case message do
        %{"method" => "server/discover"} = request ->
          json(conn, 200, discover_result(request, capabilities))

        _other ->
          calls.(conn, message)
      end
    end
  end

  # --- legacy streams ------------------------------------------------------------

  test "a legacy SSE response carries a sampling request; the handler's answer is POSTed with the session" do
    test = self()

    url =
      ScriptedServer.start(
        legacy(
          fn conn, %{"method" => "tools/call"} = request ->
            conn = sse(conn)

            conn =
              event(conn, %{
                "jsonrpc" => "2.0",
                "id" => "s-1",
                "method" => "sampling/createMessage",
                "params" => %{
                  "messages" => [
                    %{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}
                  ],
                  "maxTokens" => 5
                }
              })

            send(test, {:stream_waiting, self()})

            receive do
              :continue -> event(conn, text_result(request, "after sampling"))
            end
          end,
          sid: fn -> "session-A" end
        )
      )

    name = ready(url, protocol: :legacy, handler: Sampler)
    task = Task.async(fn -> Client.call_tool(name, "t", %{}) end)

    assert_receive {:stream_waiting, stream}, 2_000
    assert_receive {:scripted, :response, headers, %{"id" => "s-1", "result" => sampled}}, 2_000
    assert {"mcp-session-id", "session-A"} in headers
    assert {"mcp-protocol-version", "2025-11-25"} in headers
    assert sampled["content"]["text"] == "sampled"

    send(stream, :continue)
    assert {:ok, %ToolResult{content: [%{"text" => "after sampling"}]}} = Task.await(task)
  end

  test "a legacy stream that drops after an event id is resumed with GET Last-Event-ID after retry" do
    url =
      ScriptedServer.start(
        legacy(fn
          %{method: "POST"} = conn, %{"method" => "tools/call"} = request ->
            :persistent_term.put({__MODULE__, :resume, header(conn, "mcp-session-id")}, request)

            conn
            |> sse()
            |> event(
              %{
                "jsonrpc" => "2.0",
                "method" => "notifications/message",
                "params" => %{"level" => "info", "data" => "x"}
              },
              id: "e-1",
              retry: 10
            )

          %{method: "GET"} = conn, nil ->
            key = {__MODULE__, :resume, header(conn, "mcp-session-id")}
            request = :persistent_term.get(key)
            :persistent_term.erase(key)
            "e-1" = header(conn, "last-event-id")
            conn |> sse() |> event(text_result(request, "resumed"), id: "e-2")
        end)
      )

    name = ready(url, protocol: :legacy)

    assert {:ok, %ToolResult{content: [%{"text" => "resumed"}]}} =
             Client.call_tool(name, "t", %{})

    # The session's own GET stream (no Last-Event-ID, refused) and the resume.
    gets = collect_gets([])
    resume = Enum.find(gets, &List.keymember?(&1, "last-event-id", 0))
    assert {"last-event-id", "e-1"} in resume
    assert {"accept", "text/event-stream"} in resume
    assert List.keymember?(resume, "mcp-session-id", 0)
  end

  defp collect_gets(acc) do
    receive do
      {:scripted, "GET", headers, nil} -> collect_gets([headers | acc])
    after
      0 -> acc
    end
  end

  test "the legacy GET stream delivers notifications and server requests" do
    test = self()

    url =
      ScriptedServer.start(fn conn, message ->
        case {conn.method, message} do
          {"POST", %{"method" => "initialize"} = request} ->
            json(conn, 200, initialize_result(request), [{"mcp-session-id", "g-1"}])

          {"POST", %{"method" => "notifications/initialized"}} ->
            accepted(conn)

          {"POST", %{"id" => "ping-1"}} ->
            send(test, {:ping_answered, message})
            accepted(conn)

          {"DELETE", nil} ->
            Plug.Conn.send_resp(conn, 200, "")

          {"GET", nil} ->
            conn = sse(conn)

            conn =
              event(conn, %{
                "jsonrpc" => "2.0",
                "method" => "notifications/resources/updated",
                "params" => %{"uri" => "file:///a"}
              })

            conn = event(conn, %{"jsonrpc" => "2.0", "id" => "ping-1", "method" => "ping"})
            drip_until_closed(conn, test, ": keep-alive\n\n")
        end
      end)

    name = start_client(url, protocol: :legacy)
    :ok = Client.subscribe_notifications(name)
    assert :ok = Client.await_ready(name, 2_000)

    assert_receive {:mcp_notification, ^name, "notifications/resources/updated",
                    %{"uri" => "file:///a"}},
                   2_000

    assert_receive {:ping_answered, %{"result" => %{}}}, 2_000
  end

  test "a GET answered 405, or 200 without an event stream, turns the legacy GET stream off" do
    for answer <- [405, 200] do
      base = legacy(fn conn, _message -> conn end)

      url =
        ScriptedServer.start(fn
          %{method: "GET"} = conn, nil when answer == 200 -> json(conn, 200, %{"info" => true})
          conn, message -> base.(conn, message)
        end)

      name = ready(url, protocol: :legacy)
      assert_receive {:scripted, "GET", _headers, nil}, 2_000
      wait_until(fn -> tstate(name).listener == :disabled end)
      refute_receive {:scripted, "GET", _headers, nil}, 200
    end
  end

  test "DELETE ends a legacy session on close; a 405 is fine" do
    url =
      ScriptedServer.start(fn conn, message ->
        case {conn.method, message} do
          {"POST", %{"method" => "initialize"} = request} ->
            json(conn, 200, initialize_result(request), [{"mcp-session-id", "d-1"}])

          {"POST", _notification} ->
            accepted(conn)

          {"GET", nil} ->
            Plug.Conn.send_resp(conn, 405, "")

          {"DELETE", nil} ->
            Plug.Conn.send_resp(conn, 405, "")
        end
      end)

    name = ready(url, protocol: :legacy)
    assert :ok = Client.close(name)
    assert_received {:scripted, "DELETE", headers, nil}
    assert {"mcp-session-id", "d-1"} in headers
  end

  test "a 404 to a request with a session re-initializes without it and re-sends the request once" do
    counter = :counters.new(1, [])

    url =
      ScriptedServer.start(
        legacy(
          fn conn, %{"method" => "tools/call"} = request ->
            case header(conn, "mcp-session-id") do
              "s-1" -> Plug.Conn.send_resp(conn, 404, "")
              "s-2" -> json(conn, 200, text_result(request, "renewed"))
            end
          end,
          sid: fn ->
            :counters.add(counter, 1, 1)
            "s-#{:counters.get(counter, 1)}"
          end
        )
      )

    name = ready(url, protocol: :legacy)

    assert {:ok, %ToolResult{content: [%{"text" => "renewed"}]}} =
             Client.call_tool(name, "t", %{})

    assert_received {:scripted, "initialize", first, _}
    refute List.keymember?(first, "mcp-session-id", 0)
    assert_received {:scripted, "initialize", second, _}
    refute List.keymember?(second, "mcp-session-id", 0)
    assert :counters.get(counter, 1) == 2
  end

  test "a request whose re-sent copy also gets 404 fails with :session_expired" do
    url =
      ScriptedServer.start(
        legacy(fn conn, %{"method" => "tools/call"} -> Plug.Conn.send_resp(conn, 404, "") end)
      )

    name = ready(url, protocol: :legacy)
    assert {:error, %Error{kind: :session_expired}} = Client.call_tool(name, "t", %{})
  end

  test "legacy cancel POSTs notifications/cancelled, then closes the stream" do
    test = self()

    url =
      ScriptedServer.start(
        legacy(fn conn, %{"method" => "tools/call"} ->
          conn = sse(conn)
          send(test, {:streaming, self()})
          drip_until_closed(conn, test, ": keep-alive\n\n")
        end)
      )

    name = ready(url, protocol: :legacy)
    assert {:error, %Error{kind: :timeout}} = Client.call_tool(name, "t", %{}, timeout: 200)
    assert_receive {:scripted, "notifications/cancelled", _headers, %{"params" => params}}, 2_000
    assert %{"requestId" => id, "reason" => "timeout"} = params
    assert is_integer(id)
    assert_receive {:closed, _stream}, 2_000
  end

  # --- refusals ------------------------------------------------------------------

  test "401 fails with kind: :auth and the parsed challenge" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          json(conn, 401, %{}, [
            {"www-authenticate",
             ~s(Bearer resource_metadata="https://rs.example/.well-known/oauth-protected-resource", scope="tools")}
          ])
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :auth, reason: :unauthorized, data: data}} =
             Client.call_tool(name, "t", %{})

    assert %{status: 401, challenges: [%Challenge{scheme: "bearer"} = challenge]} = data
    assert Challenge.resource_metadata(challenge) =~ "oauth-protected-resource"
  end

  test "a 401 to the handshake closes the client with kind: :auth, probing or pinned" do
    url =
      ScriptedServer.start(fn conn, _message ->
        json(conn, 401, %{}, [{"www-authenticate", ~s(Bearer realm="mcp")}])
      end)

    for protocol <- [:auto, :modern, :legacy] do
      name = start_client(url, protocol: protocol)

      assert {:error, %Error{kind: :closed, data: %Error{kind: :auth}}} =
               Client.await_ready(name, 2_000),
             inspect(protocol)
    end
  end

  test "403 insufficient_scope fails with kind: :auth, reason :insufficient_scope" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          json(conn, 403, %{}, [
            {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="admin")}
          ])
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :auth, reason: :insufficient_scope, data: %{status: 403}}} =
             Client.call_tool(name, "t", %{})
  end

  test "429 fails with kind: :rate_limited carrying retry-after" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          json(conn, 429, %{}, [{"retry-after", "7"}])
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :rate_limited, data: %{retry_after: 7}}} =
             Client.call_tool(name, "t", %{})
  end

  test "modern JSON-RPC error bodies at 400 and 404 are typed protocol errors" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call", "params" => %{"name" => name}} = request ->
          case name do
            "bad" -> json(conn, 400, error(request, -32602, "Invalid params"))
            "gone" -> json(conn, 404, error(request, -32601, "Method not found"))
          end
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, -32602}}} =
             Client.call_tool(name, "bad", %{})

    assert {:error, %Error{kind: :protocol, reason: {:jsonrpc, -32601}}} =
             Client.call_tool(name, "gone", %{})
  end

  test "modern requests carry MCP-Protocol-Version, Mcp-Method and Mcp-Name" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} = request ->
          json(conn, 200, text_result(request, "ok"))
        end)
      )

    name = ready(url, protocol: :modern)
    assert {:ok, %ToolResult{}} = Client.call_tool(name, "my tool", %{})

    assert_received {:scripted, "tools/call", headers, _}
    assert {"mcp-protocol-version", "2026-07-28"} in headers
    assert {"mcp-method", "tools/call"} in headers
    assert {"mcp-name", "my tool"} in headers
    assert {"accept", "application/json, text/event-stream"} in headers
    assert {"accept-encoding", "identity"} in headers
    refute List.keymember?(headers, "mcp-session-id", 0)
  end

  test "a modern stream that ends without its response fails with :stream_closed and is not replayed" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          conn
          |> sse()
          |> event(
            %{
              "jsonrpc" => "2.0",
              "method" => "notifications/message",
              "params" => %{"level" => "info", "data" => "x"}
            },
            id: "1"
          )
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :transport, reason: :stream_closed}} =
             Client.call_tool(name, "t", %{})

    assert_received {:scripted, "tools/call", _headers, _}
    refute_received {:scripted, "GET", _headers, _}
    refute_received {:scripted, "tools/call", _headers, _}
  end

  test "5xx fails with kind: :transport" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} -> Plug.Conn.send_resp(conn, 503, "") end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :transport, reason: {:http_status, 503}}} =
             Client.call_tool(name, "t", %{})
  end

  test "a modern listen silent past listen_idle_timeout is dropped and reopened" do
    test = self()

    url =
      ScriptedServer.start(
        modern(
          fn conn, %{"method" => "subscriptions/listen", "id" => id} = request ->
            send(test, {:listen, request["params"]["notifications"], header(conn, "mcp-method")})

            conn
            |> sse()
            |> event(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/subscriptions/acknowledged",
              "params" => %{
                "notifications" => %{"toolsListChanged" => true},
                "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
              }
            })
            |> silent_then_probe(test, 1_000)
          end,
          %{"tools" => %{"listChanged" => true}}
        )
      )

    name = ready(url, protocol: :modern, transport_opts: [listen_idle_timeout: 200])
    :ok = Client.subscribe_notifications(name)

    assert_receive {:listen, %{"toolsListChanged" => true}, "subscriptions/listen"}, 2_000
    assert_receive {:closed, _stream}, 2_000
    assert_receive {:listen, %{"toolsListChanged" => true}, _}, 2_000
  end

  # --- hostile bodies (HT-1, HT-2, HT-3) -----------------------------------------

  # 50 MiB of zeros, about 50 KB gzipped; built once, at compile time.
  @bomb :zlib.gzip(:binary.copy(<<0>>, 50 * 1024 * 1024))

  test "HT-1: a gzip body is never inflated" do
    bomb = @bomb

    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, bomb)
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :transport, reason: {:unsupported_content_encoding, "gzip"}}} =
             Client.call_tool(name, "t", %{})
  end

  test "HT-1: an application/zip body is never unpacked, even when it holds a valid answer" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} = request ->
          answer = JSON.encode!(text_result(request, "unpacked"))

          {:ok, {_name, zip}} =
            :zip.create(~c"answer.zip", [{~c"answer.json", answer}], [:memory])

          conn
          |> Plug.Conn.put_resp_content_type("application/zip")
          |> Plug.Conn.send_resp(200, zip)
        end)
      )

    name = ready(url, protocol: :modern)

    assert {:error, %Error{kind: :transport, reason: {:unexpected_status, 200}}} =
             Client.call_tool(name, "t", %{})
  end

  test "HT-2: a JSON body over 8 MiB fails with :message_too_large" do
    big = :binary.copy("x", 9 * 1024 * 1024)

    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} = request ->
          json(conn, 200, text_result(request, big))
        end)
      )

    name = ready(url, protocol: :modern)
    assert {:error, %Error{kind: :message_too_large}} = Client.call_tool(name, "t", %{})
  end

  test "HT-2: a 9 MiB event across many data: lines fails with :message_too_large" do
    line = "data: " <> :binary.copy("y", 1023) <> "\n"

    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          conn = sse(conn)

          Enum.reduce_while(1..(9 * 1024), conn, fn _i, conn ->
            case Plug.Conn.chunk(conn, line) do
              {:ok, conn} -> {:cont, conn}
              {:error, _closed} -> {:halt, conn}
            end
          end)
        end)
      )

    name = ready(url, protocol: :modern)
    assert {:error, %Error{kind: :message_too_large}} = Client.call_tool(name, "t", %{})
  end

  test "HT-3: a body dripping one byte per 100 ms times out at the deadline and the socket closes" do
    test = self()

    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_chunked(200)

          drip_until_closed(conn, test, "{")
        end)
      )

    name = ready(url, protocol: :modern)
    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :timeout}} = Client.call_tool(name, "t", %{}, timeout: 1_000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 1_000 and elapsed < 1_600
    assert_receive {:closed, _stream}, 2_000
  end

  test "HT-3: a legacy call past its deadline is cancelled with notifications/cancelled" do
    test = self()

    url =
      ScriptedServer.start(
        legacy(fn conn, %{"method" => "tools/call"} ->
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_chunked(200)

          drip_until_closed(conn, test, " ")
        end)
      )

    name = ready(url, protocol: :legacy)
    assert {:error, %Error{kind: :timeout}} = Client.call_tool(name, "t", %{}, timeout: 500)
    assert_receive {:scripted, "tools/call", _headers, %{"id" => id}}

    assert_receive {:scripted, "notifications/cancelled", _headers,
                    %{"params" => %{"requestId" => ^id, "reason" => "timeout"}}},
                   2_000

    assert_receive {:closed, _stream}, 2_000
  end

  test "HT-2/HT-3: keep-alive comments do not extend the deadline" do
    test = self()

    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/call"} ->
          drip_until_closed(sse(conn), test, ": keep-alive\n\n")
        end)
      )

    name = ready(url, protocol: :modern)
    assert {:error, %Error{kind: :timeout}} = Client.call_tool(name, "t", %{}, timeout: 300)
    assert_receive {:closed, _stream}, 2_000
  end

  # Silent for `ms`, then writes until the write fails (the first write
  # after the peer closed may still succeed), reporting `{:closed, pid}`.
  defp silent_then_probe(conn, test, ms) do
    receive do
    after
      ms -> drip_until_closed(conn, test, ": probe\n\n")
    end
  end

  defp drip_until_closed(conn, test, bytes) do
    case Plug.Conn.chunk(conn, bytes) do
      {:ok, conn} ->
        receive do
        after
          100 -> drip_until_closed(conn, test, bytes)
        end

      {:error, _reason} ->
        send(test, {:closed, self()})
        conn
    end
  end

  # --- redirects (HT-4) ------------------------------------------------------------

  test "HT-4: a cross-host redirect fails and the other host is never contacted" do
    test = self()
    other_hits = :counters.new(1, [])

    other =
      ScriptedServer.start(fn conn, _message ->
        :counters.add(other_hits, 1, 1)
        send(test, {:other_host_hit, conn.req_headers})
        json(conn, 200, %{})
      end)

    for status <- [302, 307] do
      url =
        ScriptedServer.start(
          modern(fn conn, %{"method" => "tools/call"} ->
            conn
            |> Plug.Conn.put_resp_header("location", other)
            |> Plug.Conn.send_resp(status, "")
          end)
        )

      name =
        ready(url,
          protocol: :modern,
          transport_opts: [redirect: :same_origin, auth: {:bearer, "tok"}]
        )

      assert {:error, %Error{kind: :transport, reason: {:redirect_refused, ^status}}} =
               Client.call_tool(name, "t", %{})
    end

    assert :counters.get(other_hits, 1) == 0
  end

  test "HT-4: a same-origin 307 is followed only when asked, carrying the token" do
    handler =
      modern(fn conn, %{"method" => "tools/call"} = request ->
        case conn.request_path do
          "/" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/moved")
            |> Plug.Conn.send_resp(307, "")

          "/moved" ->
            json(conn, 200, text_result(request, "moved"))
        end
      end)

    url = ScriptedServer.start(handler)

    followed =
      ready(url,
        protocol: :modern,
        transport_opts: [redirect: :same_origin, auth: {:bearer, "tok"}]
      )

    assert {:ok, %ToolResult{content: [%{"text" => "moved"}]}} =
             Client.call_tool(followed, "t", %{})

    assert_received {:scripted, "tools/call", first, _}
    assert_received {:scripted, "tools/call", second, _}
    assert {"authorization", "Bearer tok"} in first
    assert {"authorization", "Bearer tok"} in second

    refused = ready(url, protocol: :modern)

    assert {:error, %Error{reason: {:redirect_refused, 307}}} =
             Client.call_tool(refused, "t", %{})
  end

  # --- pagination (HT-10) ---------------------------------------------------------------

  test "HT-10: a tools/list cursor that repeats fails with :pagination_cycle" do
    url =
      ScriptedServer.start(
        modern(fn conn, %{"method" => "tools/list"} = request ->
          json(
            conn,
            200,
            result(request, %{
              "tools" => [],
              "nextCursor" => "same",
              "ttlMs" => 0,
              "cacheScope" => "public"
            })
          )
        end)
      )

    name = ready(url, protocol: :modern)
    assert {:error, %Error{kind: :pagination_cycle}} = Client.list_all_tools(name)
  end

  # --- session ids (HT-14) ---------------------------------------------------------------

  for {label, sid} <- [
        {"a space", "bad id"},
        {"a tab", "bad\tid"},
        {"a non-ASCII character", "sésame"},
        {"more than 1 KiB", String.duplicate("a", 1_025)}
      ] do
    @sid sid
    test "HT-14: a session id with #{label} is refused" do
      sid = @sid

      url =
        ScriptedServer.start(fn conn, %{"method" => "initialize"} = request ->
          json(conn, 200, initialize_result(request), [{"mcp-session-id", sid}])
        end)

      name = start_client(url, protocol: :legacy)

      assert {:error, %Error{kind: :closed, reason: :invalid_session_id}} =
               Client.await_ready(name, 2_000)
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          10 -> wait_until(fun, tries - 1)
        end
    end
  end
end

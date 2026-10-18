defmodule ConduitMcp.Transport.SubscriptionsListenTest do
  # Real sockets: Bandit on port 0 and a raw HTTP/1.1 client over `:gen_tcp`,
  # as in `ConduitMcp.Transport.StreamedResponseTest`.
  #
  # `async: false`: unauthenticated listens are capped per client address, and
  # every test here connects from 127.0.0.1; `:max_streams` slots are shared
  # node-wide; and the telemetry handlers below see every subscription event.
  # Running alone keeps all three this module's own.
  use ExUnit.Case, async: false

  alias ConduitMcp.Ext.Tasks
  alias ConduitMcp.Subscriptions
  alias ConduitMcp.Test.McpSchema
  alias ConduitMcp.Transport.SSEStream
  alias ConduitMcp.Transport.StreamableHTTP

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }
  @subscription_id "io.modelcontextprotocol/subscriptionId"
  @tasks_meta Map.put(@meta, "io.modelcontextprotocol/clientCapabilities", %{
                "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
              })
  @ext_schema "ext-tasks-2026-07-28"

  defmodule ListenServer do
    use ConduitMcp.Server

    tool "echo", "Echo" do
      handle(fn _conn, _params -> text("ok") end)
    end

    tool "slow", "Runs as an Ext.Tasks task" do
      handle(fn _conn, _params -> {:task, status_message: "Queued"} end)
    end

    prompt "greet", "Greet" do
      get(fn _conn, _args -> [user("hi")] end)
    end

    resource "open://{id}" do
      read(fn _conn, _params, _opts -> text("open") end)
    end

    resource "vault://{id}" do
      scope("vault:read")
      read(fn _conn, _params, _opts -> text("secret") end)
    end
  end

  @rsa_key JOSE.JWK.generate_key({:rsa, 2048})
  @rsa_private @rsa_key |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "k1")
  @rsa_public @rsa_key
              |> JOSE.JWK.to_public()
              |> JOSE.JWK.to_map()
              |> elem(1)
              |> Map.put("kid", "k1")

  @doc false
  def forward_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  setup do
    id = "listen-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [[:conduit_mcp, :subscription, :start], [:conduit_mcp, :subscription, :stop]],
        &__MODULE__.forward_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    # The previous test's streams died with its listener; let the registry
    # drop their entries before this test counts listens per address.
    sync_registry()
    :ok
  end

  # --- server and client helpers -------------------------------------------

  # A short keep-alive: a stream notices its client closed only on its next
  # write, and the listener's shutdown at the end of a test waits for it.
  defp start_server(opts \\ []) do
    opts =
      Keyword.merge(
        [server_module: ListenServer, allowed_origins: "*", keep_alive_interval: 20],
        opts
      )

    pid =
      start_supervised!(
        {Bandit, plug: {StreamableHTTP, opts}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp listen_request(id, notifications, meta \\ @meta) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "subscriptions/listen",
      "params" => %{"_meta" => meta, "notifications" => notifications}
    }

    {JSON.encode!(body),
     [{"mcp-protocol-version", @version}, {"mcp-method", "subscriptions/listen"}]}
  end

  defp send_request(port, {json, headers}, extra_headers \\ [], accept \\ nil) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true])

    headers =
      [
        {"host", "localhost"},
        {"content-type", "application/json"},
        {"accept", accept || "application/json, text/event-stream"},
        {"content-length", Integer.to_string(byte_size(json))}
        | headers
      ] ++ extra_headers

    head = Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end)
    :ok = :gen_tcp.send(socket, ["POST / HTTP/1.1\r\n", head, "\r\n", json])
    socket
  end

  # Opens a listen stream and reads up to its acknowledgment.
  defp listen(port, id, notifications, extra_headers \\ [], meta \\ @meta) do
    socket = send_request(port, listen_request(id, notifications, meta), extra_headers)
    {acc, [ack]} = await_events(socket, "", 1)
    {socket, acc, ack}
  end

  defp await_events(socket, acc, count, timeout \\ 2_000) do
    acc = read_until(socket, &(length(events(received_body(&1))) >= count), acc, timeout)
    {acc, events(received_body(acc))}
  end

  defp read_until(socket, done?, acc, timeout \\ 2_000) do
    if done?.(acc) do
      acc
    else
      receive do
        {:tcp, ^socket, data} -> read_until(socket, done?, acc <> data, timeout)
        {:tcp_closed, ^socket} -> flunk("connection closed; received: #{inspect(acc)}")
      after
        timeout -> flunk("timed out; received: #{inspect(acc)}")
      end
    end
  end

  defp post(port, request, extra_headers \\ [], accept \\ nil) do
    port
    |> send_request(request, extra_headers, accept)
    |> read_until(&complete?/1, "")
    |> parse()
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

    body = if {"transfer-encoding", "chunked"} in headers, do: dechunk(body), else: body
    %{status: String.to_integer(status), headers: headers, body: body}
  end

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

  defp events(body) do
    for "data: " <> json <- String.split(body, ~r/\r\n|\n/), do: JSON.decode!(json)
  end

  defp unique_uri, do: "open://#{System.unique_integer([:positive])}"

  # The one stream subscribed to `uri` (a per-test unique topic).
  defp stream_pid(uri) do
    assert [pid] = Subscriptions.subscribers({:resource, uri})
    pid
  end

  # The registry drops a dead registrant's entries when its partition
  # processes the exit signal; a round trip through every partition after
  # the DOWN orders this test after that.
  defp sync_registry do
    for {_id, pid, _type, _modules} <- Supervisor.which_children(Subscriptions),
        is_pid(pid),
        do: :sys.get_state(pid)
  end

  defp function_auth, do: [strategy: :function, verify: fn token -> {:ok, token} end]

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  defp oauth_token(exp, scope) do
    claims = %{
      "iss" => "https://auth.example.com",
      "aud" => "https://mcp.example.com",
      "sub" => "user-1",
      "exp" => exp,
      "scope" => scope
    }

    {:ok, token, _} = Joken.encode_and_sign(claims, Joken.Signer.create("RS256", @rsa_private))
    token
  end

  defp golden!(name, message), do: assert(:ok = McpSchema.validate(@version, name, message))

  # --- acknowledgment ---------------------------------------------------------

  describe "acknowledgment" do
    test "is the first message and echoes only the honoured subset" do
      port = start_server()

      {socket, acc, ack} =
        listen(port, "a-1", %{
          "toolsListChanged" => true,
          "promptsListChanged" => false,
          "resourcesListChanged" => true,
          "resourceSubscriptions" => ["open://1", "vault://secret", "open://1"],
          "tasks" => %{"unknown" => true},
          # Ext.Tasks is off: `taskIds` is an unknown field.
          "taskIds" => ["some-task"]
        })

      assert acc =~ ~r/content-type: text\/event-stream/i
      assert acc =~ ~r/x-accel-buffering: no/i

      assert ack == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/subscriptions/acknowledged",
               "params" => %{
                 "_meta" => %{@subscription_id => "a-1"},
                 "notifications" => %{
                   "toolsListChanged" => true,
                   "resourcesListChanged" => true,
                   "resourceSubscriptions" => ["open://1"]
                 }
               }
             }

      golden!("SubscriptionsAcknowledgedNotification", ack)

      assert_receive {:telemetry, [:conduit_mcp, :subscription, :start], measurements, metadata}
      assert measurements.resource_subscriptions == 1

      assert metadata == %{
               filters: [:tools_list_changed, :resources_list_changed, :resource_subscriptions],
               server_module: ListenServer
             }

      :gen_tcp.close(socket)
    end

    test "an invalid filter is a plain -32602, no stream" do
      port = start_server()

      response =
        post(
          port,
          listen_request(1, %{"resourceSubscriptions" => List.duplicate("open://x", 1001)})
        )

      assert response.status == 200
      assert %{"id" => 1, "error" => %{"code" => -32602}} = JSON.decode!(response.body)
      refute_received {:telemetry, [:conduit_mcp, :subscription, :start], _, _}
    end

    test "without text/event-stream in Accept is 406" do
      port = start_server()

      response =
        post(port, listen_request(1, %{"toolsListChanged" => true}), [], "application/json")

      assert response.status == 406
      assert %{"id" => 1, "error" => %{"code" => -32600}} = JSON.decode!(response.body)
    end
  end

  # --- delivery -------------------------------------------------------------

  describe "delivery" do
    test "reaches only streams that asked, each tagged with its listen id" do
      port = start_server()
      tools_uri = unique_uri()
      prompts_uri = unique_uri()

      {tools, tools_acc, _ack} =
        listen(port, "tools-listener", %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => [tools_uri]
        })

      {prompts, prompts_acc, _ack} =
        listen(port, 7, %{
          "promptsListChanged" => true,
          "resourceSubscriptions" => [prompts_uri]
        })

      assert :ok = ConduitMcp.notify_tools_changed()
      assert :ok = ConduitMcp.notify_prompts_changed()

      {_acc, [_ack, tools_changed]} = await_events(tools, tools_acc, 2)
      {_acc, [_ack, prompts_changed]} = await_events(prompts, prompts_acc, 2)

      assert tools_changed == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/tools/list_changed",
               "params" => %{"_meta" => %{@subscription_id => "tools-listener"}}
             }

      # The prompts-only listener's first notification is the prompts one:
      # the tools notification, published first, never reached it.
      assert prompts_changed == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/prompts/list_changed",
               "params" => %{"_meta" => %{@subscription_id => 7}}
             }

      golden!("ToolListChangedNotification", tools_changed)
      golden!("PromptListChangedNotification", prompts_changed)

      :gen_tcp.close(tools)
      :gen_tcp.close(prompts)
    end

    test "resource updates are filtered by uri and by scope" do
      port = start_server(auth: function_auth())
      uri = unique_uri()

      {socket, acc, ack} =
        listen(
          port,
          "res",
          %{"resourceSubscriptions" => [uri, "vault://secret"]},
          bearer("res-user")
        )

      # The caller holds no `vault:read`: the URI is silently absent.
      assert ack["params"]["notifications"] == %{"resourceSubscriptions" => [uri]}
      assert Subscriptions.subscribers({:resource, "vault://secret"}) == []

      ConduitMcp.notify_resource_updated("vault://secret")
      ConduitMcp.notify_resource_updated(uri <> "/child")
      ConduitMcp.notify_resource_updated(uri)

      {_acc, [_ack, updated]} = await_events(socket, acc, 2)

      assert updated == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/resources/updated",
               "params" => %{"uri" => uri, "_meta" => %{@subscription_id => "res"}}
             }

      golden!("ResourceUpdatedNotification", updated)
      :gen_tcp.close(socket)
    end

    test "the stream carries :\\r\\n keep-alives" do
      port = start_server(keep_alive_interval: 10)
      {socket, acc, _ack} = listen(port, 1, %{"toolsListChanged" => true})

      acc = read_until(socket, &String.contains?(received_body(&1), ":\r\n"), acc)
      assert received_body(acc) =~ ":\r\n"
      :gen_tcp.close(socket)
    end
  end

  # --- server-side closure ------------------------------------------------------

  describe "graceful server-side closure" do
    test "at :max_stream_lifetime: notifications/cancelled, then the result, then close" do
      port = start_server(max_stream_lifetime: 50, keep_alive_interval: 10)

      response =
        port
        |> send_request(listen_request("life", %{"toolsListChanged" => true}))
        |> read_until(&complete?/1, "")
        |> parse()

      assert [ack, cancelled, result] = events(response.body)
      assert ack["method"] == "notifications/subscriptions/acknowledged"

      assert cancelled == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/cancelled",
               "params" => %{
                 "requestId" => "life",
                 "reason" => "Maximum stream lifetime reached",
                 "_meta" => %{@subscription_id => "life"}
               }
             }

      assert %{
               "jsonrpc" => "2.0",
               "id" => "life",
               "result" => %{
                 "resultType" => "complete",
                 "_meta" => %{@subscription_id => "life"} = meta
               }
             } = result

      assert Map.has_key?(meta, "io.modelcontextprotocol/serverInfo")

      golden!("CancelledNotification", cancelled)
      golden!("SubscriptionsListenResultResponse", result)

      assert_receive {:telemetry, [:conduit_mcp, :subscription, :stop], %{duration: duration},
                      %{reason: :max_lifetime} = metadata}

      assert is_integer(duration)
      assert Map.keys(metadata) |> Enum.sort() == [:filters, :reason, :server_module]
    end

    test "after :listen_idle_timeout without a notification" do
      port = start_server(listen_idle_timeout: 30, keep_alive_interval: 10)

      response =
        port
        |> send_request(listen_request(2, %{"toolsListChanged" => true}))
        |> read_until(&complete?/1, "")
        |> parse()

      assert [_ack, cancelled, %{"id" => 2, "result" => %{"resultType" => "complete"}}] =
               events(response.body)

      assert cancelled["params"]["reason"] == "Subscription idle timeout"

      assert_receive {:telemetry, [:conduit_mcp, :subscription, :stop], _,
                      %{reason: :idle_timeout}}
    end

    test "at the bearer token's exp (SV-3), with an authorized scoped uri honoured" do
      port =
        start_server(
          keep_alive_interval: 20,
          auth: [
            strategy: :oauth,
            issuer: "https://auth.example.com",
            audience: "https://mcp.example.com",
            key_provider: {ConduitMcp.OAuth.KeyProvider.Static, keys: [@rsa_public]}
          ]
        )

      # `exp` has one-second resolution: +2 so the token is still valid when
      # the plug checks it, closing the stream one to two seconds from now.
      token = oauth_token(System.system_time(:second) + 2, "vault:read")

      socket =
        send_request(
          port,
          listen_request(3, %{"resourceSubscriptions" => ["vault://secret"]}),
          bearer(token)
        )

      response = socket |> read_until(&complete?/1, "", 4_000) |> parse()

      assert [ack, cancelled, %{"id" => 3, "result" => _}] = events(response.body)
      assert ack["params"]["notifications"] == %{"resourceSubscriptions" => ["vault://secret"]}
      assert cancelled["params"]["reason"] == "Access token expired"

      assert_receive {:telemetry, [:conduit_mcp, :subscription, :stop], _,
                      %{reason: :token_expired}}
    end
  end

  # --- cleanup ----------------------------------------------------------------

  describe "cleanup" do
    test "a client disconnect unregisters the stream and frees its slot" do
      port = start_server(keep_alive_interval: 10, auth: function_auth())
      uri = unique_uri()

      {socket, _acc, _ack} =
        listen(
          port,
          1,
          %{"toolsListChanged" => true, "resourceSubscriptions" => [uri]},
          bearer("dc")
        )

      pid = stream_pid(uri)
      ref = Process.monitor(pid)
      assert pid in Subscriptions.subscribers(:tools)
      assert [{_seq, ^pid, _ref}] = Subscriptions.live_listeners("user:dc")

      :ok = :gen_tcp.close(socket)

      assert_receive {:telemetry, [:conduit_mcp, :subscription, :stop], _,
                      %{reason: :client_closed}},
                     2_000

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
      sync_registry()

      assert Subscriptions.subscribers({:resource, uri}) == []
      refute pid in Subscriptions.subscribers(:tools)
      assert Subscriptions.live_listeners("user:dc") == []
      assert :ets.lookup(SSEStream.streams_table(), {:slot, pid}) == []
    end

    test "Process.exit(stream, :kill) leaks no registry entry" do
      port = start_server(auth: function_auth())
      uri = unique_uri()

      {_socket, _acc, _ack} =
        listen(
          port,
          1,
          %{"promptsListChanged" => true, "resourceSubscriptions" => [uri]},
          bearer("killed")
        )

      pid = stream_pid(uri)
      ref = Process.monitor(pid)
      assert [{_seq, ^pid, _ref}] = Subscriptions.live_listeners("user:killed")
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      sync_registry()

      assert Subscriptions.subscribers({:resource, uri}) == []
      refute pid in Subscriptions.subscribers(:prompts)
      assert Subscriptions.live_listeners("user:killed") == []
      assert Registry.keys(Subscriptions, pid) == []
    end
  end

  # --- tasks extension ----------------------------------------------------------

  describe "notifications/tasks (SV-1)" do
    setup do
      previous = Application.fetch_env(:conduit_mcp, :ext_tasks)
      Application.put_env(:conduit_mcp, :ext_tasks, true)
      start_supervised!(Tasks.EtsStore.Owner)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:conduit_mcp, :ext_tasks, value)
          :error -> Application.delete_env(:conduit_mcp, :ext_tasks)
        end
      end)
    end

    test "a task's changes reach only the streams of the principal that owns it" do
      # No keep-alives: any frame on a socket after its acknowledgment is a
      # notification, so `refute_receive` on the socket is exact. The streams
      # are killed at the end instead of noticing their closed sockets.
      port = start_server(auth: function_auth(), keep_alive_interval: 60_000)
      alice_task = start_task(port, "alice")
      bob_task = start_task(port, "bob")

      {alice, alice_acc, alice_ack} =
        listen(port, "a", %{"taskIds" => [alice_task]}, bearer("alice"), @tasks_meta)

      # Bob names Alice's task too: dropped silently, like an unknown id.
      {bob, bob_acc, bob_ack} =
        listen(port, "b", %{"taskIds" => [alice_task, bob_task]}, bearer("bob"), @tasks_meta)

      assert alice_ack["params"]["notifications"] == %{"taskIds" => [alice_task]}
      assert bob_ack["params"]["notifications"] == %{"taskIds" => [bob_task]}

      :ok = Tasks.progress(alice_task, "Halfway")

      # Positive control: the change was published and reached Alice.
      {_acc, [_ack, notification]} = await_events(alice, alice_acc, 2)
      {:ok, record} = Tasks.status(alice_task)

      assert notification == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/tasks",
               "params" => Map.put(Tasks.to_wire(record), "_meta", %{@subscription_id => "a"})
             }

      assert notification["params"]["statusMessage"] == "Halfway"
      assert :ok = McpSchema.validate(@ext_schema, "TaskStatusNotification", notification)

      refute_receive {:tcp, ^bob, _data}, 100

      # Bob's stream is live: his own task's change reaches him, not Alice.
      :ok = Tasks.complete(bob_task, %{"content" => []})
      {_acc, [_ack, bob_notification]} = await_events(bob, bob_acc, 2)

      assert %{
               "method" => "notifications/tasks",
               "params" => %{"taskId" => ^bob_task, "status" => "completed", "result" => _}
             } = bob_notification

      refute_receive {:tcp, ^alice, _data}, 100

      for {owner, task_id} <- [{"alice", alice_task}, {"bob", bob_task}],
          pid <- Subscriptions.subscribers(Subscriptions.task_topic(owner, task_id)) do
        Process.exit(pid, :kill)
      end
    end

    test "the acknowledgment echoes owned taskIds; an undeclared extension is -32021" do
      port = start_server()
      task_id = start_task(port, nil)

      {socket, _acc, ack} =
        listen(port, 1, %{"taskIds" => [task_id, "unknown", task_id]}, [], @tasks_meta)

      assert ack["params"]["notifications"] == %{"taskIds" => [task_id]}
      golden!("SubscriptionsAcknowledgedNotification", ack)
      :gen_tcp.close(socket)

      response = post(port, listen_request(2, %{"taskIds" => [task_id]}))

      assert response.status == 400

      assert %{
               "id" => 2,
               "error" => %{
                 "code" => -32_021,
                 "data" => %{
                   "requiredCapabilities" => %{
                     "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
                   }
                 }
               }
             } = JSON.decode!(response.body)
    end
  end

  # Calls the `slow` tool as `principal` (`nil`: unauthenticated) and returns
  # the id of the task it created.
  defp start_task(port, principal) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => "call",
      "method" => "tools/call",
      "params" => %{"name" => "slow", "arguments" => %{}, "_meta" => @tasks_meta}
    }

    headers = [
      {"mcp-protocol-version", @version},
      {"mcp-method", "tools/call"},
      {"mcp-name", "slow"}
    ]

    auth = if principal, do: bearer(principal), else: []
    response = post(port, {JSON.encode!(body), headers}, auth)

    assert %{"result" => %{"resultType" => "task", "taskId" => task_id}} =
             JSON.decode!(response.body)

    task_id
  end

  # --- limits -----------------------------------------------------------------

  describe "limits (SV-10)" do
    test "at the per-principal cap the oldest stream is superseded, never another principal's" do
      port = start_server(keep_alive_interval: 10, auth: function_auth())
      other_uri = unique_uri()

      {other, _acc, _ack} =
        listen(port, 100, %{"resourceSubscriptions" => [other_uri]}, bearer("other"))

      streams =
        for n <- 1..4 do
          uri = unique_uri()

          {socket, acc, _ack} =
            listen(port, n, %{"resourceSubscriptions" => [uri]}, bearer("capped"))

          {socket, acc, uri}
        end

      # The 5th is admitted; stream 1 ends with the server-initiated teardown.
      {fifth, _acc, _ack} = listen(port, 5, %{"toolsListChanged" => true}, bearer("capped"))
      assert_superseded(Enum.at(streams, 0), 1)

      # A 6th supersedes the next oldest.
      {sixth, _acc, _ack} = listen(port, 6, %{"toolsListChanged" => true}, bearer("capped"))
      assert_superseded(Enum.at(streams, 1), 2)

      for {_socket, _acc, uri} <- Enum.drop(streams, 2),
          do: assert(Process.alive?(stream_pid(uri)))

      assert Process.alive?(stream_pid(other_uri))

      for socket <- [other, fifth, sixth | Enum.map(Enum.drop(streams, 2), &elem(&1, 0))],
          do: :gen_tcp.close(socket)
    end

    test "a listen refused 503 at :max_streams supersedes nothing" do
      port = start_server(max_streams: 1, max_listens_per_principal: 1)
      uri = unique_uri()
      {socket, _acc, _ack} = listen(port, 1, %{"resourceSubscriptions" => [uri]})

      assert post(port, listen_request(2, %{"toolsListChanged" => true})).status == 503
      assert Process.alive?(stream_pid(uri))
      :gen_tcp.close(socket)
    end

    test "a listen past the shared :max_streams cap is 503" do
      port = start_server(max_streams: 1)
      {socket, _acc, _ack} = listen(port, 1, %{"toolsListChanged" => true})

      response = post(port, listen_request(2, %{"toolsListChanged" => true}))

      assert response.status == 503
      assert %{"id" => 2, "error" => %{"code" => -32000}} = JSON.decode!(response.body)
      :gen_tcp.close(socket)
    end
  end

  defp assert_superseded({socket, acc, _uri}, id) do
    response = socket |> read_until(&complete?/1, acc) |> parse()

    assert [_ack, cancelled, %{"id" => ^id, "result" => %{"resultType" => "complete"}}] =
             events(response.body)

    assert %{"method" => "notifications/cancelled", "params" => %{"requestId" => ^id}} =
             cancelled

    assert cancelled["params"]["reason"] =~ "Superseded"

    assert_receive {:telemetry, [:conduit_mcp, :subscription, :stop], _, %{reason: :superseded}}
  end
end

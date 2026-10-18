defmodule ConduitMcp.Client.SecretScanTest do
  # The secret-scan end to end (plan 15.2; TL-1, MR-2): one scenario drives
  # every place a credential or a payload passes through the client and our
  # own server, with every telemetry event recorded by a wildcard handler
  # (and the default logging handlers attached), every log line captured at
  # `:debug`, and crash reports forced while requests are in flight. Each
  # known secret value is then searched for in all of it: the count must be
  # zero.
  #
  # Secrets: a static bearer token, tool arguments, a sealed MRTR
  # `requestState` (elicitation round), a legacy `Mcp-Session-Id`, a stdio
  # child's `env` value, and OAuth's (OA-8): every access and refresh token
  # (rotated ones included), authorization code, `state` and PKCE verifier
  # of three interactive authorizations (the first 401, a 401 from `:ready`
  # after the refresh token was revoked, a 403 step-up), and a
  # client-credentials secret and token.
  #
  # `async: false`: the default handlers are global, and `capture_log/2`
  # sees every process.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :stdio

  import ExUnit.CaptureLog
  import ConduitMcp.Test.Client.Harness, only: [eventually: 1]

  alias ConduitMcp.Client
  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.TokenStore
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.Stdio
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.TelemetryTestHelper
  alias ConduitMcp.Test.Client.HTTPServers
  alias ConduitMcp.Test.Client.OAuthFake
  alias ConduitMcp.Test.Client.StdioFixture

  if Stdio.windows?(), do: @moduletag(skip: "the stdio fixtures are POSIX scripts")

  @token "TOKEN-c0nduit-7f3a9e51"
  @arg "ARG-c0nduit-41d2bb07"
  @env "ENV-c0nduit-93c1aa6d"
  @client_secret "CLIENT-SECRET-c0nduit-5be0c2f4"
  @redirect "http://127.0.0.1:9/callback"
  @cimd "https://app.example.com/oauth/client.json"

  defmodule Server do
    use ConduitMcp.Server

    alias ConduitMcp.Test.Client.HTTPServers

    tool "store", "Stores a secret" do
      param(:secret, :string, "Secret", required: true)
      handle(fn _conn, _params -> text("stored") end)
    end

    tool "approve", "Asks for approval, then reports the requestState it got back" do
      param(:secret, :string, "Secret", required: true)
      param(:test, :string, "Test key", required: true)

      handle(fn conn, %{"test" => key} ->
        case conn.assigns[:mcp_input] do
          nil ->
            elicit =
              ConduitMcp.MRTR.elicit("Approve?", %{"type" => "object", "properties" => %{}})

            {:input_required, %{"ok" => elicit}, %{"step" => 1}}

          %{responses: %{"ok" => %{"action" => action}}} ->
            send(
              HTTPServers.test_pid(key),
              {:request_state, conn.body_params["params"]["requestState"]}
            )

            text("approval: " <> action)
        end
      end)
    end

    tool "hold", "Runs until the client goes away" do
      param(:secret, :string, "Secret", required: true)
      param(:test, :string, "Test key", required: true)

      handle(fn _conn, %{"test" => key} ->
        send(HTTPServers.test_pid(key), {:holding, self()})
        receive do: (:never -> text("unreachable"))
      end)
    end
  end

  defmodule ScopedServer do
    use ConduitMcp.Server

    tool "store", "Stores a secret" do
      param(:secret, :string, "Secret", required: true)
      handle(fn _conn, _params -> text("stored") end)
    end

    tool "admin_op", "Needs the admin scope" do
      scope("admin")
      handle(fn _conn, _params -> text("admin ok") end)
    end
  end

  defmodule Approver do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "accept", "content" => %{}}}
  end

  setup do
    previous = Application.get_env(:conduit_mcp, :mrtr_keys)
    Application.put_env(:conduit_mcp, :mrtr_keys, [{"scan", :crypto.strong_rand_bytes(32)}])
    :ok = ConduitMcp.Telemetry.attach_default_handlers()

    on_exit(fn ->
      ConduitMcp.Telemetry.detach_default_handlers()

      if previous,
        do: Application.put_env(:conduit_mcp, :mrtr_keys, previous),
        else: Application.delete_env(:conduit_mcp, :mrtr_keys)
    end)
  end

  test "no secret reaches telemetry, logs or crash reports" do
    ref =
      TelemetryTestHelper.attach_event_handlers(self(), ConduitMcp.Telemetry.events(), match: %{})

    {{secrets, statuses}, log} =
      with_log([level: :debug], fn -> run_flows() end)

    events = drain(ref, [])

    # The scenario reached what it means to scan.
    emitted = MapSet.new(events, &elem(&1, 0))

    for event <- [
          [:conduit_mcp, :auth, :verify],
          [:conduit_mcp, :mrtr, :input_required],
          [:conduit_mcp, :client, :input_request, :stop],
          [:conduit_mcp, :client, :tool_call, :stop],
          [:conduit_mcp, :client, :request, :stop],
          [:conduit_mcp, :client, :connection, :transition],
          [:conduit_mcp, :client, :oauth, :discovery, :stop],
          [:conduit_mcp, :client, :oauth, :registration, :stop],
          [:conduit_mcp, :client, :oauth, :token_exchange, :stop],
          [:conduit_mcp, :client, :oauth, :refresh, :stop],
          [:conduit_mcp, :client, :oauth, :step_up, :stop],
          [:conduit_mcp, :client, :oauth, :authorization_required]
        ] do
      assert event in emitted, inspect(event)
    end

    assert log =~ "terminating"
    # 5 + 3 authorizations x (code, state, verifier, access, refresh) + a
    # rotated pair + the client-credentials secret and token.
    assert length(secrets) == 24
    assert Enum.all?(secrets, &(is_binary(&1) and byte_size(&1) >= 8))
    assert length(Enum.uniq(secrets)) == 24

    haystacks =
      [{"logs", log}] ++
        Enum.map(statuses, &{"status", deep(&1)}) ++
        Enum.map(events, fn {event, measurements, metadata} ->
          {inspect(event), deep({measurements, metadata})}
        end)

    found =
      for {label, haystack} <- haystacks,
          secret <- secrets,
          String.contains?(haystack, secret),
          do: {label, secret}

    assert found == []
  end

  # Every flow, with its known secret values and the process statuses
  # (`:sys.get_status/1`, what a crash report formats) it collected.
  defp run_flows do
    url =
      HTTPServers.serve_mcp(Server, session: [], auth: [strategy: :bearer_token, token: @token])

    key = HTTPServers.register_test()
    auth = [auth: {:bearer, Secret.new(@token)}]

    # Modern: a tool call, then an MRTR elicitation round.
    modern =
      start_ready({StreamableHTTP, [url: url] ++ auth}, protocol: :modern, handler: Approver)

    assert {:ok, %ToolResult{is_error: false}} =
             Client.call_tool(modern, "store", %{"secret" => @arg})

    assert {:ok, %ToolResult{content: [%{"text" => "approval: accept"}]}} =
             Client.call_tool(modern, "approve", %{"secret" => @arg, "test" => key})

    assert_receive {:request_state, request_state} when is_binary(request_state)

    # The open listen is a long-lived exchange process.
    :ok = Client.subscribe_notifications(modern)
    exchange = await_tstate(modern, &(&1.exchanges |> Map.values() |> List.first()))

    assert %{mcp_transport: :http, mcp_era: :modern} =
             client_logger_metadata(exchange.pid)

    # Legacy: a session, then a crash while a call is in flight.
    legacy = start_ready({StreamableHTTP, [url: url] ++ auth}, protocol: :legacy)
    session_id = legacy |> connection_data() |> then(& &1.tstate.session) |> Secret.expose()
    assert is_binary(session_id)
    listener = await_tstate(legacy, & &1.listener)
    assert %{mcp_transport: :http, mcp_era: :legacy} = client_logger_metadata(listener.pid)

    assert {:ok, %ToolResult{is_error: false}} =
             Client.call_tool(legacy, "store", %{"secret" => @arg})

    legacy_conn = connection(legacy)

    held =
      Task.async(fn -> Client.call_tool(legacy, "hold", %{"secret" => @arg, "test" => key}) end)

    assert_receive {:holding, tool}, 2_000
    legacy_status = :sys.get_status(legacy_conn)
    :ok = :sys.terminate(legacy_conn, :scan_crash)
    assert {:error, _closed} = Task.await(held)
    # A legacy JSON response has no keep-alive to find the client gone.
    Process.exit(tool, :kill)

    # stdio: an env secret, a call in flight, the port owner and then the
    # connection taken down under it.
    env = %{"CONDUIT_TEST_SECRET" => Secret.new(@env)}
    stdio = start_ready(StdioFixture.server("slow:300", env: env), protocol: :modern)

    assert {:ok, %ToolResult{}} = Client.call_tool(stdio, "echo", %{"message" => @arg})

    owner = StdioFixture.port_owner(stdio)
    assert client_logger_metadata(owner).mcp_transport == :stdio
    stdio_conn = connection(stdio)
    pending = Task.async(fn -> Client.call_tool(stdio, "echo", %{"message" => @arg}) end)
    await_pending(stdio_conn)
    statuses = [legacy_status, :sys.get_status(stdio_conn), :sys.get_status(owner)]
    :ok = :sys.terminate(owner, :scan_crash)
    Process.exit(stdio_conn, :kill)
    assert {:error, _down} = Task.await(pending)

    {oauth_secrets, oauth_statuses} = oauth_flows()

    {[@token, @arg, @env, request_state, session_id] ++ oauth_secrets, statuses ++ oauth_statuses}
  end

  # OAuth (OA-8): the code flow with PKCE through `authorize_url/2` and
  # `handle_callback/3`, a refresh with rotation, a 401 from `:ready` (the
  # `:authorizing` episode), a 403 step-up and client credentials; then the
  # connection and its `TokenStore.ETS` crash.
  defp oauth_flows do
    fake = OAuthFake.start(jwt: true) |> OAuthFake.serve_as()
    url = OAuthFake.serve_mcp(fake, ScopedServer, scopes_supported: ["read"])
    name = {__MODULE__, make_ref()}
    test = self()

    oauth = [
      redirect_uri: @redirect,
      client_metadata_url: @cimd,
      allow_insecure_oauth: true,
      on_authorization_required: fn challenge -> send(test, {:authorize, name, challenge}) end
    ]

    start_supervised!(
      {Client,
       name: name,
       protocol: :modern,
       transport: {StreamableHTTP, url: url <> "/", auth: {:oauth, oauth}},
       backoff: fn _ -> 60_000 end},
      id: name
    )

    first = authorize(fake, name)
    assert :ok = Client.await_ready(name, 5_000)
    assert {:ok, %ToolResult{}} = Client.call_tool(name, "store", %{"secret" => @arg})

    assert {:ok, rotated} = OAuth.refresh(name)
    rotated = [Secret.expose(rotated.access_token), Secret.expose(rotated.refresh_token)]

    # A 401 from `:ready`: the token expired and the refresh token is gone.
    store = TokenStore.ETS.default(name)
    key = {nil, fake.issuer, url}
    {:ok, tokens} = TokenStore.fetch_tokens(store, key)
    :ok = TokenStore.put_tokens(store, key, %{tokens | expires_at: 0})
    OAuthFake.revoke_refresh_tokens(fake)

    assert {:error, %Client.Error{reason: :authorization_required}} =
             Client.call_tool(name, "store", %{"secret" => @arg})

    assert {:authorizing, _data} = :sys.get_state(connection(name))
    again = authorize(fake, name)
    assert :ok = Client.await_ready(name, 5_000)

    # A 403 insufficient_scope: step-up, then the call succeeds.
    assert {:error, %Client.Error{reason: :authorization_required}} =
             Client.call_tool(name, "admin_op", %{})

    step_up = authorize(fake, name)

    assert {:ok, %ToolResult{content: [%{"text" => "admin ok"}]}} =
             Client.call_tool(name, "admin_op", %{})

    {cc_secrets, cc_status} = client_credentials(fake, url)

    conn = connection(name)
    {:ok, store_pid, _value} = Registry.lookup({:token_store, {:client, name}})
    statuses = [:sys.get_status(conn), :sys.get_status(store_pid), cc_status]
    :ok = :sys.terminate(conn, :scan_crash)
    :ok = :sys.terminate(store_pid, :scan_crash)

    {first ++ rotated ++ again ++ step_up ++ cc_secrets, statuses}
  end

  # The host's side: the callback reported a challenge; the URL, the user's
  # approval at the fake, the callback. Returns the flow's secrets.
  defp authorize(fake, name) do
    assert_receive {:authorize, ^name, challenge}, 5_000
    {:ok, url, pending} = OAuth.authorize_url(name, challenge: challenge)
    params = OAuthFake.approve(fake, url)
    assert {:ok, tokens} = OAuth.handle_callback(pending, params, client: name)

    [
      params["code"],
      params["state"],
      Secret.expose(pending.verifier),
      Secret.expose(tokens.access_token),
      Secret.expose(tokens.refresh_token)
    ]
  end

  defp client_credentials(fake, url) do
    OAuthFake.register_client(fake, "svc", {:secret, @client_secret})
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       name: name,
       protocol: :modern,
       transport:
         {StreamableHTTP,
          url: url <> "/",
          auth:
            {:client_credentials,
             client_id: "svc",
             client_secret: @client_secret,
             scopes: ["read"],
             allow_insecure_oauth: true}},
       backoff: fn _ -> 60_000 end},
      id: name
    )

    assert :ok = Client.await_ready(name, 5_000)
    assert {:ok, %ToolResult{}} = Client.call_tool(name, "store", %{"secret" => @arg})

    {:ok, tokens} =
      TokenStore.fetch_tokens(TokenStore.ETS.default(name), {nil, fake.issuer, url})

    {[@client_secret, Secret.expose(tokens.access_token)], :sys.get_status(connection(name))}
  end

  defp start_ready(transport, opts) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client, [name: name, transport: transport, backoff: fn _ -> 60_000 end] ++ opts},
      id: name
    )

    assert :ok = Client.await_ready(name, 15_000)
    name
  end

  defp connection(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    conn
  end

  defp connection_data(name) do
    {_state, data} = :sys.get_state(connection(name))
    data
  end

  # Waits for `fun` of the transport state to return a process entry.
  defp await_tstate(name, fun) do
    eventually(fn -> match?(%{pid: pid} when is_pid(pid), fun.(connection_data(name).tstate)) end)
    fun.(connection_data(name).tstate)
  end

  defp await_pending(conn) do
    eventually(fn ->
      {_state, data} = :sys.get_state(conn)
      map_size(data.pending) > 0
    end)
  end

  defp client_logger_metadata(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    {_key, metadata} = List.keyfind(dictionary, :"$logger_metadata$", 0)
    Map.new(metadata)
  end

  defp drain(ref, acc) do
    receive do
      {event, ^ref, measurements, metadata} -> drain(ref, [{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Every term rendered in full, struct internals included (a `Secret`
  # in metadata counts as a leak: a handler could expose it).
  defp deep(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity, structs: false)
end

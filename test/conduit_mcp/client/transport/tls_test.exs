defmodule ConduitMcp.Client.Transport.TLSTest do
  # HT-8 over a real socket: the Streamable HTTP client against this
  # library's own server on Bandit `https`, with a certificate made at run
  # time by a CA the client does not trust. Verification is on by default
  # and only `insecure_skip_tls_verify: true` turns it off; no
  # `:transport_opts` path does it silently.
  use ExUnit.Case, async: true

  @moduletag :integration

  import ExUnit.CaptureLog

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.HTTPDslServer

  setup_all do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          peer: [
            key: {:rsa, 2048, 65_537},
            extensions: [
              {:Extension, {2, 5, 29, 17}, false,
               [{:dNSName, ~c"localhost"}, {:dNSName, ~c"pinned.mcp.test"}]}
            ]
          ]
        },
        client_chain: %{root: [key: {:rsa, 2048, 65_537}], peer: [key: {:rsa, 2048, 65_537}]}
      })

    server = Map.new(server)
    %{cert: server.cert, key: server.key, cacerts: Keyword.fetch!(client, :cacerts)}
  end

  setup %{cert: cert, key: key} do
    port = serve_tls(cert, key)
    %{url: "https://localhost:#{port}/", port: port}
  end

  defp serve_tls(cert, key, plug_opts \\ []) do
    plug =
      {ConduitMcp.Transport.StreamableHTTP,
       [server_module: HTTPDslServer, allowed_origins: "*", keep_alive_interval: 50] ++
         plug_opts}

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: plug,
           scheme: :https,
           port: 0,
           ip: :loopback,
           startup_log: false,
           thousand_island_options: [transport_options: [cert: cert, key: key]]},
          id: make_ref()
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp client_opts(transport_opts) do
    [
      name: {__MODULE__, make_ref()},
      transport: {StreamableHTTP, transport_opts},
      max_reconnects: 0,
      backoff: fn _attempt -> 0 end
    ]
  end

  defp connect(transport_opts) do
    opts = client_opts(transport_opts)
    start_supervised!({Client, opts})
    {Client.await_ready(opts[:name], 5_000), opts[:name]}
  end

  test "a certificate from an untrusted CA fails the connection", %{url: url} do
    capture_log(fn ->
      assert {{:error, %Error{}}, name} = connect(url: url)
      refute match?({:ok, %{state: :ready}}, Client.status(name))
    end)
  end

  test "trusting the issuing CA connects: verification, not the server, failed above",
       %{url: url, cacerts: cacerts} do
    assert {:ok, name} = connect(url: url, transport_opts: [cacerts: cacerts])
    assert {:ok, %{tools: [_ | _]}} = Client.list_tools(name)
  end

  test "insecure_skip_tls_verify: true connects, with a warning", %{url: url} do
    log =
      capture_log(fn ->
        assert {:ok, name} = connect(url: url, insecure_skip_tls_verify: true)
        assert {:ok, %{tools: [_ | _]}} = Client.list_tools(name)
      end)

    assert log =~ "insecure_skip_tls_verify"
  end

  describe "without insecure_skip_tls_verify, no transport_opts disable verification" do
    # The duplicate is the bypass: the first `:verify` read as `:verify_peer`
    # while `:ssl` honoured the later `:verify_none` and connected.
    test "verify: :verify_none raises at start, even behind a :verify_peer", %{url: url} do
      for transport_opts <- [
            [verify: :verify_none],
            [verify: :verify_peer, verify: :verify_none],
            [cacertfile: "/nonexistent", verify: :verify_none]
          ] do
        assert_raise ArgumentError, ~r/insecure_skip_tls_verify/, fn ->
          Client.child_spec(client_opts(url: url, transport_opts: transport_opts))
        end
      end
    end

    test "an accept-everything verify_fun raises at start", %{url: url} do
      accept_all = {fn _cert, _event, state -> {:valid, state} end, nil}

      for transport_opts <- [
            [verify_fun: accept_all],
            [verify: :verify_peer, verify_fun: accept_all]
          ] do
        assert_raise ArgumentError, ~r/insecure_skip_tls_verify/, fn ->
          Client.child_spec(client_opts(url: url, transport_opts: transport_opts))
        end
      end
    end

    test "a trust-anything partial_chain still fails the connection", %{url: url} do
      trust_any = fn [root | _] -> {:trusted, root} end

      capture_log(fn ->
        assert {{:error, %Error{}}, _name} =
                 connect(url: url, transport_opts: [partial_chain: trust_any])
      end)
    end
  end

  # W-S4: `server_url_policy: :public_only` connects to the address it
  # vetted. `pinned.mcp.test` resolves nowhere but through the test's
  # resolver, so a request that resolved the name a second time could not
  # connect at all.
  describe "server_url_policy: :public_only pins the vetted address" do
    setup %{port: port, cacerts: cacerts} do
      test = self()

      resolver = fn host ->
        send(test, {:resolved, host, self()})
        {:ok, [{127, 0, 0, 1}]}
      end

      opts = [
        server_url_policy: :public_only,
        allow_private: ["127.0.0.0/8"],
        resolver: resolver,
        transport_opts: [cacerts: cacerts]
      ]

      %{opts: opts, pinned: "https://pinned.mcp.test:#{port}/"}
    end

    test "with the library's pool: TLS verified for the original host, the resolver run per request outside the connection",
         %{opts: opts, pinned: pinned} do
      assert {:ok, name} = connect([url: pinned] ++ opts)
      assert {:ok, %{tools: [_ | _]}} = Client.list_tools(name)

      {:ok, connection, _view} = ConduitMcp.Client.Request.lookup(name)
      assert_received {:resolved, "pinned.mcp.test", resolved_in}
      refute resolved_in == connection
    end

    test "with a :finch pool of the host's", %{opts: opts, pinned: pinned} do
      finch = :"#{__MODULE__}.Finch#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})

      assert {:ok, name} = connect([url: pinned, finch: finch] ++ opts)
      assert {:ok, %{tools: [_ | _]}} = Client.list_tools(name)
    end

    test "a name the certificate does not cover fails the handshake, so nothing is sent",
         %{opts: opts, port: port} do
      capture_log(fn ->
        assert {{:error, %Error{}}, _name} =
                 connect([url: "https://rebound.mcp.test:#{port}/"] ++ opts)
      end)
    end

    test "an address outside allow_private is refused before any connection",
         %{opts: opts, pinned: pinned} do
      capture_log(fn ->
        assert {{:error, %Error{}}, _name} =
                 connect([url: pinned] ++ Keyword.delete(opts, :allow_private))
      end)
    end

    test "a legacy session's DELETE on close is pinned too (from a task, not the connection)",
         %{opts: opts, cert: cert, key: key} do
      port = serve_tls(cert, key, session: [])
      name = {__MODULE__, make_ref()}

      start_supervised!(
        {Client,
         name: name,
         protocol: :legacy,
         transport: {StreamableHTTP, [url: "https://pinned.mcp.test:#{port}/"] ++ opts},
         max_reconnects: 0,
         backoff: fn _attempt -> 0 end}
      )

      assert :ok = Client.await_ready(name, 5_000)
      {:ok, connection, _view} = ConduitMcp.Client.Request.lookup(name)
      {_state, data} = :sys.get_state(connection)
      sid = Secret.expose(data.tstate.session)
      assert {:ok, _} = ConduitMcp.Session.EtsStore.get(sid)

      assert :ok = Client.close(name)
      assert {:error, _} = ConduitMcp.Session.EtsStore.get(sid)

      for {:resolved, "pinned.mcp.test", pid} <- flush_resolved() do
        refute pid == connection
      end
    end
  end

  defp flush_resolved do
    receive do
      {:resolved, _host, _pid} = message -> [message | flush_resolved()]
    after
      0 -> []
    end
  end
end

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
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Test.Client.HTTPDslServer

  setup_all do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          peer: [
            key: {:rsa, 2048, 65_537},
            extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
          ]
        },
        client_chain: %{root: [key: {:rsa, 2048, 65_537}], peer: [key: {:rsa, 2048, 65_537}]}
      })

    server = Map.new(server)
    %{cert: server.cert, key: server.key, cacerts: Keyword.fetch!(client, :cacerts)}
  end

  setup %{cert: cert, key: key} do
    plug =
      {ConduitMcp.Transport.StreamableHTTP,
       server_module: HTTPDslServer, allowed_origins: "*", keep_alive_interval: 50}

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
    %{url: "https://localhost:#{port}/"}
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
end

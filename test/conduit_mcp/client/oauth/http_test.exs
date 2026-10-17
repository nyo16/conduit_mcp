defmodule ConduitMcp.Client.OAuth.HTTPTest do
  # The OAuth HTTP layer: URL policy before any connection, IP pinning with
  # TLS SNI and hostname verification against the original name (HT-6), no
  # redirects, no decompression, a body cap.
  use ExUnit.Case, async: true

  @moduletag :integration

  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.OAuth.HTTP

  defmodule Echo do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(test), do: test

    def call(conn, test) do
      send(test, {:hit, conn.request_path})

      case conn.request_path do
        "/redirect" ->
          conn |> put_resp_header("location", "/elsewhere") |> send_resp(302, "")

        "/gzip" ->
          conn |> put_resp_header("content-encoding", "gzip") |> send_resp(200, "x")

        "/big" ->
          send_resp(conn, 200, String.duplicate("a", 2_000))

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(%{"host" => conn.host}))
      end
    end
  end

  # A CA and a server certificate for `auth.test`, made at run time.
  defp tls do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          peer: [
            key: {:rsa, 2048, 65_537},
            extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"auth.test"}]}]
          ]
        },
        client_chain: %{root: [key: {:rsa, 2048, 65_537}], peer: [key: {:rsa, 2048, 65_537}]}
      })

    {Map.new(server), Keyword.fetch!(client, :cacerts)}
  end

  defp serve(scheme, extra \\ []) do
    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           [plug: {Echo, self()}, scheme: scheme, port: 0, ip: :loopback, startup_log: false] ++
             extra},
          id: make_ref()
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  setup_all do
    {server, cacerts} = tls()
    %{server: server, cacerts: cacerts}
  end

  describe "IP pinning with SNI (the 14.2 prototype)" do
    setup %{server: server, cacerts: cacerts} do
      port =
        serve(:https,
          thousand_island_options: [transport_options: [cert: server.cert, key: server.key]]
        )

      test = self()

      resolver = fn host ->
        send(test, {:resolved, host})
        {:ok, [{127, 0, 0, 1}]}
      end

      %{port: port, cacerts: cacerts, resolver: resolver}
    end

    test "connects to the vetted address once, verifying the certificate for the original host",
         ctx do
      http = %{
        resolver: ctx.resolver,
        allow_private: ["127.0.0.0/8"],
        transport_opts: [cacerts: ctx.cacerts]
      }

      assert {:ok, %{status: 200} = response} =
               HTTP.get("https://auth.test:#{ctx.port}/meta", http)

      assert {:ok, %{"host" => "auth.test"}} = HTTP.json(response)
      assert_received {:resolved, "auth.test"}
      refute_received {:resolved, _}
    end

    test "a certificate for another name fails hostname verification", ctx do
      http = %{
        resolver: ctx.resolver,
        allow_private: ["127.0.0.0/8"],
        transport_opts: [cacerts: ctx.cacerts]
      }

      assert {:error, {:transport_error, _}} =
               HTTP.get("https://evil.test:#{ctx.port}/meta", http)

      refute_received {:hit, _}
    end

    test "a blocked address is refused before any connection", ctx do
      http = %{resolver: ctx.resolver, transport_opts: [cacerts: ctx.cacerts]}

      assert {:error, {:url_blocked, {:blocked_address, {127, 0, 0, 1}}}} =
               HTTP.get("https://auth.test:#{ctx.port}/meta", http)

      refute_received {:hit, _}
    end

    test "plain http is refused unless allow_insecure, and then only for loopback", ctx do
      assert {:error, {:invalid_url, :insecure_url}} =
               HTTP.get("http://127.0.0.1:#{ctx.port}/meta", %{})

      assert {:error, {:invalid_url, :insecure_url}} =
               HTTP.get("http://auth.test:#{ctx.port}/meta", %{allow_insecure: true})
    end

    # HT-8 on the OAuth path: `insecure_skip_tls_verify` does not exist
    # here, so nothing may turn verification off.
    test "a certificate from a CA outside the trust store fails", ctx do
      http = %{resolver: ctx.resolver, allow_private: ["127.0.0.0/8"]}

      assert {:error, {:transport_error, _}} =
               HTTP.get("https://auth.test:#{ctx.port}/meta", http)

      refute_received {:hit, _}
    end

    test "TLS options that turn verification off are refused, and never reach the socket",
         ctx do
      accept_all = {fn _cert, _event, state -> {:valid, state} end, nil}

      for tls <- [
            [verify: :verify_none],
            [verify: :verify_peer, verify: :verify_none],
            [verify_fun: accept_all]
          ] do
        assert {:error, message} =
                 OAuth.Config.new(server_url: "https://mcp.example.com", transport_opts: tls)

        assert message =~ "transport_opts"

        http = %{resolver: ctx.resolver, allow_private: ["127.0.0.0/8"], transport_opts: tls}

        assert {:error, {:transport_error, _}} =
                 HTTP.get("https://auth.test:#{ctx.port}/meta", http)
      end

      refute_received {:hit, _}
    end
  end

  describe "responses" do
    setup do
      %{base: "http://127.0.0.1:#{serve(:http)}", http: %{allow_insecure: true}}
    end

    test "a redirect is refused, never followed (HT-4)", ctx do
      assert {:error, {:redirect, 302}} = HTTP.get(ctx.base <> "/redirect", ctx.http)
      assert_received {:hit, "/redirect"}
      refute_received {:hit, "/elsewhere"}
    end

    test "a compressed body is refused before it is read (HT-1)", ctx do
      assert {:error, {:unsupported_content_encoding, "gzip"}} =
               HTTP.get(ctx.base <> "/gzip", ctx.http)
    end

    test "the body is capped", ctx do
      assert {:error, :message_too_large} =
               HTTP.get(ctx.base <> "/big", Map.put(ctx.http, :max_bytes, 1_000))

      assert {:ok, %{body: body}} = HTTP.get(ctx.base <> "/big", ctx.http)
      assert byte_size(body) == 2_000
    end
  end
end

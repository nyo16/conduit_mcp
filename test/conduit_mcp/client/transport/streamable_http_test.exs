defmodule ConduitMcp.Client.Transport.StreamableHTTPTest do
  # Options and pure helpers of the Streamable HTTP client transport; its
  # behaviour on the wire is covered by the `:integration` tests
  # (`http_integration_test.exs`, `http_scripted_test.exs`).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.StreamableHTTP
  alias ConduitMcp.Client.Transport.StreamableHTTP.Exchange

  defp validate(opts), do: StreamableHTTP.validate_options(opts)

  defp start(transport_opts, opts \\ []) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       [name: name, transport: {StreamableHTTP, transport_opts}, max_reconnects: 0] ++ opts}
    )

    name
  end

  test "kind/0 is :http" do
    assert StreamableHTTP.kind() == :http
  end

  describe "options" do
    test "a valid URL with defaults" do
      assert {:ok, opts} = validate(url: "https://mcp.example.com/mcp")
      assert opts[:redirect] == false
      assert opts[:server_url_policy] == :any
      assert opts[:max_message_bytes] == 8 * 1024 * 1024
      assert opts[:listen_idle_timeout] == 120_000
    end

    test "URLs that are not plain http(s) are refused" do
      for url <- ["ftp://x/", "https://user:pw@x/", "https://x/#frag", "not a url", "https:///"] do
        assert {:error, message} = validate(url: url), url
        assert message =~ "url"
      end
    end

    test "headers the transport owns are refused, as are unsafe values" do
      for name <- ["Authorization", "mcp-session-id", "Mcp-Param-Region", "content-type", "Host"] do
        assert {:error, message} = validate(url: "https://x/", headers: [{name, "v"}])
        assert message =~ "set by the transport"
      end

      assert {:error, message} = validate(url: "https://x/", headers: [{"x-a", "v\r\nx-b: w"}])
      assert message =~ "visible ASCII characters, spaces and tabs"
      assert {:error, _} = validate(url: "https://x/", headers: [{"bad name", "v"}])

      assert {:ok, opts} =
               validate(url: "https://x/", headers: [{"X-Tenant", Secret.new("acme")}])

      assert [{"x-tenant", %Secret{}}] = opts[:headers]
    end

    test "a plain bearer token is held as a Secret" do
      assert {:ok, opts} = validate(url: "https://x/", auth: {:bearer, "tok"})
      assert {:bearer, %Secret{} = token} = opts[:auth]
      assert Secret.expose(token) == "tok"
      refute inspect(opts) =~ "tok\""
      assert {:error, _} = validate(url: "https://x/", auth: {:bearer, ""})
      assert {:error, _} = validate(url: "https://x/", auth: :oauth)
    end

    test "HT-8: credentials over plain http to a host that is not loopback raise at start" do
      assert_raise ArgumentError, ~r/plain http/, fn ->
        Client.child_spec(
          name: :ht8,
          transport: {StreamableHTTP, url: "http://mcp.example.com/", auth: {:bearer, "tok"}}
        )
      end

      assert_raise ArgumentError, ~r/plain http/, fn ->
        Client.child_spec(
          name: :ht8,
          transport: {StreamableHTTP, url: "http://10.0.0.1/", auth: fn _ -> {:ok, "t"} end}
        )
      end

      for url <- ["http://127.0.0.1:4000/", "http://localhost/", "http://[::1]:4000/"] do
        assert {:ok, _} = validate(url: url, auth: {:bearer, "tok"}), url
      end

      assert {:ok, _} = validate(url: "http://mcp.example.com/")
    end

    test "HT-8: verify_none is refused unless insecure_skip_tls_verify is set" do
      assert {:error, message} =
               validate(url: "https://x/", transport_opts: [verify: :verify_none])

      assert message =~ "insecure_skip_tls_verify"

      assert {:error, message} =
               validate(url: "https://x/", insecure_skip_tls_verify: true, finch: MyFinch)

      assert message =~ "library-started pool"
    end

    test "HT-8: insecure_skip_tls_verify logs a warning when the transport starts" do
      log =
        capture_log(fn ->
          name = start(url: "https://127.0.0.1:1/", insecure_skip_tls_verify: true)
          _ = Client.await_ready(name, 1_000)
        end)

      assert log =~ "insecure_skip_tls_verify"
    end

    test "allow_private entries must be CIDRs" do
      assert {:error, message} = validate(url: "https://x/", allow_private: ["nope"])
      assert message =~ "allow_private"
      assert {:ok, _} = validate(url: "https://x/", allow_private: ["10.0.0.0/8"])
    end
  end

  describe "the pool" do
    test "a library-started Finch unless :finch names one" do
      {:ok, opts} = validate(url: "https://x/")

      assert [%{id: :finch, start: {Finch, :start_link, _}}] =
               StreamableHTTP.child_specs(opts, :k)

      {:ok, opts} = validate(url: "https://x/", finch: MyFinch)
      assert StreamableHTTP.child_specs(opts, :k) == []
    end

    test "the library pool is named from a hash of the client name" do
      http = ConduitMcp.OptionalDeps.finch!()
      name = http.pool_name({:tenant, 42})
      assert name == http.pool_name({:tenant, 42})
      refute name == http.pool_name({:tenant, 43})
      refute Atom.to_string(name) =~ "tenant"
    end
  end

  describe "server_url_policy: :public_only" do
    test "a loopback server is refused before any request" do
      name =
        start([url: "https://127.0.0.1:1/", server_url_policy: :public_only], protocol: :modern)

      assert {:error, %Client.Error{kind: :closed}} = Client.await_ready(name, 2_000)
    end

    # W-S4: pinning the vetted address is only as good as the certificate
    # check bound to the original name.
    test "is refused together with insecure_skip_tls_verify" do
      assert {:error, message} =
               validate(
                 url: "https://x/",
                 server_url_policy: :public_only,
                 insecure_skip_tls_verify: true
               )

      assert message =~ "server_url_policy"
      assert message =~ "insecure_skip_tls_verify"
    end

    test "a :resolver is a one-arity function" do
      assert {:ok, _} = validate(url: "https://x/", resolver: fn _host -> {:ok, []} end)
      assert {:error, message} = validate(url: "https://x/", resolver: :nope)
      assert message =~ "resolver"
    end
  end

  test "HT-14: session ids are 1..1024 visible ASCII characters" do
    assert Exchange.valid_session_id?("a")
    assert Exchange.valid_session_id?(String.duplicate("~", 1_024))
    assert Exchange.valid_session_id?("0123-ABCD_xyz.!")
    refute Exchange.valid_session_id?("")
    refute Exchange.valid_session_id?(String.duplicate("a", 1_025))
    refute Exchange.valid_session_id?("has space")
    refute Exchange.valid_session_id?("tab\there")
    refute Exchange.valid_session_id?("crlf\r\n")
    refute Exchange.valid_session_id?("é")
    refute Exchange.valid_session_id?(nil)
  end

  test "loopback?/1" do
    for host <- ["localhost", "127.0.0.1", "127.9.9.9", "::1", "[::1]"],
        do: assert(StreamableHTTP.loopback?(host), host)

    for host <- ["example.com", "10.0.0.1", "::2", nil, "localhost.example.com"],
        do: refute(StreamableHTTP.loopback?(host), inspect(host))
  end
end

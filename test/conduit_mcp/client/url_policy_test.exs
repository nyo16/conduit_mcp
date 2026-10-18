defmodule ConduitMcp.Client.URLPolicyTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.URLPolicy

  doctest ConduitMcp.Client.URLPolicy

  # A resolver that must not be reached: literal hosts are never resolved.
  defp no_dns(_host), do: flunk("resolver called for a literal host")

  defp resolving(ips) do
    test = self()

    fn host ->
      send(test, {:resolved, host})
      {:ok, ips}
    end
  end

  defp check_ip(literal, opts \\ []) do
    URLPolicy.check(
      "https://#{literal}/x",
      :public_only,
      Keyword.put_new(opts, :resolver, &no_dns/1)
    )
  end

  # {first address inside, last address inside, nearest address outside}
  @v4_ranges [
    {"0.0.0.0/8", "0.0.0.0", "0.255.255.255", "1.0.0.0"},
    {"10.0.0.0/8", "10.0.0.0", "10.255.255.255", "11.0.0.0"},
    {"100.64.0.0/10", "100.64.0.0", "100.127.255.255", "100.128.0.0"},
    {"127.0.0.0/8", "127.0.0.0", "127.255.255.255", "128.0.0.0"},
    {"169.254.0.0/16", "169.254.0.0", "169.254.255.255", "169.255.0.0"},
    {"172.16.0.0/12", "172.16.0.0", "172.31.255.255", "172.32.0.0"},
    {"192.0.0.0/24", "192.0.0.0", "192.0.0.255", "192.0.1.0"},
    {"192.168.0.0/16", "192.168.0.0", "192.168.255.255", "192.169.0.0"},
    {"198.18.0.0/15", "198.18.0.0", "198.19.255.255", "198.20.0.0"},
    {"224.0.0.0/4", "224.0.0.0", "239.255.255.255", "223.255.255.255"},
    {"240.0.0.0/4", "240.0.0.0", "255.255.255.255", "223.255.255.254"}
  ]

  @v6_ranges [
    {"::/96 (unspecified, loopback, v4-compatible)", "::", "::1", "::ffff:ffff", "::1:0:0"},
    {"100::/64", "100::", "100::1", "100::ffff:ffff:ffff:ffff", "100:0:0:1::"},
    {"64:ff9b:1::/48", "64:ff9b:1::", "64:ff9b:1::1", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff",
     "64:ff9b:2::"},
    {"fc00::/7", "fc00::", "fc00::1", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fe00::"},
    {"fe80::/10", "fe80::", "fe80::1", "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fbff::"},
    {"fec0::/10", "fec0::", "fec0::1", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db8::"},
    {"ff00::/8", "ff00::", "ff02::1", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2606:4700::1"}
  ]

  describe "HT-6 range table" do
    test "every blocked IPv4 range: both ends blocked, its neighbour allowed" do
      for {name, first, last, outside} <- @v4_ranges do
        for inside <- [first, last] do
          assert {:error, {:blocked_address, _}} = check_ip(inside), "#{inside} in #{name}"
        end

        assert {:ok, _} = check_ip(outside), "#{outside} outside #{name}"
      end
    end

    test "every blocked IPv6 range: inside blocked, neighbour allowed" do
      for {name, a, b, c, outside} <- @v6_ranges do
        for inside <- [a, b, c] do
          assert {:error, {:blocked_address, _}} = check_ip("[#{inside}]"), "#{inside} in #{name}"
        end

        assert {:ok, _} = check_ip("[#{outside}]"), "#{outside} outside #{name}"
      end
    end

    test "IPv6 forms embedding IPv4 are unwrapped and checked as IPv4" do
      blocked = [
        "::ffff:127.0.0.1",
        "::ffff:7f00:1",
        "::ffff:10.1.2.3",
        "::ffff:0:169.254.169.254",
        "64:ff9b::127.0.0.1",
        "64:ff9b::a00:1",
        "2002:7f00:1::",
        "2002:c0a8:101::1",
        "2002:a9fe:a9fe:1:2:3:4:5"
      ]

      for literal <- blocked do
        assert {:error, {:blocked_address, _}} = check_ip("[#{literal}]"), literal
      end

      public = ["::ffff:8.8.8.8", "::ffff:0:1.1.1.1", "64:ff9b::808:808", "2002:808:808::1"]

      for literal <- public do
        assert {:ok, %{addresses: [_]}} = check_ip("[#{literal}]"), literal
      end
    end

    test "odd IPv4 notations are normalised by parsing before the check" do
      for host <- [
            "127.1",
            "0x7f.1",
            "0x7F.0.0.1",
            "0177.0.0.1",
            "017700000001",
            "2130706433",
            "0x7f000001",
            "127.0.0.1.",
            "127.0.1"
          ] do
        assert check_ip(host) == {:error, {:blocked_address, {127, 0, 0, 1}}}, host
      end

      assert check_ip("0") == {:error, {:blocked_address, {0, 0, 0, 0}}}
      assert check_ip("0xA9.0xFE.0xA9.0xFE") == {:error, {:blocked_address, {169, 254, 169, 254}}}
      assert {:ok, %{host: "8.8.8.8", addresses: [{8, 8, 8, 8}]}} = check_ip("0x8.0x8.0x8.0x8")
    end

    test "numeric hosts that are not valid IPv4 are refused, not resolved" do
      for host <- ["1.2.3.4.5", "09.1", "256.1.1.1", "1.16777216", "0xg.1", "example.123"] do
        assert check_ip(host) == {:error, :invalid_host}, host
      end
    end
  end

  describe ":public_only with hostnames" do
    test "a stubbed resolver answer in a private range is rejected before any connect" do
      assert URLPolicy.check("https://internal.example/", :public_only,
               resolver: resolving([{10, 0, 0, 1}])
             ) == {:error, {:blocked_address, {10, 0, 0, 1}}}

      assert_received {:resolved, "internal.example"}
    end

    test "one blocked address among public ones rejects the URL" do
      ips = [
        {93, 184, 216, 34},
        {0x2606, 0x2800, 0, 0, 0, 0, 0, 1},
        {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}
      ]

      assert {:error, {:blocked_address, {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}}} =
               URLPolicy.check("https://mixed.example", :public_only, resolver: resolving(ips))
    end

    test "public answers return every address for pinning, the hostname for SNI, and the port" do
      ips = [{93, 184, 216, 34}, {93, 184, 216, 34}, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}]

      assert URLPolicy.check("https://API.Example.com.:8443/mcp?x=1", :public_only,
               resolver: resolving(ips)
             ) ==
               {:ok,
                %{
                  scheme: "https",
                  host: "api.example.com",
                  port: 8443,
                  addresses: [{93, 184, 216, 34}, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}]
                }}

      assert_received {:resolved, "api.example.com"}
    end

    test "resolver failures and empty answers are errors" do
      assert URLPolicy.check("https://nx.example", :public_only,
               resolver: fn _ -> {:error, :nxdomain} end
             ) ==
               {:error, {:resolve_failed, :nxdomain}}

      assert URLPolicy.check("https://nx.example", :public_only, resolver: fn _ -> {:ok, []} end) ==
               {:error, {:resolve_failed, :nxdomain}}

      assert URLPolicy.check("https://x.example", :public_only,
               resolver: fn _ -> {:ok, [:bogus]} end
             ) ==
               {:error, {:resolve_failed, :invalid_address}}
    end

    test "localhost resolves through the system resolver and is blocked" do
      assert {:error, {:blocked_address, _}} = URLPolicy.check("https://localhost/", :public_only)
    end
  end

  describe "allow_private" do
    test "admits only its CIDR" do
      opts = [allow_private: ["10.1.0.0/16", {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}]]

      assert {:ok, %{addresses: [{10, 1, 2, 3}]}} = check_ip("10.1.2.3", opts)
      assert {:ok, _} = check_ip("[::ffff:10.1.2.3]", opts)
      assert {:ok, _} = check_ip("[fd12::1]", opts)

      assert check_ip("10.2.0.1", opts) == {:error, {:blocked_address, {10, 2, 0, 1}}}
      assert {:error, {:blocked_address, _}} = check_ip("127.0.0.1", opts)
      assert {:error, {:blocked_address, _}} = check_ip("[fc00::1]", opts)

      assert {:error, {:blocked_address, {10, 9, 9, 9}}} =
               URLPolicy.check("https://h.example", :public_only,
                 allow_private: ["10.1.0.0/16"],
                 resolver: resolving([{10, 1, 0, 1}, {10, 9, 9, 9}])
               )
    end

    test "an invalid CIDR raises naming it" do
      for bad <- ["10.0.0.0/33", "nope", "10.0.0/8", {{10, 0, 0, 0}, 40}, "::/129"] do
        assert_raise ArgumentError, ~r/invalid :allow_private CIDR/, fn ->
          check_ip("1.1.1.1", allow_private: [bad])
        end
      end
    end

    test "parse_cidr/1" do
      assert URLPolicy.parse_cidr("192.168.1.7") == {:ok, {{192, 168, 1, 7}, 32}}
      assert URLPolicy.parse_cidr("fd00::/8") == {:ok, {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}}
      assert URLPolicy.parse_cidr("10.0.0.0/8/1") == :error
      assert URLPolicy.parse_cidr(:x) == :error
    end
  end

  describe "URL shape" do
    test ":public_only requires https; :any allows http and https only" do
      assert check_ip("8.8.8.8") |> elem(0) == :ok

      assert URLPolicy.check("http://8.8.8.8/", :public_only) ==
               {:error, {:scheme_not_allowed, "http"}}

      for url <- ["ftp://x.example/", "javascript:alert(1)", "file:///etc/passwd"] do
        assert {:error, {:scheme_not_allowed, _}} = URLPolicy.check(url, :any), url
      end
    end

    test ":any does no DNS lookup and no address checks" do
      assert URLPolicy.check("http://127.0.0.1:4000/mcp", :any, resolver: &no_dns/1) ==
               {:ok,
                %{scheme: "http", host: "127.0.0.1", port: 4000, addresses: [{127, 0, 0, 1}]}}

      assert URLPolicy.check("HTTPS://Internal.Corp", :any, resolver: &no_dns/1) ==
               {:ok, %{scheme: "https", host: "internal.corp", port: 443, addresses: []}}
    end

    test "parser-differential tricks are refused outright" do
      for url <- [
            "https://user:pass@example.com/",
            "https://example.com@127.0.0.1/",
            "https://%31%32%37.0.0.1/",
            "https://[fe80::1%25en0]/",
            "https://evil.example\\@127.0.0.1/",
            "https://exa mple.com/",
            "https://example.com/\n",
            "https://bücher.example/",
            "https:///path",
            "https://[::ffff:127.0.0.1/",
            "",
            "https://a..b/"
          ] do
        assert {:error, reason} = URLPolicy.check(url, :public_only, resolver: &no_dns/1),
               "#{inspect(url)} was accepted"

        assert reason in [:invalid_url, :invalid_host, :userinfo_not_allowed], inspect(url)
      end
    end
  end
end

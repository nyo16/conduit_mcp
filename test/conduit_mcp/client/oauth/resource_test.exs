defmodule ConduitMcp.Client.OAuth.ResourceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.OAuth.{Error, Resource}

  doctest ConduitMcp.Client.OAuth.Resource

  @table [
    {"https://mcp.example.com/mcp", "https://mcp.example.com/mcp"},
    {"https://mcp.example.com", "https://mcp.example.com"},
    {"https://mcp.example.com/", "https://mcp.example.com"},
    {"https://mcp.example.com/mcp/", "https://mcp.example.com/mcp"},
    {"https://mcp.example.com/mcp//", "https://mcp.example.com/mcp"},
    {"HTTPS://MCP.EXAMPLE.COM/MCP", "https://mcp.example.com/MCP"},
    {"https://mcp.example.com:443/mcp", "https://mcp.example.com/mcp"},
    {"https://mcp.example.com:8443", "https://mcp.example.com:8443"},
    {"https://mcp.example.com/mcp#section", "https://mcp.example.com/mcp"},
    {"https://mcp.example.com/mcp?tenant=A", "https://mcp.example.com/mcp?tenant=A"},
    {"https://mcp.example.com/mcp?", "https://mcp.example.com/mcp"},
    {"https://mcp.example.com/a%2Fb", "https://mcp.example.com/a%2Fb"},
    {"https://[2001:DB8::1]:443/mcp", "https://[2001:db8::1]/mcp"},
    {"https://[2001:db8::1]:8443/", "https://[2001:db8::1]:8443"}
  ]

  test "canonicalization table" do
    for {input, expected} <- @table do
      assert Resource.canonical(input) == {:ok, expected}, input
    end
  end

  test "non-https is refused; http only on loopback with allow_insecure" do
    assert {:error, %Error{reason: :insecure_url}} =
             Resource.canonical("http://mcp.example.com/mcp")

    assert {:error, %Error{reason: :insecure_url}} =
             Resource.canonical("http://127.0.0.1:4000/mcp")

    assert {:error, %Error{reason: :insecure_url}} = Resource.canonical("ws://mcp.example.com")

    assert {:error, %Error{reason: :insecure_url}} =
             Resource.canonical("http://mcp.example.com/mcp", allow_insecure: true)

    assert Resource.canonical("http://127.0.0.1:4000/mcp/", allow_insecure: true) ==
             {:ok, "http://127.0.0.1:4000/mcp"}

    assert Resource.canonical("http://LOCALHOST:80/mcp", allow_insecure: true) ==
             {:ok, "http://localhost/mcp"}

    assert Resource.canonical("http://[::1]:4000", allow_insecure: true) ==
             {:ok, "http://[::1]:4000"}
  end

  test "malformed URLs are refused" do
    for {input, detail} <- [
          {"https://user:pw@mcp.example.com/", :userinfo},
          {"https:///mcp", :missing_host},
          {"/mcp", :not_absolute},
          {"https://mcp.example.com/a b", :unparsable},
          {nil, :not_a_string}
        ] do
      assert {:error, %Error{reason: :invalid_url, data: ^detail}} = Resource.canonical(input),
             inspect(input)
    end
  end

  property "canonical/1 is idempotent" do
    check all(
            host <- string(?a..?z, min_length: 1, max_length: 10),
            port <- one_of([constant(nil), integer(1..65_535)]),
            segments <-
              list_of(string(Enum.concat([?a..?z, ?A..?Z, ?0..?9]), min_length: 1, max_length: 5),
                max_length: 3
              ),
            slash <- boolean()
          ) do
      url =
        "https://" <>
          String.upcase(host) <>
          ".example" <>
          if(port, do: ":#{port}", else: "") <>
          Enum.map_join(segments, &("/" <> &1)) <> if(slash, do: "/", else: "")

      assert {:ok, canonical} = Resource.canonical(url)
      assert Resource.canonical(canonical) == {:ok, canonical}
      refute String.ends_with?(canonical, "/")
      refute canonical =~ ~r/:443(\/|$)/
    end
  end
end

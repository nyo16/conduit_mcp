defmodule ConduitMcp.Client.OAuth.PendingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.OAuth.{Error, Pending, PKCE}
  alias ConduitMcp.Client.Secret

  @base [
    redirect_uri: "http://127.0.0.1:33418/callback",
    issuer: "https://auth.example.com",
    resource: "https://mcp.example.com/mcp"
  ]

  test "new/1 generates 32-byte state and verifier as Secrets with a 10 minute TTL" do
    pending = Pending.new(@base ++ [now: 1_000])

    for secret <- [pending.state, pending.verifier] do
      assert Secret.secret?(secret)

      assert {:ok, <<_::binary-size(32)>>} =
               secret |> Secret.expose() |> Base.url_decode64(padding: false)
    end

    assert pending.created_at == 1_000
    assert pending.expires_at == 1_600
    assert pending.scopes == []
    assert pending.principal == nil
    refute pending.iss_parameter_supported
    assert Pending.code_challenge(pending) == PKCE.challenge(pending.verifier)
    refute Pending.expired?(pending, 1_599)
    assert Pending.expired?(pending, 1_600)

    other = Pending.new(@base)
    refute Secret.expose(other.state) == Secret.expose(pending.state)
    refute Secret.expose(other.verifier) == Secret.expose(pending.verifier)
  end

  test "inspect never shows state or verifier" do
    pending = Pending.new(@base)
    rendered = inspect(pending, limit: :infinity)

    refute rendered =~ Secret.expose(pending.state)
    refute rendered =~ Secret.expose(pending.verifier)
  end

  test "redirect URIs must be https or loopback http, without a fragment" do
    for ok <- [
          "https://app.example.com/cb",
          "http://127.0.0.1:1/cb",
          "http://[::1]:2/cb",
          "http://localhost:3/cb"
        ] do
      assert %Pending{redirect_uri: ^ok} = Pending.new(Keyword.put(@base, :redirect_uri, ok))
    end

    for bad <- [
          "http://app.example.com/cb",
          "https://app.example.com/cb#x",
          "javascript:alert(1)",
          "com.example:/cb",
          nil
        ] do
      assert_raise NimbleOptions.ValidationError, fn ->
        Pending.new(Keyword.put(@base, :redirect_uri, bad))
      end
    end

    assert_raise NimbleOptions.ValidationError, fn ->
      Pending.new(Keyword.delete(@base, :issuer))
    end
  end

  property "to_map/1 and from_map/1 round-trip, also through JSON" do
    check all(
            scopes <- list_of(string(:alphanumeric, min_length: 1), max_length: 4),
            principal <- one_of([constant(nil), string(:printable)]),
            iss? <- boolean(),
            client_id <- one_of([constant(nil), string(:alphanumeric)]),
            ttl <- integer(1..86_400),
            now <- integer(0..2_000_000_000)
          ) do
      pending =
        Pending.new(
          @base ++
            [
              scopes: scopes,
              principal: principal,
              iss_parameter_supported: iss?,
              client_id: client_id,
              token_endpoint: "https://auth.example.com/token",
              ttl: ttl,
              now: now
            ]
        )

      map = Pending.to_map(pending)
      assert Enum.all?(Map.keys(map), &is_binary/1)
      assert Pending.from_map(map) == {:ok, pending}
      assert map |> JSON.encode!() |> JSON.decode!() |> Pending.from_map() == {:ok, pending}
    end
  end

  test "from_map/1 rejects missing and malformed fields without echoing values" do
    map = Pending.to_map(Pending.new(@base))

    for {key, value} <- [
          {"v", 2},
          {"state", ""},
          {"state", 1},
          {"code_verifier", "short"},
          {"redirect_uri", "http://evil.example/cb"},
          {"issuer", nil},
          {"resource", 1},
          {"scopes", "a b"},
          {"iss_parameter_supported", "true"},
          {"client_id", 1},
          {"token_endpoint", 1},
          {"created_at", "now"},
          {"expires_at", map["created_at"] - 1}
        ] do
      assert {:error, %Error{reason: :invalid_pending, data: %{field: ^key}} = error} =
               Pending.from_map(Map.put(map, key, value))

      refute inspect(error) =~ map["state"]
    end

    assert {:error, %Error{reason: :invalid_pending, data: %{field: "state"}}} =
             Pending.from_map(Map.delete(map, "state"))

    assert {:error, %Error{reason: :invalid_pending}} = Pending.from_map(nil)
  end
end

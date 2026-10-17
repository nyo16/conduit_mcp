defmodule ConduitMcp.Client.OAuth.PKCETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.OAuth.{Error, PKCE}
  alias ConduitMcp.Client.Secret

  doctest ConduitMcp.Client.OAuth.PKCE

  test "OA-1: RFC 7636 Appendix B vector" do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert PKCE.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    assert PKCE.challenge(Secret.new(verifier)) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    assert PKCE.method() == "S256"
  end

  property "verifiers are 43 base64url characters from 32 random bytes, and unique" do
    check all(_ <- constant(nil), max_runs: 50) do
      verifier = PKCE.verifier()
      assert byte_size(verifier) == 43
      assert verifier =~ ~r/^[A-Za-z0-9_-]{43}$/
      assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(verifier, padding: false)
      assert PKCE.valid_verifier?(verifier)
      assert byte_size(PKCE.challenge(verifier)) == 43
    end

    assert 100 == 1..100 |> Enum.map(fn _ -> PKCE.verifier() end) |> Enum.uniq() |> length()
  end

  test "challenge/1 refuses verifiers outside RFC 7636 §4.1" do
    for bad <- [
          String.duplicate("a", 42),
          String.duplicate("a", 129),
          String.duplicate("a", 42) <> "=",
          String.duplicate("é", 43)
        ] do
      refute PKCE.valid_verifier?(bad)
      assert_raise ArgumentError, fn -> PKCE.challenge(bad) end
    end

    assert PKCE.valid_verifier?(String.duplicate("a-._~", 25) <> "abc")
    refute PKCE.valid_verifier?(nil)
  end

  describe "OA-1: S256 is required" do
    test "missing, plain-only, lowercase or malformed lists are refused" do
      for metadata <- [
            %{},
            %{"code_challenge_methods_supported" => []},
            %{"code_challenge_methods_supported" => ["plain"]},
            %{"code_challenge_methods_supported" => ["s256"]},
            %{"code_challenge_methods_supported" => "S256"},
            %{"code_challenge_methods_supported" => nil}
          ] do
        refute PKCE.s256_supported?(metadata)
        assert %Error{reason: :pkce_unsupported} = catch_error(PKCE.ensure_s256!(metadata))
      end
    end

    test "S256 in the list is accepted" do
      assert :ok = PKCE.ensure_s256!(%{"code_challenge_methods_supported" => ["plain", "S256"]})
    end
  end
end

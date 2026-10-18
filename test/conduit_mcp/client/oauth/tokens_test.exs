defmodule ConduitMcp.Client.OAuth.TokensTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.OAuth.{Error, Tokens}
  alias ConduitMcp.Client.Secret

  doctest ConduitMcp.Client.OAuth.Tokens
  doctest ConduitMcp.Client.OAuth.Error

  test "new/1 wraps tokens in Secret and inspect hides them" do
    tokens =
      Tokens.new(
        access_token: "at-SECRET",
        refresh_token: "rt-SECRET",
        scopes: ["a"],
        expires_at: 10
      )

    assert Secret.expose(tokens.access_token) == "at-SECRET"
    assert Secret.expose(tokens.refresh_token) == "rt-SECRET"
    assert tokens.token_type == "Bearer"
    refute inspect(tokens, limit: :infinity) =~ "SECRET"

    assert Tokens.new(access_token: Secret.new("x")).access_token == Secret.new("x")
    assert Tokens.new(access_token: "x").refresh_token == nil
  end

  test "new/1 rejects invalid fields" do
    for fields <- [
          [],
          [access_token: ""],
          [access_token: 1],
          [access_token: "a", refresh_token: ""],
          [access_token: "a", expires_at: "soon"],
          [access_token: "a", scopes: "a b"],
          [access_token: "a", token_type: nil]
        ] do
      assert_raise ArgumentError, fn -> Tokens.new(fields) end
    end

    assert_raise KeyError, fn -> Tokens.new(access_token: "a", bogus: 1) end
  end

  test "expired?/3" do
    tokens = Tokens.new(access_token: "a", expires_at: 100)
    refute Tokens.expired?(tokens, 99)
    assert Tokens.expired?(tokens, 100)
    refute Tokens.expired?(tokens, 69, 30)
    assert Tokens.expired?(tokens, 70, 30)
    refute Tokens.expired?(Tokens.new(access_token: "a"), 1_000_000, 30)
  end

  describe "Error" do
    test "every reason builds; unknown reasons raise" do
      for reason <- Error.reasons() do
        assert Exception.message(Error.new(reason)) =~ Atom.to_string(reason)
      end

      assert_raise ArgumentError, fn -> Error.new(:nope) end
    end

    property "the message never renders data" do
      check all(
              reason <- member_of(Error.reasons()),
              secret <- string(:alphanumeric, min_length: 12)
            ) do
        error = Error.new(reason, %{"error_description" => secret, token: Secret.new(secret)})
        refute Exception.message(error) =~ secret
      end
    end
  end
end

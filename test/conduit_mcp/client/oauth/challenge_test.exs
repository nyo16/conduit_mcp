defmodule ConduitMcp.Client.OAuth.ChallengeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.OAuth.{Challenge, Error}

  doctest ConduitMcp.Client.OAuth.Challenge

  defp parse!(value) do
    assert {:ok, challenges} = Challenge.parse(value)
    challenges
  end

  defp detail(value) do
    assert {:error, %Error{reason: :invalid_challenge, data: detail}} = Challenge.parse(value)
    detail
  end

  defp c(scheme, params \\ %{}, token68 \\ nil),
    do: %Challenge{scheme: scheme, params: params, token68: token68}

  describe "parse/1 well-formed input" do
    test "the MCP 401 shape" do
      header =
        ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", ) <>
          ~s(scope="files:read files:write")

      assert [challenge] = parse!(header)
      assert challenge.scheme == "bearer"

      assert Challenge.resource_metadata(challenge) ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

      assert Challenge.scopes(challenge) == ["files:read", "files:write"]
      assert Challenge.error(challenge) == nil
      refute Challenge.insufficient_scope?(challenge)
    end

    test "the 403 step-up shape" do
      [challenge] =
        parse!(
          ~s(Bearer error="insufficient_scope", scope="admin", error_description="need \\"admin\\"")
        )

      assert Challenge.insufficient_scope?(challenge)
      assert Challenge.error_description(challenge) == ~s(need "admin")
      assert Challenge.scopes(challenge) == ["admin"]
    end

    test "several challenges in one header, Bearer mixed with DPoP and Basic" do
      header = ~s(DPoP algs="ES256 PS256", Basic realm="api", Bearer realm="mcp", scope="a")

      assert parse!(header) == [
               c("dpop", %{"algs" => "ES256 PS256"}),
               c("basic", %{"realm" => "api"}),
               c("bearer", %{"realm" => "mcp", "scope" => "a"})
             ]

      assert Challenge.bearer(parse!(header)) == c("bearer", %{"realm" => "mcp", "scope" => "a"})
    end

    test "challenges across several header values keep their order" do
      assert parse!([~s(Basic realm="x"), "Bearer scope=a", "Negotiate"]) == [
               c("basic", %{"realm" => "x"}),
               c("bearer", %{"scope" => "a"}),
               c("negotiate")
             ]
    end

    test "scheme and parameter names are case-insensitive and stored lowercase" do
      [challenge] = parse!(~s(bEaReR Resource_Metadata="https://x.example/prm", SCOPE=a))
      assert challenge.scheme == "bearer"
      assert challenge.params == %{"resource_metadata" => "https://x.example/prm", "scope" => "a"}
      assert Challenge.param(challenge, "RESOURCE_METADATA") == "https://x.example/prm"
      assert Challenge.bearer([challenge]) == challenge
    end

    test "values keep their case and bytes" do
      assert [%{params: %{"realm" => "MiXeD Case é"}}] = parse!(~s(Bearer realm="MiXeD Case é"))
    end

    test "commas, equals signs and spaces inside quoted values are data" do
      assert parse!(~s(Bearer realm="a, b=c, Basic d", scope="x")) ==
               [c("bearer", %{"realm" => "a, b=c, Basic d", "scope" => "x"})]
    end

    test "quoted-pair escapes" do
      assert [%{params: %{"realm" => ~s(a"b\\c d)}}] = parse!(~S(Bearer realm="a\"b\\c\ d"))
    end

    test "bad whitespace around = and empty list elements" do
      assert parse!(~s(, ,Bearer  realm = "x" ,, , scope=\ty , ,)) ==
               [c("bearer", %{"realm" => "x", "scope" => "y"})]
    end

    test "token68" do
      assert parse!("Basic dXNlcjpwYXNz") == [c("basic", %{}, "dXNlcjpwYXNz")]

      assert parse!("Negotiate abc==, Bearer realm=x") == [
               c("negotiate", %{}, "abc=="),
               c("bearer", %{"realm" => "x"})
             ]
    end

    test "empty quoted value and scheme-only challenges" do
      assert parse!(~s(Bearer realm="")) == [c("bearer", %{"realm" => ""})]
      assert parse!("Bearer") == [c("bearer")]
      assert parse!("Bearer, Basic") == [c("bearer"), c("basic")]
      assert parse!("") == []
      assert parse!([]) == []
    end

    test "a parameter with an empty unquoted value reads as token68, per the grammar" do
      assert parse!("Bearer realm=") == [c("bearer", %{}, "realm=")]
    end

    test "bearer/1 takes the first Bearer challenge and nil when there is none" do
      assert Challenge.bearer(parse!("Bearer scope=a, Bearer scope=b")).params == %{
               "scope" => "a"
             }

      assert Challenge.bearer(parse!(~s(Basic realm="x"))) == nil
      assert Challenge.scopes(c("bearer")) == []
    end
  end

  describe "parse/1 adversarial input" do
    test "unterminated quotes" do
      assert detail(~s(Bearer realm="abc)) == :unterminated_quote
      assert detail(~s(Bearer realm="abc\\)) == :unterminated_quote
      assert detail(~s(Bearer realm=")) == :unterminated_quote
      assert detail(~s(Bearer realm="a", scope="b, Basic realm=c)) == :unterminated_quote
    end

    test "duplicate parameters are rejected, compared case-insensitively" do
      assert detail("Bearer scope=a, scope=b") == :duplicate_param

      assert detail(~s(Bearer resource_metadata="https://a", Resource_Metadata="https://b")) ==
               :duplicate_param
    end

    test "control characters cannot be smuggled, quoted or not" do
      assert detail("Bearer realm=x\r\nSet-Cookie: a=b") == :malformed
      assert detail(~s(Bearer realm="x\r\ny")) == :malformed
      assert detail(~s(Bearer realm="x\0y")) == :malformed
      assert detail("Bearer\nrealm=x") == :malformed
    end

    test "structural garbage" do
      for value <- [
            "=x",
            "Bearer =x",
            "Bearer a=b c",
            "Bearer a==b",
            "Bearer a=\"b\"c",
            "Bearer a=b=c",
            "Bearer \"x\"",
            "Bearer\"x\"",
            "Bearer a=b, =c",
            "Bearer abc def",
            "Bearer realm=x, \"y\"",
            "(Bearer)"
          ] do
        assert {:error, %Error{reason: :invalid_challenge}} = Challenge.parse(value), value
      end
    end

    test "quoted values must be valid UTF-8" do
      assert detail(<<"Bearer realm=\"", 0xFF, "\"">>) == :invalid_encoding
    end

    test "input over 8 KiB, in one value or across values, is refused before parsing" do
      big = "Bearer realm=\"" <> String.duplicate("a", 8200) <> "\""
      assert detail(big) == :too_large
      assert detail(List.duplicate(String.duplicate("a", 3000), 3)) == :too_large
      assert {:ok, _} = Challenge.parse("Bearer realm=\"" <> String.duplicate("a", 8000) <> "\"")
    end

    test "parameter and challenge counts are capped" do
      params = Enum.map_join(1..33, ", ", &"p#{&1}=v")
      assert detail("Bearer " <> params) == :too_many_params

      assert {:ok, [%{params: p}]} =
               Challenge.parse("Bearer " <> Enum.map_join(1..32, ", ", &"p#{&1}=v"))

      assert map_size(p) == 32

      assert detail(Enum.map_join(1..17, ", ", &"S#{&1}")) == :too_many_challenges
      assert detail(List.duplicate("A, B", 9)) == :too_many_challenges
      assert length(parse!(Enum.map_join(1..16, ", ", &"S#{&1}"))) == 16
    end

    test "non-string input" do
      assert detail(nil) == :invalid_input
      assert detail(["Bearer", 1]) == :invalid_input
      assert detail(%{}) == :invalid_input
    end
  end

  describe "properties" do
    @tchars Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c"!#$%&'*+-.^_`|~"])
    @token68_chars Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c"-._~+/"])
    @value_chars [?\t, 0x20..0x7E, 0xA0..0x2FF, 0x4E00..0x4E2F]

    defp token_gen, do: string(@tchars, min_length: 1, max_length: 12)

    defp challenge_gen do
      bind(token_gen(), fn scheme ->
        one_of([
          constant(c(String.downcase(scheme), %{}, nil) |> Map.put(:raw_scheme, scheme)),
          map(
            {string(@token68_chars, min_length: 1, max_length: 20), string([?=], max_length: 2)},
            fn {chars, pad} ->
              c(String.downcase(scheme), %{}, chars <> pad) |> Map.put(:raw_scheme, scheme)
            end
          ),
          map(
            uniq_list_of({token_gen(), string(@value_chars, max_length: 30)},
              min_length: 1,
              max_length: 6,
              uniq_fun: fn {name, _} -> String.downcase(name) end
            ),
            fn params ->
              String.downcase(scheme)
              |> c(Map.new(params, fn {k, v} -> {String.downcase(k), v} end))
              |> Map.put(:raw_scheme, scheme)
              |> Map.put(:raw_params, params)
            end
          )
        ])
      end)
    end

    defp ows_gen, do: string([?\s, ?\t], max_length: 2)

    defp render_value(value) do
      gen all(bare? <- boolean()) do
        if bare? and value != "" and String.match?(value, ~r/^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$/) do
          value
        else
          ~s(") <> String.replace(value, ~r/(["\\])/, "\\\\\\1") <> ~s(")
        end
      end
    end

    defp render_challenge(challenge) do
      case challenge do
        %{raw_params: params} ->
          gen all(
                rendered <-
                  fixed_list(
                    Enum.map(params, fn {name, value} ->
                      gen all(v <- render_value(value), l <- ows_gen(), r <- ows_gen()) do
                        name <> l <> "=" <> r <> v
                      end
                    end)
                  ),
                seps <- list_of(sep_gen(), length: length(params))
              ) do
            challenge.raw_scheme <> " " <> join_with(rendered, seps)
          end

        %{token68: t68} when is_binary(t68) ->
          constant(challenge.raw_scheme <> " " <> t68)

        _ ->
          constant(challenge.raw_scheme)
      end
    end

    defp sep_gen,
      do:
        map({ows_gen(), integer(1..3), ows_gen()}, fn {l, n, r} ->
          l <> String.duplicate(",", n) <> r
        end)

    defp join_with([first | rest], seps),
      do:
        Enum.zip(rest, seps) |> Enum.reduce(first, fn {item, sep}, acc -> acc <> sep <> item end)

    defp strip(challenge), do: Map.drop(challenge, [:raw_scheme, :raw_params])

    property "rendered challenges parse back, whatever the separators and name case" do
      check all(
              challenges <- list_of(challenge_gen(), min_length: 1, max_length: 5),
              rendered <- fixed_list(Enum.map(challenges, &render_challenge/1)),
              seps <- list_of(sep_gen(), length: length(challenges)),
              lead <- ows_gen(),
              trail <- ows_gen()
            ) do
        header = lead <> join_with(rendered, seps) <> trail
        assert {:ok, parsed} = Challenge.parse(header), inspect(header)
        assert parsed == Enum.map(challenges, &strip/1)

        # One challenge per header value gives the same result.
        assert Challenge.parse(rendered) == {:ok, parsed}
      end
    end

    property "never raises on arbitrary bytes" do
      check all(
              value <-
                one_of([binary(max_length: 200), string(~c"Bb =,\"\\ \taz\r\n", max_length: 60)])
            ) do
        case Challenge.parse(value) do
          {:ok, challenges} -> assert Enum.all?(challenges, &match?(%Challenge{}, &1))
          {:error, %Error{reason: :invalid_challenge}} -> :ok
        end
      end
    end

    property "anything over 8192 bytes is too large" do
      check all(extra <- integer(1..100), byte <- member_of(~c"a ,\"=")) do
        assert detail(:binary.copy(<<byte>>, 8192 + extra)) == :too_large
      end
    end
  end
end

defmodule ConduitMcp.MRTR.StateTest do
  # async: false — mutates the global :mrtr_keys application env.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ConduitMcp.MRTR.State

  @old {"k1", :binary.copy(<<1>>, 32)}
  @new {"k2", :binary.copy(<<2>>, 32)}
  @now 1_700_000_000_000

  @binding %{
    version: "2026-07-28",
    method: "tools/call",
    params: %{
      "name" => "deploy",
      "arguments" => %{"target" => "prod", "n" => 1},
      "_meta" => %{"progressToken" => 1}
    },
    principal: "sub:alice"
  }

  setup do
    previous = Application.fetch_env(:conduit_mcp, :mrtr_keys)
    Application.put_env(:conduit_mcp, :mrtr_keys, [@old])

    on_exit(fn ->
      case previous do
        {:ok, keys} -> Application.put_env(:conduit_mcp, :mrtr_keys, keys)
        :error -> Application.delete_env(:conduit_mcp, :mrtr_keys)
      end
    end)
  end

  defp seal(state \\ %{"step" => "approve"}, binding \\ @binding),
    do: State.seal(state, binding, now: @now)

  defp open(token, binding \\ @binding, now \\ @now), do: State.open(token, binding, now: now)

  test "round-trips and decodes atoms as strings" do
    token = seal(%{step: :awaiting, target: "prod"})
    assert {:ok, %{"step" => "awaiting", "target" => "prod"}} = open(token)
    assert String.starts_with?(token, "k1.")
    refute token =~ "awaiting"
  end

  test "rounds that only change _meta, inputResponses or requestState still open" do
    token = seal()

    params =
      @binding.params
      |> Map.put("_meta", %{"other" => true})
      |> Map.put("inputResponses", %{"approval" => %{"action" => "accept"}})
      |> Map.put("requestState", token)

    assert {:ok, _} = open(token, %{@binding | params: params})
  end

  test "param key order does not matter" do
    token = seal()
    reordered = Map.new(Enum.reverse(Map.to_list(@binding.params)))
    assert {:ok, _} = open(token, %{@binding | params: reordered})
  end

  describe "every failure is the identical :error" do
    setup do
      %{token: seal()}
    end

    test "tampering, binding mismatch, expiry, kid and size", %{token: token} do
      [kid, body] = String.split(token, ".", parts: 2)
      raw = Base.url_decode64!(body, padding: false)

      flip = fn bin, at ->
        :crypto.exor(bin, <<0::size(at * 8), 1, 0::size((byte_size(bin) - at - 1) * 8)>>)
      end

      failures = [
        bit_flip_ciphertext:
          open(kid <> "." <> Base.url_encode64(flip.(raw, byte_size(raw) - 1), padding: false)),
        bit_flip_iv: open(kid <> "." <> Base.url_encode64(flip.(raw, 0), padding: false)),
        wrong_principal: open(token, %{@binding | principal: "sub:mallory"}),
        nil_principal: open(token, %{@binding | principal: nil}),
        expired: open(token, @binding, @now + :timer.minutes(5)),
        wrong_method: open(token, %{@binding | method: "prompts/get"}),
        wrong_version: open(token, %{@binding | version: "2025-11-25"}),
        wrong_args: open(token, put_in(@binding, [:params, "arguments", "target"], "dev")),
        wrong_tool: open(token, put_in(@binding, [:params, "name"], "other")),
        unknown_kid: open("k9." <> body),
        swapped_kid: open("k2." <> body),
        truncated: open(binary_part(token, 0, byte_size(token) - 4)),
        too_short: open(kid <> ".AAAA"),
        no_separator: open(body),
        bad_base64: open(kid <> ".***"),
        oversize: open(token <> String.duplicate("A", 64 * 1024)),
        non_binary: open(nil)
      ]

      for {name, result} <- failures, do: assert({name, result} == {name, :error})
    end

    test "unknown kid when the key is configured under another kid", %{token: token} do
      Application.put_env(:conduit_mcp, :mrtr_keys, [@new])
      assert open(token) == :error
    end
  end

  test "expiry is 5 minutes, 60 seconds without a principal" do
    token = seal()
    assert {:ok, _} = open(token, @binding, @now + :timer.minutes(5) - 1)

    anon = %{@binding | principal: nil}
    anon_token = seal(%{}, anon)
    assert {:ok, _} = open(anon_token, anon, @now + :timer.seconds(60) - 1)
    assert :error = open(anon_token, anon, @now + :timer.seconds(60))
  end

  test "rotation: old tokens open while the old key is second, fail once removed" do
    token = seal()

    Application.put_env(:conduit_mcp, :mrtr_keys, [@new, @old])
    assert {:ok, _} = open(token)
    assert String.starts_with?(seal(), "k2.")

    Application.put_env(:conduit_mcp, :mrtr_keys, [@new])
    assert open(token) == :error
  end

  test "seal raises a pointed error when :mrtr_keys is not configured" do
    Application.delete_env(:conduit_mcp, :mrtr_keys)
    assert_raise ArgumentError, ~r/:mrtr_keys/, fn -> seal() end
    assert open("k1.AAAA") == :error
  end

  test "seal rejects non-JSON terms" do
    for {bad, kind} <- [
          {{:a, 1}, "tuple"},
          {self(), "pid"},
          {make_ref(), "reference"},
          {fn -> :ok end, "function"},
          {%{"x" => [1, {2}]}, "tuple"},
          {%{{1} => 1}, "tuple"},
          {<<255>>, "non-UTF-8"},
          {[1 | 2], "improper list"},
          {URI.parse("http://x"), "struct URI"}
        ] do
      assert_raise ArgumentError, ~r/JSON-encodable.*#{kind}/, fn -> seal(bad) end
    end
  end

  property "any JSON-native term round-trips" do
    check all(state <- json_term()) do
      assert {:ok, ^state} = open(seal(state))
    end
  end

  defp json_term do
    leaf =
      one_of([
        constant(nil),
        boolean(),
        integer(),
        float(),
        string(:printable)
      ])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 4), map_of(string(:printable), child, max_length: 4)])
    end)
  end

  describe "validate_keys!/1" do
    test "accepts a well-formed keyring" do
      assert :ok = State.validate_keys!([@new, @old])
    end

    test "rejects malformed keyrings without echoing key bytes" do
      secret = "short-secret-key-bytes"

      for bad <- [
            [],
            :nope,
            [{"k1", secret}],
            [{"", elem(@old, 1)}],
            [{"a.b", elem(@old, 1)}],
            [{:k1, elem(@old, 1)}],
            [elem(@old, 1)],
            [@old, {"k1", elem(@new, 1)}]
          ] do
        error = assert_raise ArgumentError, fn -> State.validate_keys!(bad) end
        assert error.message =~ ":mrtr_keys"
        refute error.message =~ secret
        refute error.message =~ elem(@old, 1)
      end
    end
  end
end

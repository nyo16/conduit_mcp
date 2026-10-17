defmodule ConduitMcp.Client.Transport.Stdio.FramerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.Transport.Stdio.Framer

  doctest ConduitMcp.Client.Transport.Stdio.Framer

  defp feed_all(chunks, opts \\ []) do
    Enum.reduce(chunks, {[], 0, Framer.new(opts)}, fn chunk, {acc, errors, framer} ->
      case Framer.feed(framer, chunk) do
        {:ok, messages, framer} -> {acc ++ messages, errors, framer}
        {:error, :message_too_large, messages, framer} -> {acc ++ messages, errors + 1, framer}
      end
    end)
  end

  defp split_at(binary, cuts) do
    cuts = cuts |> Enum.uniq() |> Enum.sort()

    {chunks, from} =
      Enum.reduce(cuts, {[], 0}, fn cut, {acc, from} ->
        {[binary_part(binary, from, cut - from) | acc], cut}
      end)

    Enum.reverse([binary_part(binary, from, byte_size(binary) - from) | chunks])
  end

  test "frames LF and CRLF messages, skipping blank lines" do
    {messages, 0, framer} = feed_all(["{\"a\":1}\n\r\n\n{\"b\":2}\r\n{\"c\""])
    assert messages == [~s({"a":1}), ~s({"b":2})]
    assert Framer.buffered_bytes(framer) == 4
  end

  test "only one trailing CR is stripped; inner CRs are kept" do
    {messages, 0, _} = feed_all(["a\rb\r\r\n"])
    assert messages == ["a\rb\r"]
  end

  test "a CRLF split between chunks frames like an unsplit one" do
    {messages, 0, _} = feed_all(["{}\r", "\n{}", "\r", "\n"])
    assert messages == ["{}", "{}"]
  end

  test "an oversized message is reported as soon as it passes the cap, then resyncs" do
    framer = Framer.new(max_message_bytes: 8)

    assert {:ok, ["ok"], framer} = Framer.feed(framer, "ok\n12345")
    assert {:error, :message_too_large, [], framer} = Framer.feed(framer, "67890")
    assert Framer.buffered_bytes(framer) == 0

    # Still inside the oversized line: dropped silently, reported once.
    assert {:ok, [], framer} = Framer.feed(framer, String.duplicate("x", 100))
    assert {:ok, ["next"], framer} = Framer.feed(framer, "tail\nnext\n")
    assert Framer.buffered_bytes(framer) == 0
  end

  test "an oversized message inside one chunk drops only itself" do
    framer = Framer.new(max_message_bytes: 4)

    assert {:error, :message_too_large, ["a", "b"], _} =
             Framer.feed(framer, "a\n123456789\nb\n")
  end

  test "the cap counts message bytes, not the CR or LF" do
    assert {["1234", "abcd"], 0, _} = feed_all(["1234\r\nab", "cd\r", "\n"], max_message_bytes: 4)
    assert {[], 1, _} = feed_all(["12345\r\n"], max_message_bytes: 4)
    assert {[], 1, _} = feed_all(["1234", "5\r", "\n"], max_message_bytes: 4)
  end

  test "invalid max_message_bytes raises" do
    assert_raise ArgumentError, fn -> Framer.new(max_message_bytes: 0) end
  end

  describe "properties" do
    defp message_gen do
      StreamData.binary(min_length: 1, max_length: 40)
      |> StreamData.map(&String.replace(&1, "\n", ""))
      |> StreamData.map(&String.trim_trailing(&1, "\r"))
      |> StreamData.filter(&(&1 != ""))
    end

    property "any chunk split yields the same messages, for LF and CRLF" do
      check all(
              messages <- StreamData.list_of(message_gen(), max_length: 15),
              eol <- StreamData.member_of(["\n", "\r\n"]),
              stream = Enum.map_join(messages, &(&1 <> eol)),
              cuts <- StreamData.list_of(StreamData.integer(0..byte_size(stream)), max_length: 15)
            ) do
        assert {^messages, 0, _} = feed_all(split_at(stream, cuts))
        assert {^messages, 0, _} = feed_all(for <<b <- stream>>, do: <<b>>)
      end
    end

    property "oversized messages are dropped and every other message survives" do
      check all(
              messages <- StreamData.list_of(message_gen(), min_length: 1, max_length: 15),
              max <- StreamData.integer(1..40),
              stream = Enum.map_join(messages, &(&1 <> "\n")),
              cuts <- StreamData.list_of(StreamData.integer(0..byte_size(stream)), max_length: 10)
            ) do
        {framed, errors, framer} = feed_all(split_at(stream, cuts), max_message_bytes: max)

        assert framed == Enum.filter(messages, &(byte_size(&1) <= max))
        oversized = Enum.count(messages, &(byte_size(&1) > max))
        assert errors >= min(oversized, 1) and errors <= oversized
        assert Framer.buffered_bytes(framer) == 0
      end
    end
  end
end

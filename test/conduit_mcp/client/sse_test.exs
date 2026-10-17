defmodule ConduitMcp.Client.SSETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConduitMcp.Client.SSE
  alias ConduitMcp.Client.SSE.Event

  doctest ConduitMcp.Client.SSE

  defp parse(stream, opts \\ []) do
    {:ok, events, state} = SSE.feed(SSE.new(opts), stream)
    {events, state}
  end

  defp parse_chunks(chunks, opts \\ []) do
    Enum.reduce(chunks, {[], SSE.new(opts)}, fn chunk, {acc, state} ->
      {:ok, events, state} = SSE.feed(state, chunk)
      {acc ++ events, state}
    end)
  end

  defp summary({events, state}),
    do: {events, SSE.last_event_id(state), SSE.retry(state), SSE.comments(state)}

  defp split_at(binary, cuts) do
    cuts
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce({[], 0}, fn cut, {acc, from} ->
      {[binary_part(binary, from, cut - from) | acc], cut}
    end)
    |> then(fn {acc, from} ->
      Enum.reverse([binary_part(binary, from, byte_size(binary) - from) | acc])
    end)
  end

  describe "WHATWG examples" do
    test "multi-line data joins with LF" do
      {[event], _} = parse("data: YHOO\ndata: +2\ndata: 10\n\n")
      assert event == %Event{type: "message", data: "YHOO\n+2\n10", id: nil}
    end

    test "comments, id set and reset, and one leading space stripped" do
      stream =
        ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n"

      {events, state} = parse(stream)

      assert events == [
               %Event{type: "message", data: "first event", id: "1"},
               %Event{type: "message", data: "second event", id: nil},
               %Event{type: "message", data: " third event", id: nil}
             ]

      assert SSE.comments(state) == 1
    end

    test "empty-data events are not dispatched and a trailing incomplete event is dropped" do
      {events, _} = parse("data\n\ndata\ndata\n\ndata:")
      assert events == [%Event{type: "message", data: "\n", id: nil}]
    end

    test "a field with no space after the colon and with one space are the same" do
      {events, _} = parse("data:test\n\ndata: test\n\n")
      assert Enum.map(events, & &1.data) == ["test", "test"]
    end
  end

  describe "fields" do
    test "event sets the type for one event; empty type is message" do
      {events, _} = parse("event: ping\ndata: 1\n\nevent:\ndata: 2\n\ndata: 3\n\n")
      assert Enum.map(events, & &1.type) == ["ping", "message", "message"]
    end

    test "an id containing NUL is ignored" do
      {events, state} = parse("id: 5\ndata: a\n\nid: 6\0x\ndata: b\n\n")
      assert Enum.map(events, & &1.id) == ["5", "5"]
      assert SSE.last_event_id(state) == "5"
    end

    test "an id-only event (MCP priming) dispatches nothing but updates last_event_id" do
      {[], state} = parse("id: prime-1\ndata:\n\n")
      assert SSE.last_event_id(state) == "prime-1"

      {[], state} = parse("id: 42\n\n")
      assert SSE.last_event_id(state) == "42"
    end

    test "last_event_id is recorded at the blank line, not at the id line" do
      {[], state} = parse("id: 9\ndata: partial")
      assert SSE.last_event_id(state) == nil
    end

    test "retry accepts ASCII digits only" do
      {_, state} = parse("retry: 1500\n\n")
      assert SSE.retry(state) == 1500

      for bad <- ["retry: 1a\n", "retry: -1\n", "retry:  10\n", "retry:\n", "retry: 1.5\n"] do
        {_, state} = parse("retry: 7\n" <> bad)
        assert SSE.retry(state) == 7, "#{inspect(bad)} changed retry"
      end
    end

    test "unknown fields and colon-less unknown lines are ignored" do
      {[event], _} = parse("foo: bar\nbaz\ndata: ok\n\n")
      assert event.data == "ok"
    end
  end

  describe "line endings and BOM" do
    test "CR, LF and CRLF all end lines" do
      for eol <- ["\n", "\r", "\r\n"] do
        {[event], _} = parse(Enum.join(["data: a", "data: b", "", ""], eol))
        assert event.data == "a\nb", "eol #{inspect(eol)}"
      end
    end

    test "a CR at a chunk end and an LF opening the next are one line ending" do
      {events, _} = parse_chunks(["data: a\r", "\ndata: b\r", "\n\r", "\n"])
      assert Enum.map(events, & &1.data) == ["a\nb"]
    end

    test "a lone CR at a chunk end still ends the line" do
      {events, _} = parse_chunks(["data: a\r", "\r"])
      assert Enum.map(events, & &1.data) == ["a"]
    end

    test "a leading BOM is stripped once, even split across chunks" do
      bom = <<0xEF, 0xBB, 0xBF>>
      {[event], _} = parse_chunks([<<0xEF>>, <<0xBB>>, <<0xBF, "data: x\n\n">>])
      assert event.data == "x"

      # A second BOM is ordinary bytes: it makes the field name unknown.
      {events, _} = parse(bom <> bom <> "data: y\n\ndata: z\n\n")
      assert Enum.map(events, & &1.data) == ["z"]
    end

    test "bytes that only start like a BOM are kept, not dropped" do
      # The held 0xEF byte is replayed into the first line, which therefore
      # has an unknown field name, exactly as when the bytes arrive at once.
      assert parse_chunks([<<0xEF>>, "data: q\n\ndata: r\n\n"]) |> elem(0) ==
               parse(<<0xEF, "data: q\n\ndata: r\n\n">>) |> elem(0)

      {events, _} = parse_chunks([<<0xEF>>, "\ndata: r\n\n"])
      assert Enum.map(events, & &1.data) == ["r"]
    end
  end

  describe "limits" do
    test "an over-long line errors before its terminator arrives" do
      sse = SSE.new(max_line_bytes: 10)
      assert {:ok, [], sse} = SSE.feed(sse, "data: 1234")
      assert {:error, :event_too_large, sse} = SSE.feed(sse, "5")
      assert {:error, :event_too_large, _} = SSE.feed(sse, "\n\n")
    end

    test "an event over max_event_bytes across many data lines errors" do
      sse = SSE.new(max_event_bytes: 20)
      stream = String.duplicate("data: 12345\n", 3)
      assert {:ok, [], sse} = SSE.feed(sse, stream)
      assert {:error, :event_too_large, _} = SSE.feed(sse, "data: 12345\n")
    end

    test "an event exactly at the cap is fine" do
      # "12345\n12345" is 11 bytes of data.
      {[event], _} =
        parse("data: 12345\ndata: 12345\n\n", max_event_bytes: 11, max_line_bytes: 11)

      assert byte_size(event.data) == 11
    end

    test "keep-alive comments produce no events but are counted" do
      sse = SSE.new()
      assert {:ok, [], sse} = SSE.feed(sse, ":\n: ping\n")
      assert {:ok, [], sse} = SSE.feed(sse, ":keepalive\n")
      assert SSE.comments(sse) == 3
    end

    test "invalid limits raise" do
      assert_raise ArgumentError, fn -> SSE.new(max_line_bytes: 0) end
      assert_raise ArgumentError, fn -> SSE.new(max_event_bytes: :infinity) end
    end
  end

  describe "properties" do
    defp line_text do
      StreamData.string(:printable, max_length: 20)
      |> StreamData.map(&String.replace(&1, ["\r", "\n"], ""))
    end

    defp event_gen do
      StreamData.fixed_map(%{
        type: StreamData.one_of([StreamData.constant(nil), line_text()]),
        id: StreamData.one_of([StreamData.constant(nil), line_text()]),
        data: StreamData.list_of(line_text(), min_length: 1, max_length: 4),
        comment: StreamData.boolean()
      })
    end

    defp serialize(events, eol) do
      Enum.map_join(events, fn event ->
        [
          if(event.comment, do: [": keep-alive", eol], else: []),
          if(event.type, do: ["event: ", event.type, eol], else: []),
          if(event.id, do: ["id: ", String.replace(event.id, "\0", ""), eol], else: []),
          Enum.map(event.data, &["data: ", &1, eol]),
          eol
        ]
        |> IO.iodata_to_binary()
      end)
    end

    defp expected(events) do
      {acc, _id} =
        Enum.reduce(events, {[], nil}, fn event, {acc, last_id} ->
          id =
            case event.id && String.replace(event.id, "\0", "") do
              nil -> last_id
              "" -> nil
              id -> id
            end

          data = Enum.join(event.data, "\n")
          type = if event.type in [nil, ""], do: "message", else: event.type

          if data == "",
            do: {acc, id},
            else: {[%Event{type: type, data: data, id: id} | acc], id}
        end)

      Enum.reverse(acc)
    end

    property "parses generated streams to the modelled events for every line ending" do
      check all(
              events <- StreamData.list_of(event_gen(), max_length: 8),
              eol <- StreamData.member_of(["\n", "\r", "\r\n"])
            ) do
        {parsed, _state} = parse(serialize(events, eol))
        assert parsed == expected(events)
      end
    end

    property "any chunk split yields identical events, ids, retry and comment counts" do
      token =
        StreamData.one_of([
          StreamData.member_of([
            "\n",
            "\r",
            "\r\n",
            ": c",
            "data: ",
            "data:",
            "id: ",
            "id",
            "event: e",
            "retry: 12",
            "retry: x",
            <<0xEF, 0xBB, 0xBF>>,
            "\0"
          ]),
          StreamData.string(:printable, max_length: 6)
        ])

      check all(
              prefix <- StreamData.member_of(["", <<0xEF, 0xBB, 0xBF>>]),
              tokens <- StreamData.list_of(token, max_length: 40),
              stream = prefix <> Enum.join(tokens),
              cuts <- StreamData.list_of(StreamData.integer(0..byte_size(stream)), max_length: 12)
            ) do
        assert summary(parse_chunks(split_at(stream, cuts))) == summary(parse(stream))
        assert summary(parse_chunks(for <<b <- stream>>, do: <<b>>)) == summary(parse(stream))
      end
    end
  end
end

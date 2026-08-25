defmodule ConduitMcp.ReflectTest do
  use ExUnit.Case, async: true
  doctest ConduitMcp.Reflect

  alias ConduitMcp.Reflect

  describe "text/2" do
    test "passes plain strings through" do
      assert Reflect.text("tools/call") == "tools/call"
    end

    test "strips C0 control characters, DEL and C1" do
      assert Reflect.text("tools/call\x00\x01\x02") == "tools/call"
      assert Reflect.text("a\x7Fb") == "ab"
      assert Reflect.text("a\u0085b") == "ab"
    end

    test "strips tabs and newlines, which is what log forging needs" do
      assert Reflect.text("ok\r\n2026-01-01 [error] forged") == "ok2026-01-01 [error] forged"
      assert Reflect.text("a\tb") == "ab"
    end

    test "strips ANSI escape sequences' introducer" do
      refute Reflect.text("\e[31mred\e[0m") =~ "\e"
    end

    test "clamps to the default length" do
      assert Reflect.text(String.duplicate("a", 5_000)) |> String.length() == 200
    end

    test "clamps to an explicit length" do
      assert Reflect.text(String.duplicate("a", 500), 40) |> String.length() == 40
    end

    test "renders terms with no String.Chars implementation instead of raising" do
      # These are exactly the shapes that used to raise inside the handler and
      # get converted into a misleading "Internal server error".
      assert Reflect.text(%{}) == "%{}"
      assert Reflect.text({1, 2}) == "{1, 2}"
      assert Reflect.text(%{"a" => 1}) =~ "a"
      assert is_binary(Reflect.text(self()))
    end

    test "renders JSON arrays instead of raising or silently emptying them" do
      # `to_string/1` on a list raises ArgumentError (`[1.5]`, `[%{}]`) or
      # UnicodeConversionError (`[-1]`) — neither is Protocol.UndefinedError, so
      # the old rescue missed them and the exception escaped. JSON puts an array
      # wherever a scalar is expected, and the `notifications/cancelled` reason
      # path has no rescue of its own, so this was a bare 500.
      assert Reflect.text([1.5]) == "[1.5]"
      assert Reflect.text([%{}]) == "[%{}]"
      assert Reflect.text([-1]) == "[-1]"
      assert Reflect.text([]) == "[]"

      # `to_string([1, 2])` is "\x01\x02" — accepted by List.Chars, then stripped
      # to "" by the control-character pass. Rendering beats losing the value.
      assert Reflect.text([1, 2]) == "[1, 2]"
      assert Reflect.text(["a"]) == "[\"a\"]"
    end

    test "strips the remaining Unicode format and bidi controls" do
      # U+061C is the fourth Bidi_Control outside the U+200x/U+202x/U+206x
      # ranges and reorders a log line identically to U+200F.
      assert Reflect.text("a\u061Cb") == "ab"
      assert Reflect.text("a\u2060b") == "ab"
      assert Reflect.text("a\uFEFFb") == "ab"
    end

    test "renders scalars that do implement String.Chars" do
      assert Reflect.text(42) == "42"
      assert Reflect.text(:atom) == "atom"
      assert Reflect.text(nil) == ""
    end

    test "clamps an oversized inspected term too" do
      big = Map.new(1..5_000, fn i -> {"key-#{i}", i} end)
      assert Reflect.text(big) |> String.length() <= 200
    end

    test "a multibyte value longer than the byte clamp does not raise" do
      # The byte clamp cuts at `max * 4`, mid-codepoint for any multibyte
      # value that long. `:re` with the unicode option *raises* on invalid
      # UTF-8, so without repairing the tail this raised ArgumentError - and
      # the handler's rescue reflects the method name again, so it raised a
      # second time from inside the rescue: no JSON-RPC response at all.
      out = Reflect.text(String.duplicate("€", 300))

      assert String.valid?(out)
      assert String.length(out) == 200
    end

    test "every multibyte length around the clamp boundary stays valid" do
      # 3-byte and 4-byte codepoints put the cut at a different offset within
      # the sequence, so walk both across the boundary.
      for char <- ["€", "𝄞"], n <- 195..215 do
        out = Reflect.text(String.duplicate(char, n))

        assert String.valid?(out), "invalid UTF-8 for #{n} x #{char}"
        assert String.length(out) <= 200
      end
    end

    test "an invalid-UTF-8 binary is inspected rather than reflected" do
      assert Reflect.text(<<0xFF, 0xFE>>) =~ "255"
    end
  end
end

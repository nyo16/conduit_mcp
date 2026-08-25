defmodule ConduitMcp.Reflect do
  @moduledoc """
  The single boundary helper for client-supplied text that is echoed back to
  the client or written to the log.

  Three separate hazards, one function:

    * **Type.** Interpolating a non-binary — `protocolVersion: {}`, a
      `requestId` object — raises inside the handler, and the surrounding
      `rescue` turns a client mistake into a misleading
      "Internal server error".
    * **Size.** A 1 MB string sits comfortably inside the transports'
      `length: 1_000_000` parser cap and is reflected in full into both the
      error message and the log line.
    * **Control characters.** `"tools/call\\x00\\x01\\x02"` round-trips
      verbatim today, so a hostile value reaches the operator's log with
      terminal escapes and NULs intact.

  `text/2` applies `to_string/1`, strips control characters (C0/C1, DEL,
  zero-width and bidi controls, and the Unicode line separators — keeping
  nothing, not even tabs or newlines, which is what lets a value forge log
  lines), and clamps both the byte length and the grapheme length. Both clamps
  are needed: a grapheme cluster is unbounded in size, so one base character
  plus 400 000 combining marks is a single grapheme and ~800 KB of output.
  """

  @default_max 200

  # C0, DEL and C1, plus zero-width and bidi controls and the Unicode line
  # separators. Deliberately strips `\t` `\n` `\r` too: a reflected value has no
  # legitimate use for them and they are exactly what a log-forging payload
  # needs. U+202A–U+202E / U+2066–U+2069 are the Trojan Source class — they make
  # a log line render right-to-left, so the operator reads something other than
  # what the client sent. U+061C (ALM) is the fourth Unicode `Bidi_Control`
  # outside those ranges and reorders identically. U+2028/U+2029 survive JSON
  # encoding unescaped and break downstream JS consumers. U+2060 (word joiner)
  # and U+FEFF (ZWNBSP/BOM) are invisible format characters.
  @control_chars ~r/[\x00-\x1F\x7F-\x9F\x{061C}\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}\x{2066}-\x{2069}\x{FEFF}]/u

  # Max UTF-8 bytes per codepoint. A grapheme cluster is *unbounded* in length
  # (one base character plus N combining marks is one grapheme), so a grapheme
  # clamp alone is not a size bound: 400k combining marks is one grapheme and
  # ~800 KB of output.
  @bytes_per_codepoint 4

  @doc """
  Renders `value` as text that is safe to put in an error message or a log
  line: coerced to a string, control characters removed, clamped to `max`
  graphemes *and* to a hard byte ceiling (default #{@default_max}).

  ## Examples

      iex> ConduitMcp.Reflect.text("tools/call")
      "tools/call"

      iex> ConduitMcp.Reflect.text("tools/call\\x00\\x01")
      "tools/call"

      iex> ConduitMcp.Reflect.text(%{})
      "%{}"

      iex> ConduitMcp.Reflect.text(String.duplicate("a", 500)) |> String.length()
      200
  """
  @spec text(term(), pos_integer()) :: String.t()
  def text(value, max \\ @default_max) do
    value
    |> stringify()
    # Byte clamp first: bounds the work the regex and the grapheme walk do, so
    # neither is driven by an attacker-chosen length.
    |> binary_slice(0, max * @bytes_per_codepoint)
    # The byte clamp cuts at an arbitrary offset, so a multibyte value longer
    # than the clamp is left with a truncated sequence - and `:re` with the
    # unicode option *raises* on invalid UTF-8. Dropping the partial codepoint
    # is the whole reason this call exists; without it every reflection site
    # (method name, taskId, protocolVersion, cancellation reason, auth failure)
    # raises for a long multibyte value.
    |> String.replace_invalid("")
    |> String.replace(@control_chars, "")
    |> String.slice(0, max)
  end

  # `to_string/1` raises for terms with no String.Chars implementation (maps,
  # tuples, PIDs) — exactly the shapes a hostile or buggy client sends. And a
  # binary that is not valid UTF-8 would make the `/u` regex below raise, which
  # is the one outcome this module promises never to produce; JSON input can't
  # be invalid UTF-8, but an operator-supplied `:verify` callback's reason can.
  defp stringify(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value, limit: 10)
  end

  # Lists are handled ahead of `to_string/1`, not rescued out of it. A JSON
  # array can appear anywhere a scalar is expected, and `List.Chars` accepts
  # some of them: `to_string([1, 2])` is "\x01\x02", so a reflected `reason` of
  # `[1, 2]` would render as two stripped control characters — an empty string
  # where the client sent data. The rest raise: `ArgumentError` for `[1.5]` or
  # `[%{}]`, `UnicodeConversionError` for `[-1]`.
  defp stringify(value) when is_list(value) do
    inspect(value, limit: 10, printable_limit: 256)
  end

  defp stringify(value) do
    to_string(value)
  rescue
    # `Protocol.UndefinedError` alone was not enough. Every exception reachable
    # here must land on `inspect/2`, because the two call paths that matter -
    # `notifications/cancelled` (handler.ex:69-73) and `Logger.debug` in
    # `Transport.Shared.dispatch_post/2` - have no rescue of their own, so a
    # raise here leaves the client with a bare 500 and no JSON-RPC reply.
    _ in [Protocol.UndefinedError, ArgumentError, UnicodeConversionError] ->
      inspect(value, limit: 10, printable_limit: 256)
  end
end

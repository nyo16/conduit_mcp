defmodule ConduitMcp.Client.Transport.Stdio.Framer do
  @moduledoc """
  Splits a stdio byte stream into newline-delimited MCP messages.

  The stdio transport reads its port in `:stream` mode, so chunks arrive in
  arbitrary splits; this pure state machine turns them back into messages.

      iex> framer = ConduitMcp.Client.Transport.Stdio.Framer.new()
      iex> {:ok, [], framer} = ConduitMcp.Client.Transport.Stdio.Framer.feed(framer, "{\\"a\\":")
      iex> {:ok, messages, _framer} = ConduitMcp.Client.Transport.Stdio.Framer.feed(framer, "1}\\r\\n{}\\n")
      iex> messages
      ["{\\"a\\":1}", "{}"]

  ## Rules

    * A message ends at `\\n`. One trailing `\\r` is stripped, so CRLF output
      (Windows servers) frames the same as LF.
    * Blank lines (empty after the `\\r` strip) are skipped.
    * Bytes are scanned once: the held partial line is never rescanned, only
      each new chunk is searched for newlines.
    * Bytes after the last newline wait for the next chunk; at end of stream
      they are an incomplete message and are dropped by the caller.

  ## Oversized messages and resync

  A message longer than `:max_message_bytes` (default 8 MiB, `\\r` and `\\n`
  excluded) is detected as soon as the held bytes pass the cap, without
  buffering more. The framer then **discards every byte up to and including
  the next `\\n`** and resumes framing after it, so one oversized message
  costs that message only.

  `feed/2` reports a discard by returning
  `{:error, :message_too_large, messages, state}`: the whole chunk was still
  consumed, `messages` holds every complete message in it (before and after
  the discarded one), and `state` is ready for the next chunk. A caller that
  treats oversize as fatal closes the connection; a lenient caller keeps
  feeding.
  """

  @default_max_message_bytes 8 * 1024 * 1024

  @enforce_keys [:max_message_bytes]
  defstruct [:max_message_bytes, held: [], held_bytes: 0, discarding: false]

  @opaque t :: %__MODULE__{}

  @doc """
  A fresh framer.

  ## Options

    * `:max_message_bytes` - positive integer, default 8 MiB.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    case Keyword.get(opts, :max_message_bytes, @default_max_message_bytes) do
      max when is_integer(max) and max > 0 ->
        %__MODULE__{max_message_bytes: max}

      other ->
        raise ArgumentError,
              ":max_message_bytes must be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc """
  Feeds the next chunk; returns the complete messages it finished, in order.
  """
  @spec feed(t(), binary()) ::
          {:ok, [binary()], t()} | {:error, :message_too_large, [binary()], t()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    case split(chunk, state, [], false) do
      {messages, state, false} -> {:ok, messages, state}
      {messages, state, true} -> {:error, :message_too_large, messages, state}
    end
  end

  @doc "Bytes held for an incomplete message (0 while discarding)."
  @spec buffered_bytes(t()) :: non_neg_integer()
  def buffered_bytes(%__MODULE__{held_bytes: bytes}), do: bytes

  defp split(chunk, state, acc, dropped?) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        {state, dropped_now?} = hold(chunk, state)
        {Enum.reverse(acc), state, dropped? or dropped_now?}

      {pos, 1} ->
        rest = binary_part(chunk, pos + 1, byte_size(chunk) - pos - 1)
        {acc, state, dropped_now?} = finish_line(binary_part(chunk, 0, pos), state, acc)
        split(rest, state, acc, dropped? or dropped_now?)
    end
  end

  defp hold(_chunk, %{discarding: true} = state), do: {state, false}

  defp hold(chunk, state) do
    held_bytes = state.held_bytes + byte_size(chunk)

    # `+ 1` leaves room for a trailing `\r` that the strip will remove.
    if held_bytes > state.max_message_bytes + 1,
      do: {%{state | held: [], held_bytes: 0, discarding: true}, true},
      else: {%{state | held: [state.held, chunk], held_bytes: held_bytes}, false}
  end

  defp finish_line(_tail, %{discarding: true} = state, acc),
    do: {acc, %{state | discarding: false}, false}

  defp finish_line(tail, state, acc) do
    total = state.held_bytes + byte_size(tail)
    held = state.held
    state = %{state | held: [], held_bytes: 0}

    # Size is decided before the bytes are joined, so an oversized line that
    # arrived in one chunk is never copied.
    if total > state.max_message_bytes + 1 do
      {acc, state, true}
    else
      line = strip_cr(if held == [], do: tail, else: IO.iodata_to_binary([held, tail]))

      cond do
        byte_size(line) > state.max_message_bytes -> {acc, state, true}
        line == "" -> {acc, state, false}
        true -> {[line | acc], state, false}
      end
    end
  end

  defp strip_cr(line) do
    size = byte_size(line)

    if size > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, size - 1),
      else: line
  end
end

defmodule ConduitMcp.Client.SSE do
  @moduledoc """
  An incremental parser for `text/event-stream` bodies, following the WHATWG
  HTML "Parsing an event stream" algorithm.

  It is pure: the caller owns the state and feeds it the body chunk by chunk,
  in any split.

      iex> sse = ConduitMcp.Client.SSE.new()
      iex> {:ok, [], sse} = ConduitMcp.Client.SSE.feed(sse, "id: 7\\ndata: {\\"a\\"")
      iex> {:ok, [event], sse} = ConduitMcp.Client.SSE.feed(sse, ":1}\\n\\n")
      iex> {event.type, event.data, event.id}
      {"message", "{\\"a\\":1}", "7"}
      iex> ConduitMcp.Client.SSE.last_event_id(sse)
      "7"

  ## Behaviour

    * A leading UTF-8 BOM is stripped once, even when split across chunks.
    * Lines end in CRLF, LF or CR. A CR that ends one chunk and an LF that
      starts the next are one line ending.
    * Comment lines (starting with `:`) dispatch nothing; they are counted in
      `comments/1`. A chunk of keep-alive comments therefore returns no
      events, so a caller can tell keep-alives from progress.
    * `event:` sets the type; an empty or missing type dispatches as
      `"message"`.
    * `id:` updates the last event id immediately unless the value contains
      NUL (then it is ignored). An event with an `id:` and no data dispatches
      nothing but still updates `last_event_id/1` when its blank line arrives,
      which is what a resuming client sends as `Last-Event-ID`. An empty
      `id:` resets it to `nil`.
    * `retry:` is honoured only when the value is ASCII digits; read it with
      `retry/1`.
    * Unknown fields are ignored. Bytes are not UTF-8 validated: CR and LF
      never occur inside a multi-byte sequence, so splitting is safe, and the
      JSON decoder downstream rejects invalid text.
    * An incomplete event at the end of the stream is never dispatched.

  **One deliberate difference from WHATWG:** an event whose data is empty
  (for example the MCP priming event `id: 1` / `data:` / blank line) is not
  dispatched. It cannot carry a JSON-RPC message, and the id it carries is
  still recorded.

  ## Limits

    * `:max_line_bytes` - longest line, terminator excluded (default 8 MiB).
    * `:max_event_bytes` - largest event data (default 8 MiB).

  Exceeding either returns `{:error, :event_too_large, state}`, checked as
  bytes arrive, so an endless line without a terminator is caught without
  buffering past the cap. The error is terminal: every later `feed/2`
  returns it again, and the caller should drop the stream.
  """

  defmodule Event do
    @moduledoc """
    One dispatched server-sent event.

      * `type` - the `event:` value, or `"message"`.
      * `data` - the joined `data:` lines (LF-separated, no trailing LF).
      * `id` - the stream's last event id at dispatch time, or `nil`.
    """
    @enforce_keys [:type, :data]
    defstruct [:type, :data, :id]

    @type t :: %__MODULE__{type: String.t(), data: String.t(), id: String.t() | nil}
  end

  @default_max_bytes 8 * 1024 * 1024
  @bom <<0xEF, 0xBB, 0xBF>>

  @enforce_keys [:max_line_bytes, :max_event_bytes]
  defstruct [
    :max_line_bytes,
    :max_event_bytes,
    :type,
    :id_buffer,
    :last_event_id,
    :retry,
    :error,
    bom: {:pending, ""},
    line: [],
    line_bytes: 0,
    cr_pending: false,
    data: [],
    data_bytes: 0,
    comments: 0
  ]

  @opaque t :: %__MODULE__{}

  @type feed_result :: {:ok, [Event.t()], t()} | {:error, :event_too_large, t()}

  @doc """
  A fresh parser state.

  ## Options

    * `:max_line_bytes` - positive integer, default 8 MiB.
    * `:max_event_bytes` - positive integer, default 8 MiB.
    * `:last_event_id` - the last event id to start from (a stream resumed
      with `Last-Event-ID`), default `nil`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_line_bytes: positive!(opts, :max_line_bytes),
      max_event_bytes: positive!(opts, :max_event_bytes),
      last_event_id: Keyword.get(opts, :last_event_id)
    }
  end

  @doc """
  Feeds the next chunk of the body and returns the events it completed, in
  order.
  """
  @spec feed(t(), binary()) :: feed_result()
  def feed(%__MODULE__{error: error} = state, _chunk) when error != nil,
    do: {:error, error, state}

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    case strip_bom(state, chunk) do
      {:wait, state} -> {:ok, [], state}
      {:go, chunk, state} -> chunk |> skip_pending_lf(state) |> parse([])
    end
  end

  @doc "The last event id recorded at a dispatch point, or `nil`."
  @spec last_event_id(t()) :: String.t() | nil
  def last_event_id(%__MODULE__{last_event_id: id}), do: id

  @doc "The latest valid `retry:` value in milliseconds, or `nil`."
  @spec retry(t()) :: non_neg_integer() | nil
  def retry(%__MODULE__{retry: retry}), do: retry

  @doc "How many comment lines (keep-alives) the stream has carried."
  @spec comments(t()) :: non_neg_integer()
  def comments(%__MODULE__{comments: count}), do: count

  defp positive!(opts, key) do
    case Keyword.get(opts, key, @default_max_bytes) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end

  # The BOM may be split across the first chunks, so up to two bytes that are
  # a prefix of it are held back until the decision can be made.
  defp strip_bom(%{bom: :done} = state, chunk), do: {:go, chunk, state}

  defp strip_bom(%{bom: {:pending, held}} = state, chunk) do
    data = held <> chunk

    cond do
      match?(@bom <> _, data) ->
        {:go, binary_part(data, 3, byte_size(data) - 3), %{state | bom: :done}}

      byte_size(data) < 3 and binary_part(@bom, 0, byte_size(data)) == data ->
        {:wait, %{state | bom: {:pending, data}}}

      true ->
        {:go, data, %{state | bom: :done}}
    end
  end

  # A CR ended the previous chunk: an LF opening this one belongs to it.
  defp skip_pending_lf(<<?\n, rest::binary>>, %{cr_pending: true} = state),
    do: {rest, %{state | cr_pending: false}}

  defp skip_pending_lf("", state), do: {"", state}
  defp skip_pending_lf(chunk, state), do: {chunk, %{state | cr_pending: false}}

  # Each byte is scanned once: the held partial line is never rescanned,
  # only the new chunk is searched for the next terminator.
  defp parse({chunk, state}, acc) do
    case :binary.match(chunk, ["\r", "\n"]) do
      :nomatch -> hold_partial(chunk, state, acc)
      {pos, 1} -> complete_line(chunk, pos, state, acc)
    end
  end

  defp hold_partial(chunk, state, acc) do
    line_bytes = state.line_bytes + byte_size(chunk)

    if line_bytes > state.max_line_bytes do
      fail(state)
    else
      {:ok, Enum.reverse(acc), %{state | line: [state.line, chunk], line_bytes: line_bytes}}
    end
  end

  defp complete_line(chunk, pos, state, acc) do
    if state.line_bytes + pos > state.max_line_bytes do
      fail(state)
    else
      line = IO.iodata_to_binary([state.line, binary_part(chunk, 0, pos)])
      {rest, cr_pending} = after_terminator(chunk, pos)
      state = %{state | line: [], line_bytes: 0, cr_pending: cr_pending}

      case process_line(line, state) do
        {:ok, nil, state} -> parse({rest, state}, acc)
        {:ok, event, state} -> parse({rest, state}, [event | acc])
        :too_large -> fail(state)
      end
    end
  end

  defp after_terminator(chunk, pos) do
    rest_start = pos + 1
    rest_size = byte_size(chunk) - rest_start

    case {:binary.at(chunk, pos), rest_size} do
      {?\r, 0} ->
        {"", true}

      {?\r, _} ->
        if :binary.at(chunk, rest_start) == ?\n,
          do: {binary_part(chunk, rest_start + 1, rest_size - 1), false},
          else: {binary_part(chunk, rest_start, rest_size), false}

      {?\n, _} ->
        {binary_part(chunk, rest_start, rest_size), false}
    end
  end

  defp fail(state), do: {:error, :event_too_large, %{state | error: :event_too_large}}

  defp process_line("", state), do: dispatch(state)

  defp process_line(<<?:, _comment::binary>>, state),
    do: {:ok, nil, %{state | comments: state.comments + 1}}

  defp process_line(line, state) do
    case :binary.split(line, ":") do
      [field, <<?\s, value::binary>>] -> field(field, value, state)
      [field, value] -> field(field, value, state)
      [field] -> field(field, "", state)
    end
  end

  defp field("event", value, state), do: {:ok, nil, %{state | type: value}}

  defp field("data", value, state) do
    data_bytes = state.data_bytes + byte_size(value) + 1

    # `data_bytes` counts one LF per line; the dispatched data drops the last.
    if data_bytes - 1 > state.max_event_bytes,
      do: :too_large,
      else: {:ok, nil, %{state | data: [state.data, value, ?\n], data_bytes: data_bytes}}
  end

  defp field("id", value, state) do
    if :binary.match(value, <<0>>) == :nomatch,
      do: {:ok, nil, %{state | id_buffer: value}},
      else: {:ok, nil, state}
  end

  defp field("retry", value, state) do
    if value != "" and digits?(value),
      do: {:ok, nil, %{state | retry: String.to_integer(value)}},
      else: {:ok, nil, state}
  end

  defp field(_unknown, _value, state), do: {:ok, nil, state}

  defp digits?(<<>>), do: true
  defp digits?(<<c, rest::binary>>) when c in ?0..?9, do: digits?(rest)
  defp digits?(_value), do: false

  defp dispatch(state) do
    last_event_id = if state.id_buffer in [nil, ""], do: nil, else: state.id_buffer
    event = build_event(state, last_event_id)

    {:ok, event, %{state | last_event_id: last_event_id, data: [], data_bytes: 0, type: nil}}
  end

  # No data lines, or only empty ones: nothing to dispatch.
  defp build_event(%{data_bytes: bytes}, _id) when bytes <= 1, do: nil

  defp build_event(state, id) do
    data = IO.iodata_to_binary(state.data)

    %Event{
      type: if(state.type in [nil, ""], do: "message", else: state.type),
      data: binary_part(data, 0, byte_size(data) - 1),
      id: id
    }
  end
end

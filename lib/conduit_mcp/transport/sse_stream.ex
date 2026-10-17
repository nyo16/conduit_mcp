defmodule ConduitMcp.Transport.SSEStream do
  @moduledoc """
  Server-Sent Events primitives shared by every stream the HTTP transports
  hold open: the legacy `GET /sse` stream of `ConduitMcp.Transport.SSE` and
  the modern streamed POST responses (`ConduitMcp.StreamSpec`).

  A stream pins a process, a socket and a `Plug.Conn` for its whole life,
  so every stream built on this module is bounded three ways:

    * **a deadline** — `loop/3` returns `:deadline` once a monotonic
      deadline passes, checked at the top of every iteration;
    * **a connection cap** — `acquire_slot/3` admits at most `max` streams
      per slot table (see "Slot accounting");
    * **disconnect detection** — every write (`send_frame/2`,
      `keep_alive/1`) reports `{:error, reason}` once the client is gone.

  ## Frames

    * `frame/1` — a JSON-RPC message as an SSE `message` event:
      `event: message`, one `data:` line, a blank line. `JSON` escapes every
      newline inside strings, so the message always fits one `data:` line.
    * `keep_alive_frame/0` — `":\\r\\n"`, an SSE comment. Clients discard
      it; intermediaries see traffic and keep the connection open.

  `open/1` sends the response head: `content-type: text/event-stream`,
  `cache-control: no-cache` and `x-accel-buffering: no` (so nginx does not
  buffer the stream), and no `connection` header — RFC 9113 §8.2.2 forbids
  connection-specific headers in HTTP/2 and strict clients reject them.

  ## The receive loop

  `loop/3` waits for messages and keep-alive ticks until a callback halts
  it, a write fails, or the deadline passes. Keep-alive ticks follow a fixed
  schedule — every `:interval` milliseconds since the loop started — so a
  stream of messages arriving faster than the interval cannot starve them,
  nor the deadline check.

  Every message is received and handed to `:on_message`, so anything a
  callback does not care about is drained and the mailbox cannot grow
  without bound over a long-lived stream. The one exception is
  `{:bandit, _}`: under HTTP/2 the plug runs inside Bandit's per-stream
  process (Bandit.HTTP2.StreamProcess), and the connection process delivers
  `{:send_window_update, delta}` and `{:rst_stream, code}` to *this*
  mailbox for `chunk/2` to read back with a selective receive. Draining
  them would discard flow-control credit (eventually a
  `FLOW_CONTROL_ERROR`) and ignore stream cancellation — an
  `EventSource.close()` sends `RST_STREAM`, not a TCP close.
  """

  import Plug.Conn

  @keep_alive_frame ":\r\n"

  @typedoc """
  What a loop callback returns:

    * `{:cont, conn, state}` — keep looping;
    * `{:halt, conn, state}` — stop; `loop/3` returns `:halt`;
    * `{:closed, conn, state}` — a write failed: the client is gone; `loop/3`
      returns `:closed`.
  """
  @type step(state) ::
          {:cont, Plug.Conn.t(), state}
          | {:halt, Plug.Conn.t(), state}
          | {:closed, Plug.Conn.t(), state}

  @typedoc "Why `loop/3` returned."
  @type outcome :: :halt | :closed | :deadline

  @typedoc """
  Options for `loop/3`:

    * `:interval` (required) — milliseconds between keep-alive ticks.
    * `:deadline` (required) — the `System.monotonic_time(:millisecond)` at
      which the loop returns `:deadline`.
    * `:on_message` — `(message, conn, state -> step)`, called for every
      message except `{:bandit, _}`. Default: drain and continue.
    * `:on_tick` — `(conn, state -> step)`, called on every keep-alive
      tick. Default: write `keep_alive_frame/0`, `:closed` when that fails.
  """
  @type loop_option ::
          {:interval, pos_integer()}
          | {:deadline, integer()}
          | {:on_message, (term(), Plug.Conn.t(), term() -> step(term()))}
          | {:on_tick, (Plug.Conn.t(), term() -> step(term()))}

  @doc """
  Starts the SSE response: the stream headers, then `send_chunked(conn, 200)`.
  """
  @spec open(Plug.Conn.t()) :: Plug.Conn.t()
  def open(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  @doc """
  Encodes a JSON-RPC message as one SSE `message` event.

  Raises if `message` is not JSON-encodable, so callers building frames in
  user code (`ConduitMcp.Progress`, `ConduitMcp.Log`) fail where the bad
  value was produced.

  ## Example

      iex> ConduitMcp.Transport.SSEStream.frame(%{"jsonrpc" => "2.0", "method" => "ping"})
      ...> |> IO.iodata_to_binary()
      ~s(event: message\\ndata: {"jsonrpc":"2.0","method":"ping"}\\n\\n)
  """
  @spec frame(map()) :: iodata()
  def frame(message) when is_map(message),
    do: ["event: message\ndata: ", JSON.encode_to_iodata!(message), "\n\n"]

  @doc """
  The keep-alive frame, `":\\r\\n"`: an SSE comment line.
  """
  @spec keep_alive_frame() :: String.t()
  def keep_alive_frame, do: @keep_alive_frame

  @doc """
  Writes an already-encoded frame. `{:error, reason}` means the client is gone.
  """
  @spec send_frame(Plug.Conn.t(), iodata()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send_frame(conn, frame), do: chunk(conn, frame)

  @doc """
  Writes `keep_alive_frame/0`. `{:error, reason}` means the client is gone.
  """
  @spec keep_alive(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def keep_alive(conn), do: chunk(conn, @keep_alive_frame)

  @doc """
  Runs the receive loop described in the moduledoc and returns why it
  stopped, with the final conn and state.
  """
  @spec loop(Plug.Conn.t(), state, [loop_option()]) :: {outcome(), Plug.Conn.t(), state}
        when state: term()
  def loop(conn, state, opts) do
    interval = Keyword.fetch!(opts, :interval)

    config = %{
      interval: interval,
      deadline: Keyword.fetch!(opts, :deadline),
      on_message: Keyword.get(opts, :on_message, &drain/3),
      on_tick: Keyword.get(opts, :on_tick, &tick/2)
    }

    next_loop(conn, state, config, now() + interval)
  end

  # The deadline is checked here, at the top of every iteration, not inside
  # the `after`: each clause below recurses into a fresh `receive`, so an
  # `after`-only check would be starved by any message arriving more often
  # than the timeout.
  defp next_loop(conn, state, config, next_tick) do
    now = now()

    if now >= config.deadline do
      {:deadline, conn, state}
    else
      await(conn, state, config, next_tick, min(next_tick, config.deadline) - now)
    end
  end

  defp await(conn, state, config, next_tick, timeout) do
    receive do
      message
      when not (is_tuple(message) and tuple_size(message) > 0 and
                    elem(message, 0) == :bandit) ->
        message
        |> config.on_message.(conn, state)
        |> continue(config, next_tick)
    after
      max(timeout, 0) ->
        if now() >= next_tick and now() < config.deadline do
          conn
          |> config.on_tick.(state)
          |> continue(config, now() + config.interval)
        else
          next_loop(conn, state, config, next_tick)
        end
    end
  end

  defp continue({:cont, conn, state}, config, next_tick),
    do: next_loop(conn, state, config, next_tick)

  defp continue({outcome, conn, state}, _config, _next_tick) when outcome in [:halt, :closed],
    do: {outcome, conn, state}

  defp drain(_message, conn, state), do: {:cont, conn, state}

  defp tick(conn, state) do
    case keep_alive(conn) do
      {:ok, conn} -> {:cont, conn, state}
      {:error, _reason} -> {:closed, conn, state}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # --- slot accounting ----------------------------------------------------

  # Each stream pins a process, a socket and a Plug.Conn for its whole life,
  # so the count has to be bounded somewhere. Every stream holds one row,
  # `{{:slot, pid}, monotonic_time}`, keyed by the pid of the process serving
  # it.
  #
  # Keying by pid is what makes a slot reclaimable when its cleanup never runs.
  # Under HTTP/2, Bandit's `Bandit.HTTP2.StreamProcess` is linked to the
  # connection process and does not trap exits, so a peer close kills the
  # stream before an `after` can call release_slot/1. A bare counter leaked
  # one slot per such disconnect for the life of the node; a row whose pid is
  # dead is recognisably stale and acquire_slot/3 sweeps it.
  #
  # Insert-then-count keeps the cap exact under concurrency: each acquirer's
  # own row is part of the count it reads, so two racers at the boundary can
  # both reject (under-admit) but no interleaving admits more than `max`.
  # Dead rows are only swept once the count exceeds `max`; below the cap they
  # are never counted against anyone.
  #
  # The count is `:ets.info(table, :size)`, O(1): every row is a slot row
  # except one `:last_sweep` marker, which is subtracted. The marker is
  # overwritten but never deleted, so a concurrent count can only see it
  # appear - an overcount by one, which rejects rather than over-admits.
  #
  # A sweep is O(rows), so the reject path rate-limits it. A sweep that freed
  # nothing writes `{:last_sweep, now_ms}`; for `sweep_window_ms` after that,
  # an over-cap acquirer rejects without sweeping again. At the cap with every
  # stream alive, a flood of rejected connects therefore costs one sweep per
  # window instead of one per connect. A release, or a sweep that did free a
  # row, resets the marker to `{:last_sweep, nil}`: the table has changed, so
  # "nothing here is dead" no longer describes it. A dead row cannot be
  # starved by this: the skip only applies within one window of a fruitless
  # sweep, so a stream killed without releasing is reclaimed by the first
  # over-cap connect after that window - at most `sweep_window_ms` later than
  # with no skip at all.
  #
  # One row per pid holds because an HTTP/2 stream is its own process and
  # HTTP/1.1 keep-alive runs requests sequentially in one process, where the
  # `after` runs before the next request. `Process.alive?/1` is local-only,
  # which is fine: Bandit handlers run on this node.
  #
  # Each table is owned by a supervised `ConduitMcp.EtsOwner`
  # (`ConduitMcp.Transport.SSE.Owner`, `ConduitMcp.Transport.SSEStream.Owner`),
  # not by whichever stream first touched it. Otherwise closing the *creating*
  # connection would destroy the table, and every other live stream's slot
  # with it, so the cap could be walked past indefinitely.
  @slot_pids_spec [{{{:slot, :"$1"}, :_}, [], [:"$1"]}]
  @sweep_window_ms 1_000
  @streams_table :conduit_mcp_sse_streams

  @doc """
  Takes a slot for the calling process in slot table `table`, admitting at
  most `max` live streams. Returns `false` at the cap — and when the table
  is missing or unusable, because a resource cap must read "cannot count" as
  "no".

  `sweep_window_ms` is how long a sweep that found no dead rows suppresses
  the next one (default #{@sweep_window_ms}).
  """
  @spec acquire_slot(atom() | :ets.tid(), pos_integer(), non_neg_integer()) :: boolean()
  def acquire_slot(table, max, sweep_window_ms \\ @sweep_window_ms) do
    :ets.insert(table, {{:slot, self()}, System.monotonic_time()})

    if admit?(table, max, sweep_window_ms) do
      true
    else
      :ets.delete(table, {:slot, self()})
      false
    end
  rescue
    ArgumentError -> false
  end

  defp admit?(table, max, sweep_window_ms) do
    count = count_slots(table)

    cond do
      not is_integer(count) -> false
      count <= max -> true
      recently_swept_in_vain?(table, sweep_window_ms) -> false
      true -> within_cap?(sweep_dead_slots(table), max)
    end
  end

  defp within_cap?(count, max), do: is_integer(count) and count <= max

  # `:undefined` (not an integer) when the table has vanished; callers treat
  # that as over the cap.
  defp count_slots(table) do
    marker = if :ets.member(table, :last_sweep), do: 1, else: 0

    case :ets.info(table, :size) do
      size when is_integer(size) -> size - marker
      :undefined -> :undefined
    end
  end

  defp recently_swept_in_vain?(table, sweep_window_ms) do
    case :ets.lookup(table, :last_sweep) do
      [{:last_sweep, at}] when is_integer(at) ->
        System.monotonic_time(:millisecond) - at < sweep_window_ms

      _ ->
        false
    end
  end

  # Deletes the rows of streams that died without releasing, records whether
  # that freed anything, then recounts.
  defp sweep_dead_slots(table) do
    dead = for pid <- :ets.select(table, @slot_pids_spec), not Process.alive?(pid), do: pid
    Enum.each(dead, &:ets.delete(table, {:slot, &1}))

    swept_at = if dead == [], do: System.monotonic_time(:millisecond)
    :ets.insert(table, {:last_sweep, swept_at})

    count_slots(table)
  end

  @doc """
  Releases the calling process's slot in `table`, if it holds one.
  Idempotent; `:ok` when the table is gone (the slot went with it).
  """
  @spec release_slot(atom() | :ets.tid()) :: :ok
  def release_slot(table) do
    # A freed slot ends any skip window: see the section comment. Releasing
    # nothing changes nothing, so it leaves the marker alone.
    if :ets.take(table, {:slot, self()}) != [] do
      :ets.insert(table, {:last_sweep, nil})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The number of slot rows in `table` whose process is alive. Read-only: a
  getter that swept dead rows would hide leaks from the tests that should
  see them.
  """
  @spec active_slots(atom() | :ets.tid()) :: non_neg_integer()
  def active_slots(table) do
    table
    |> :ets.select(@slot_pids_spec)
    |> Enum.count(&Process.alive?/1)
  rescue
    ArgumentError -> 0
  end

  @doc """
  The options every slot table is created with.
  """
  @spec slot_table_opts() :: [term()]
  def slot_table_opts, do: [:named_table, :public, :set, write_concurrency: :auto]

  @doc """
  Creates named slot table `table` unless it exists. A fallback for
  embedding contexts where the `:conduit_mcp` application is not started;
  normally the table's owner created it at boot.
  """
  @spec ensure_slot_table(atom()) :: :ok
  def ensure_slot_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, slot_table_opts())
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The slot table behind streamed POST responses (`:max_streams`), owned by
  `ConduitMcp.Transport.SSEStream.Owner`.
  """
  @spec streams_table() :: atom()
  def streams_table, do: @streams_table

  defmodule Owner do
    @moduledoc """
    Long-lived process that owns the `:conduit_mcp_sse_streams` ETS table,
    the slot table behind the HTTP transports' `:max_streams` cap on
    streamed POST responses: one row per open stream, keyed by the pid
    serving it.

    Started under `ConduitMcp.Supervisor` by `ConduitMcp.Application`, so the
    table outlives every individual stream.
    """

    # Not a GenServer itself: the process is a `ConduitMcp.EtsOwner`
    # registered under this module's name. This module is the child spec.
    @doc false
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    alias ConduitMcp.Transport.SSEStream

    @doc false
    def start_link(_opts) do
      ConduitMcp.EtsOwner.start_link(
        __MODULE__,
        SSEStream.streams_table(),
        SSEStream.slot_table_opts()
      )
    end
  end
end

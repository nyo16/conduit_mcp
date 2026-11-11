# Task 1.4 item 2: does Bandit 1.14.1 reset a long-lived HTTP/2 SSE stream
# (streamed tools/call, subscriptions/listen) whose process leaves
# `{:bandit, _}` messages unread between ticks?
#
#   MIX_ENV=test mix run .claude/plans/hardening-0.11.1/research/h2_spike.exs
#
# Raw h2c (prior knowledge) over :gen_tcp, frames built with Bandit's own
# frame modules and HPAX, so the client controls exactly which frames reach
# the stream process.
Logger.configure(level: :warning)

defmodule Spike.Server do
  use ConduitMcp.Server

  tool "hold", "progress once, then block until the stream dies" do
    handle(fn conn, _params ->
      ConduitMcp.Progress.report(conn, 0)

      receive do
        :never -> text("unreachable")
      end
    end)
  end

  tool "many", "1000 progress notifications, then a result" do
    handle(fn conn, _params ->
      for i <- 1..1000, do: ConduitMcp.Progress.report(conn, i, total: 1000)
      text("done")
    end)
  end
end

defmodule Spike.H2 do
  alias Bandit.HTTP2.Frame

  @version "2026-07-28"
  @meta %{
    "io.modelcontextprotocol/protocolVersion" => @version,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  def start(opts) do
    {:ok, pid} =
      Bandit.start_link(
        plug:
          {ConduitMcp.Transport.StreamableHTTP,
           Keyword.merge([server_module: Spike.Server, allowed_origins: "*"], opts)},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  def connect(port) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(s, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    send_frame(s, %Frame.Settings{settings: %{}})
    # Read the server's SETTINGS (and possibly its window update), then ACK.
    {frames, buf} = recv_frames(s, "", 500)
    true = Enum.any?(frames, &match?(%Frame.Settings{ack: false}, &1))
    send_frame(s, %Frame.Settings{ack: true})
    %{socket: s, buf: buf, hpack: HPAX.new(4096), dec: HPAX.new(4096)}
  end

  def post(c, stream_id, method, params, extra_headers \\ []) do
    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => Map.put(params, "_meta", Map.merge(@meta, params["_meta"] || %{}))
      })

    headers =
      [
        {":method", "POST"},
        {":scheme", "http"},
        {":path", "/"},
        {":authority", "localhost"},
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"content-length", Integer.to_string(byte_size(body))},
        {"mcp-protocol-version", @version},
        {"mcp-method", method}
      ] ++ extra_headers

    {block, hpack} = HPAX.encode(Enum.map(headers, fn {k, v} -> {:no_store, k, v} end), c.hpack)
    block = IO.iodata_to_binary(block)

    send_frame(c.socket, %Frame.Headers{stream_id: stream_id, end_headers: true, fragment: block})
    send_frame(c.socket, %Frame.Data{stream_id: stream_id, end_stream: true, data: body})
    %{c | hpack: hpack}
  end

  def window_updates(c, stream_id, n) do
    frames =
      for _ <- 1..n,
          do: Frame.serialize(%Frame.WindowUpdate{stream_id: stream_id, size_increment: 1}, 16_384)

    :ok = :gen_tcp.send(c.socket, frames)
  end

  def send_frame(s, frame), do: :ok = :gen_tcp.send(s, Frame.serialize(frame, 16_384))

  # Reads everything that arrives within `ms` (frames only, unparsed tail kept).
  def recv_frames(s, buf, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    loop(s, buf, [], deadline)
  end

  defp loop(s, buf, acc, deadline) do
    {frames, buf} = parse(buf, [])
    acc = acc ++ frames
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {acc, buf}
    else
      case :gen_tcp.recv(s, 0, left) do
        {:ok, data} -> loop(s, buf <> data, acc, deadline)
        {:error, :timeout} -> {acc, buf}
        {:error, :closed} -> {acc ++ [:closed], buf}
      end
    end
  end

  defp parse(buf, acc) do
    case Frame.deserialize(buf, 16_777_215) do
      {{:ok, frame}, rest} -> parse(rest, [frame | acc])
      {{:more, rest}, <<>>} -> {Enum.reverse(acc), IO.iodata_to_binary(rest)}
      {{:error, code, msg}, rest} -> parse(rest, [{:frame_error, code, msg} | acc])
      nil -> {Enum.reverse(acc), ""}
    end
  end

  def summarize(frames) do
    Enum.frequencies_by(frames, fn
      %Frame.Data{} -> :data
      %Frame.Headers{} -> :headers
      %Frame.RstStream{error_code: code} -> {:rst_stream, code}
      %Frame.Goaway{error_code: code} -> {:goaway, code}
      %Frame.WindowUpdate{} -> :window_update
      %Frame.Settings{} -> :settings
      %Frame.Ping{} -> :ping
      other -> other
    end)
  end
end

alias Spike.H2

# --- A: adversarial burst of stream-level WINDOW_UPDATEs ----------------------

run_burst = fn label, port, stream_req, n ->
  c = H2.connect(port)
  c = stream_req.(c)
  # Let the stream open (first progress / ack event) before flooding it.
  {opening, buf} = H2.recv_frames(c.socket, c.buf, 300)
  H2.window_updates(c, 1, n)
  {after_flood, _buf} = H2.recv_frames(c.socket, buf, 1_500)

  IO.puts(
    "#{label} n=#{n}: before=#{inspect(H2.summarize(opening))} " <>
      "after=#{inspect(H2.summarize(after_flood))}"
  )

  :gen_tcp.close(c.socket)
end

hold = fn c -> H2.post(c, 1, "tools/call", %{"name" => "hold", "arguments" => %{}, "_meta" => %{"progressToken" => "t"}}, [{"mcp-name", "hold"}]) end

listen = fn c ->
  H2.post(c, 1, "subscriptions/listen", %{"notifications" => %{"toolsListChanged" => true}})
end

{_pid, port} = H2.start(keep_alive_interval: 15_000)
IO.puts("== keep_alive_interval 15 000 ms (default): nothing read between bursts ==")

for n <- [50, 99, 100, 101, 150] do
  run_burst.("tools/call", port, hold, n)
  run_burst.("listen", port, listen, n)
end

# Ticks every 20 ms: each keep-alive send consumes at most one queued message.
{_pid, port2} = H2.start(keep_alive_interval: 20)
IO.puts("== keep_alive_interval 20 ms ==")

for n <- [150] do
  run_burst.("tools/call", port2, hold, n)
  run_burst.("listen", port2, listen, n)
end

# --- B: honest client: one stream + one connection WINDOW_UPDATE per DATA -----

honest = fn port ->
  c = H2.connect(port)
  c = H2.post(c, 1, "tools/call", %{"name" => "many", "arguments" => %{}, "_meta" => %{"progressToken" => "t"}}, [{"mcp-name", "many"}])

  read = fn read, buf, stats ->
    {frames, buf} = H2.recv_frames(c.socket, buf, 200)

    for %Bandit.HTTP2.Frame.Data{stream_id: 1, data: d} <- frames, byte_size(d) > 0 do
      H2.send_frame(c.socket, %Bandit.HTTP2.Frame.WindowUpdate{stream_id: 1, size_increment: byte_size(d)})
      H2.send_frame(c.socket, %Bandit.HTTP2.Frame.WindowUpdate{stream_id: 0, size_increment: byte_size(d)})
    end

    stats = Map.merge(stats, H2.summarize(frames), fn _k, a, b -> a + b end)
    done? = Enum.any?(frames, &match?(%Bandit.HTTP2.Frame.Data{end_stream: true}, &1))
    reset? = Enum.any?(frames, &match?(%Bandit.HTTP2.Frame.RstStream{}, &1))

    if done? or reset? or frames == [], do: stats, else: read.(read, buf, stats)
  end

  stats = read.(read, c.buf, %{})
  IO.puts("honest client, 1000 progress events: #{inspect(stats)}")
  :gen_tcp.close(c.socket)
end

honest.(port)

# --- C: Mint (Finch's HTTP/2 stack) as the client ------------------------------

mint = fn port ->
  {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port)

  body =
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "many",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "progressToken" => "t"
        }
      }
    })

  headers = [
    {"content-type", "application/json"},
    {"accept", "application/json, text/event-stream"},
    {"mcp-protocol-version", "2026-07-28"},
    {"mcp-method", "tools/call"},
    {"mcp-name", "many"}
  ]

  {:ok, conn, ref} = Mint.HTTP2.request(conn, "POST", "/", headers, body)

  collect = fn collect, conn, acc ->
    receive do
      msg ->
        {:ok, conn, responses} = Mint.HTTP2.stream(conn, msg)

        acc =
          Enum.reduce(responses, acc, fn
            {:status, ^ref, s}, acc -> Map.put(acc, :status, s)
            {:data, ^ref, d}, acc -> Map.update(acc, :bytes, byte_size(d), &(&1 + byte_size(d)))
            {:done, ^ref}, acc -> Map.put(acc, :done, true)
            {:error, ^ref, e}, acc -> Map.put(acc, :error, e)
            _, acc -> acc
          end)

        if acc[:done] || acc[:error], do: acc, else: collect.(collect, conn, acc)
    after
      3_000 -> Map.put(acc, :timeout, true)
    end
  end

  IO.puts("Mint HTTP/2, 1000 progress events: #{inspect(collect.(collect, conn, %{}))}")
end

mint.(port)

# --- D: same honest client against a plain chunking plug (no ConduitMcp) -----

defmodule Spike.PlainPlug do
  import Plug.Conn
  def init(o), do: o

  def call(conn, _) do
    conn = send_chunked(conn, 200)

    Enum.reduce(1..1000, conn, fn i, conn ->
      {:ok, conn} = chunk(conn, "data: #{String.duplicate("x", 120)} #{i}\n\n")
      conn
    end)
  end
end

{:ok, plain} =
  Bandit.start_link(plug: Spike.PlainPlug, port: 0, ip: :loopback, startup_log: false)

{:ok, {_ip, plain_port}} = ThousandIsland.listener_info(plain)

c = H2.connect(plain_port)
{block, _} = HPAX.encode([{:no_store, ":method", "GET"}, {:no_store, ":scheme", "http"}, {:no_store, ":path", "/"}, {:no_store, ":authority", "localhost"}], c.hpack)
H2.send_frame(c.socket, %Bandit.HTTP2.Frame.Headers{stream_id: 1, end_headers: true, end_stream: true, fragment: IO.iodata_to_binary(block)})

read = fn read, buf, stats ->
  {frames, buf} = H2.recv_frames(c.socket, buf, 200)

  for %Bandit.HTTP2.Frame.Data{stream_id: 1, data: d} <- frames, byte_size(d) > 0 do
    H2.send_frame(c.socket, %Bandit.HTTP2.Frame.WindowUpdate{stream_id: 1, size_increment: byte_size(d)})
    H2.send_frame(c.socket, %Bandit.HTTP2.Frame.WindowUpdate{stream_id: 0, size_increment: byte_size(d)})
  end

  stats = Map.merge(stats, H2.summarize(frames), fn _k, a, b -> a + b end)
  stop? = frames == [] or Enum.any?(frames, &match?(%Bandit.HTTP2.Frame.RstStream{}, &1)) or
    Enum.any?(frames, &match?(%Bandit.HTTP2.Frame.Data{end_stream: true}, &1))
  if stop?, do: stats, else: read.(read, buf, stats)
end

IO.puts("plain chunking plug, honest client, 1000 chunks: #{inspect(read.(read, c.buf, %{}))}")

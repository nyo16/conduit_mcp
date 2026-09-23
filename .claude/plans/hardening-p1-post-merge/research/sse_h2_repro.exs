Application.ensure_all_started(:conduit_mcp)
Code.require_file("test/support/test_server.ex")
require Logger
Logger.configure(level: :error)

opts = [
  server_module: ConduitMcp.TestServer,
  allowed_origins: "*",
  keep_alive_interval: 500,
  max_connections: 1000
]

{:ok, _} = Bandit.start_link(plug: {ConduitMcp.Transport.SSE, opts}, port: 4799, ip: :loopback)
Process.sleep(200)

run = fn label, args ->
  base = ConduitMcp.Transport.SSE.active_connections()

  tasks =
    for _ <- 1..10 do
      Task.async(fn -> System.cmd("curl", args ++ ["-s", "-N", "-H", "Accept: text/event-stream", "--max-time", "1", "http://127.0.0.1:4799/sse"], stderr_to_stdout: true) end)
    end

  Process.sleep(500)
  mid = ConduitMcp.Transport.SSE.active_connections()
  results = Enum.map(tasks, &Task.await(&1, 10_000))
  IO.inspect(hd(results), label: "#{label} sample curl output", printable_limit: 300)
  during = ConduitMcp.Transport.SSE.active_connections()
  IO.puts("#{label}: mid_connection=#{mid}")
  Process.sleep(10_000)
  IO.puts("#{label}: before=#{base} right_after_drop=#{during} after_10s=#{ConduitMcp.Transport.SSE.active_connections()}")
end

run.("HTTP/1.1", ["--http1.1"])
run.("HTTP/2 prior-knowledge", ["--http2-prior-knowledge"])

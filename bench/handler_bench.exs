Code.require_file("bench/bench_helper.exs")

alias Bench.Fixtures
alias ConduitMcp.Handler

conn = Fixtures.fake_conn()

IO.puts("\n=== Handler Dispatch Benchmark ===")
IO.puts("Measures: full request routing, function_exported? overhead, method dispatch\n")

# --- Section 1: Method dispatch ---

IO.puts("--- Method Dispatch (DSL Server) ---\n")

Benchee.run(
  %{
    "ping (minimal path)" => fn ->
      Handler.handle_request(Fixtures.ping_request(), Bench.DSLServer, conn)
    end,
    "tools/list" => fn ->
      Handler.handle_request(Fixtures.list_tools_request(), Bench.DSLServer, conn)
    end,
    "tools/call: 1 param (echo)" => fn ->
      req = Fixtures.tool_call_request("echo", Fixtures.small_params())
      Handler.handle_request(req, Bench.DSLServer, conn)
    end,
    "tools/call: 5 params (create_user)" => fn ->
      req = Fixtures.tool_call_request("create_user", Fixtures.medium_params())
      Handler.handle_request(req, Bench.DSLServer, conn)
    end,
    "tools/call: 20 params (bulk_import)" => fn ->
      req = Fixtures.tool_call_request("bulk_import", Fixtures.large_params())
      Handler.handle_request(req, Bench.DSLServer, conn)
    end,
    "resources/list" => fn ->
      Handler.handle_request(Fixtures.list_resources_request(), Bench.DSLServer, conn)
    end,
    "resources/read (URI template)" => fn ->
      req = Fixtures.resource_read_request("user://42")
      Handler.handle_request(req, Bench.DSLServer, conn)
    end,
    "prompts/list" => fn ->
      Handler.handle_request(Fixtures.list_prompts_request(), Bench.DSLServer, conn)
    end,
    "prompts/get" => fn ->
      req = Fixtures.prompt_get_request("code_review", %{"code" => "x = 1"})
      Handler.handle_request(req, Bench.DSLServer, conn)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/handler_dispatch.html"}
  ]
)

# --- Section 2: function_exported? micro-benchmark ---

IO.puts("\n--- function_exported? Overhead ---\n")

Benchee.run(
  %{
    "function_exported? x1" => fn ->
      function_exported?(Bench.DSLServer, :__scope_for_tool__, 1)
    end,
    "function_exported? x6 (all optional callbacks)" => fn ->
      m = Bench.DSLServer
      function_exported?(m, :__scope_for_tool__, 1)
      function_exported?(m, :handle_complete, 3)
      function_exported?(m, :handle_set_log_level, 2)
      function_exported?(m, :handle_subscribe_resource, 2)
      function_exported?(m, :handle_unsubscribe_resource, 2)
      function_exported?(m, :__capabilities__, 0)
    end,
    "Module.function_exported? x6 (Erlang BIF)" => fn ->
      m = Bench.DSLServer
      :erlang.function_exported(m, :__scope_for_tool__, 1)
      :erlang.function_exported(m, :handle_complete, 3)
      :erlang.function_exported(m, :handle_set_log_level, 2)
      :erlang.function_exported(m, :handle_subscribe_resource, 2)
      :erlang.function_exported(m, :handle_unsubscribe_resource, 2)
      :erlang.function_exported(m, :__capabilities__, 0)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/handler_function_exported.html"}
  ]
)

# --- Section 3: Telemetry overhead ---

IO.puts("\n--- Telemetry Overhead ---\n")

Benchee.run(
  %{
    "System.monotonic_time x2 + duration calc" => fn ->
      start = System.monotonic_time()
      _duration = System.monotonic_time() - start
    end,
    ":telemetry.execute (no handlers)" => fn ->
      :telemetry.execute([:bench, :noop], %{value: 1}, %{})
    end,
    "monotonic_time x2 + telemetry.execute (combined)" => fn ->
      start = System.monotonic_time()
      duration = System.monotonic_time() - start
      :telemetry.execute([:bench, :noop], %{duration: duration}, %{method: "test"})
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/handler_telemetry.html"}
  ]
)

# --- Section 4: Concurrent dispatch ---
#
# Every request with an id writes the in-flight table on entry and exit and
# checks the cancellation table on exit. A single-process run cannot show
# contention on those shared tables; this one runs the same 16 000 requests
# from 1 process and from 16 processes at once, each a distinct client. A
# serialized table shows up as the 16-process job running no faster than the
# 1-process one. Debug logging is raised to :warning for the section: every
# request logs "Handling method" at :debug, and 16 processes writing to the
# console would measure the logger instead.

IO.puts("\n--- Concurrent Dispatch (1 vs 16 processes) ---\n")

total_requests = 16_000

concurrent = fn request, processes ->
  per_process = div(total_requests, processes)

  fn ->
    1..processes
    |> Enum.map(fn p ->
      Task.async(fn ->
        client = %{conn | remote_ip: {10, 0, 0, p}}

        for i <- 1..per_process do
          Handler.handle_request(%{request | "id" => i}, Bench.DSLServer, client)
        end
      end)
    end)
    |> Task.await_many(:infinity)
  end
end

ping = Fixtures.ping_request()
echo = Fixtures.tool_call_request("echo", Fixtures.small_params())
log_level = Logger.level()
Logger.configure(level: :warning)

Benchee.run(
  %{
    "ping x#{total_requests}, 1 process" => concurrent.(ping, 1),
    "ping x#{total_requests}, 16 processes" => concurrent.(ping, 16),
    "tools/call echo x#{total_requests}, 1 process" => concurrent.(echo, 1),
    "tools/call echo x#{total_requests}, 16 processes" => concurrent.(echo, 16)
  },
  warmup: 2,
  time: 5,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/handler_concurrent.html"}
  ]
)

Logger.configure(level: log_level)

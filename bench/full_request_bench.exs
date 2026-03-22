Code.require_file("bench/bench_helper.exs")

alias ConduitMcp.Handler
alias Bench.Fixtures

conn = Fixtures.fake_conn()

IO.puts("\n=== Full Request Pipeline Benchmark ===")
IO.puts("Measures: DSL vs Manual vs Endpoint mode for identical operations\n")

servers = [
  {"DSL", Bench.DSLServer},
  {"Manual", Bench.ManualServer},
  {"Endpoint", Bench.EndpointServer}
]

# --- tools/call echo ---

IO.puts("--- tools/call echo (1 param) ---\n")

echo_req = Fixtures.tool_call_request("echo", Fixtures.small_params())

echo_scenarios =
  for {mode, server} <- servers, into: %{} do
    {"#{mode}: tools/call echo", fn -> Handler.handle_request(echo_req, server, conn) end}
  end

Benchee.run(echo_scenarios,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/full_echo.html"}
  ]
)

# --- tools/call create_user (5 params) ---

IO.puts("\n--- tools/call create_user (5 params) ---\n")

user_req = Fixtures.tool_call_request("create_user", Fixtures.medium_params())

user_scenarios =
  for {mode, server} <- servers, into: %{} do
    {"#{mode}: tools/call create_user", fn -> Handler.handle_request(user_req, server, conn) end}
  end

Benchee.run(user_scenarios,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/full_create_user.html"}
  ]
)

# --- resources/read ---

IO.puts("\n--- resources/read (URI template) ---\n")

resource_req = Fixtures.resource_read_request("user://42")

resource_scenarios =
  for {mode, server} <- servers, into: %{} do
    {"#{mode}: resources/read user", fn -> Handler.handle_request(resource_req, server, conn) end}
  end

Benchee.run(resource_scenarios,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/full_resource.html"}
  ]
)

# --- prompts/get ---

IO.puts("\n--- prompts/get ---\n")

prompt_req = Fixtures.prompt_get_request("code_review", %{"code" => "x = 1"})

prompt_scenarios =
  for {mode, server} <- servers, into: %{} do
    {"#{mode}: prompts/get code_review",
     fn -> Handler.handle_request(prompt_req, server, conn) end}
  end

Benchee.run(prompt_scenarios,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/full_prompt.html"}
  ]
)

# --- tools/list ---

IO.puts("\n--- tools/list ---\n")

list_req = Fixtures.list_tools_request()

list_scenarios =
  for {mode, server} <- servers, into: %{} do
    {"#{mode}: tools/list", fn -> Handler.handle_request(list_req, server, conn) end}
  end

Benchee.run(list_scenarios,
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/full_list.html"}
  ]
)

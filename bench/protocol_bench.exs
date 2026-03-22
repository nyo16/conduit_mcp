Code.require_file("bench/bench_helper.exs")

alias ConduitMcp.Protocol

IO.puts("\n=== Protocol Module Benchmark ===")
IO.puts("Measures: request validation, response construction, version negotiation\n")

valid_request = %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "method" => "tools/call",
  "params" => %{"name" => "echo", "arguments" => %{"message" => "hi"}}
}

invalid_request = %{"foo" => "bar"}

notification = %{
  "jsonrpc" => "2.0",
  "method" => "notifications/initialized",
  "params" => %{}
}

result_map = %{
  "content" => [%{"type" => "text", "text" => "Hello!"}]
}

error_data = %{"errors" => [%{"param" => "x", "message" => "required"}]}

Benchee.run(
  %{
    "valid_request? (valid)" => fn -> Protocol.valid_request?(valid_request) end,
    "valid_request? (invalid)" => fn -> Protocol.valid_request?(invalid_request) end,
    "valid_notification?" => fn -> Protocol.valid_notification?(notification) end,
    "success_response" => fn -> Protocol.success_response(1, result_map) end,
    "error_response (no data)" => fn -> Protocol.error_response(1, -32000, "Tool failed") end,
    "error_response (with data)" => fn ->
      Protocol.error_response(1, -32602, "Validation failed", error_data)
    end,
    "negotiate_version (match)" => fn -> Protocol.negotiate_version("2025-11-25") end,
    "negotiate_version (no match)" => fn -> Protocol.negotiate_version("2024-01-01") end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/protocol.html"}
  ]
)

Code.require_file("bench/bench_helper.exs")

IO.puts("\n=== JSON Encoding/Decoding Benchmark ===")
IO.puts("Measures: Built-in JSON module performance with varying payload sizes\n")

# --- Payloads ---

small_payload = %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "result" => %{
    "content" => [%{"type" => "text", "text" => "Hello, world!"}]
  }
}

medium_payload = %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "result" => %{
    "tools" =>
      Enum.map(1..10, fn i ->
        %{
          "name" => "tool_#{i}",
          "description" => "Tool number #{i} that does something useful",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "param1" => %{"type" => "string", "description" => "First parameter"},
              "param2" => %{"type" => "integer", "description" => "Second parameter"},
              "param3" => %{"type" => "boolean", "description" => "Third parameter"}
            },
            "required" => ["param1"]
          }
        }
      end)
  }
}

large_payload = %{
  "jsonrpc" => "2.0",
  "id" => 1,
  "result" => %{
    "content" =>
      Enum.map(1..100, fn i ->
        %{"type" => "text", "text" => "Line #{i}: #{String.duplicate("data ", 20)}"}
      end)
  }
}

small_json = JSON.encode!(small_payload)
medium_json = JSON.encode!(medium_payload)
large_json = JSON.encode!(large_payload)

IO.puts(
  "Payload sizes: small=#{byte_size(small_json)}B, medium=#{byte_size(medium_json)}B, large=#{byte_size(large_json)}B\n"
)

# --- Encoding ---

IO.puts("--- Encoding ---\n")

Benchee.run(
  %{
    "JSON.encode! small" => fn -> JSON.encode!(small_payload) end,
    "JSON.encode! medium" => fn -> JSON.encode!(medium_payload) end,
    "JSON.encode! large" => fn -> JSON.encode!(large_payload) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/json_encode.html"}
  ]
)

# --- Decoding ---

IO.puts("\n--- Decoding ---\n")

Benchee.run(
  %{
    "JSON.decode! small" => fn -> JSON.decode!(small_json) end,
    "JSON.decode! medium" => fn -> JSON.decode!(medium_json) end,
    "JSON.decode! large" => fn -> JSON.decode!(large_json) end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML, file: "bench/output/json_decode.html"}
  ]
)

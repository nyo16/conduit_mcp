# Exercises the simple tools server with ConduitMcp.Client.
#
# Start the server in one terminal (from the repo root):
#
#     mix run --no-halt examples/simple_tools_server/run.exs
#
# then, in another:
#
#     mix run examples/simple_tools_server/client_test.exs
#
# URL defaults to http://localhost:4001/ (the server's default PORT). The
# client negotiates the protocol era itself (`protocol: :auto`): the server
# answers the modern `server/discover`, so this runs on 2026-07-28; pass
# PROTOCOL=legacy to force the 2025-11-25 `initialize` handshake.

alias ConduitMcp.Client
alias ConduitMcp.Client.Transport.StreamableHTTP

url = System.get_env("URL", "http://localhost:4001/")

protocol =
  case System.get_env("PROTOCOL", "auto") do
    "auto" -> :auto
    "modern" -> :modern
    "legacy" -> :legacy
  end

check = fn
  true, what ->
    IO.puts("   ✓ #{what}")

  false, what ->
    IO.puts(:stderr, "   ✗ #{what}")
    System.halt(1)
end

text = fn %ConduitMcp.Client.ToolResult{content: content} ->
  Enum.map_join(content, "", &(&1["text"] || ""))
end

IO.puts("\n=== Testing MCP Server at #{url} ===\n")

{:ok, _pid} =
  Client.start_link(
    name: :simple_tools,
    transport: {StreamableHTTP, url: url},
    protocol: protocol
  )

IO.puts("1. Connecting...")

case Client.await_ready(:simple_tools, 5_000) do
  :ok ->
    :ok

  {:error, error} ->
    IO.puts(:stderr, "   ✗ not ready: #{Exception.message(error)} (is the server running?)")
    System.halt(1)
end

{:ok, %{server_info: info, era: era, version: version}} = Client.server_info(:simple_tools)
IO.puts("   ✓ Server: #{info.name} #{info.version}")
IO.puts("   ✓ Era: #{era} (#{version})\n")

IO.puts("2. Listing tools...")
{:ok, tools} = Client.list_all_tools(:simple_tools)
for tool <- tools, do: IO.puts("     - #{tool.name}: #{tool.description}")

check.(
  Enum.map(tools, & &1.name) |> Enum.sort() == ["echo", "reverse_string"],
  "found echo and reverse_string\n"
)

IO.puts("3. Calling echo...")
message = "Hello from ConduitMcp.Client!"
{:ok, result} = Client.call_tool(:simple_tools, "echo", %{"message" => message})

check.(
  not result.is_error and text.(result) == message,
  "echo returned #{inspect(text.(result))}\n"
)

IO.puts("4. Calling reverse_string...")
{:ok, result} = Client.call_tool(:simple_tools, "reverse_string", %{"text" => "Elixir MCP"})
check.(text.(result) == "PCM rixilE", "reverse_string returned #{inspect(text.(result))}\n")

IO.puts("5. Calling echo without its required argument...")
# The server rejects the arguments before running the tool: a JSON-RPC
# error, so `{:error, %Error{}}`. (A tool that runs and fails returns
# `{:ok, %ToolResult{is_error: true}}` instead.)
{:error, error} = Client.call_tool(:simple_tools, "echo", %{})
check.(error.reason == {:jsonrpc, -32602}, "#{Exception.message(error)}\n")

:ok = Client.close(:simple_tools)
IO.puts("=== All Tests Passed! ===\n")

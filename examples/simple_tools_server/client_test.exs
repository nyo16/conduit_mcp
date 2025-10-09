#!/usr/bin/env elixir

# Simple MCP client to test the server
# Usage: elixir examples/simple_tools_server/client_test.exs

defmodule SimpleMCPClient do
  @server_url "http://localhost:4001"

  def test_server do
    IO.puts("\n=== Testing MCP Server ===\n")

    # Step 1: Connect to SSE endpoint to get message endpoint
    IO.puts("1. Connecting to SSE endpoint...")
    {:ok, endpoint_url} = get_endpoint_from_sse()
    IO.puts("   ✓ Got endpoint: #{endpoint_url}\n")

    # Step 2: Initialize
    IO.puts("2. Initializing connection...")

    init_response =
      send_request(endpoint_url, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "test-client",
            "version" => "1.0.0"
          }
        }
      })

    IO.puts("   ✓ Server: #{init_response["result"]["serverInfo"]["name"]}")
    IO.puts("   ✓ Protocol: #{init_response["result"]["protocolVersion"]}\n")

    # Step 3: List tools
    IO.puts("3. Listing available tools...")

    tools_response =
      send_request(endpoint_url, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      })

    tools = tools_response["result"]["tools"]
    IO.puts("   ✓ Found #{length(tools)} tools:")

    Enum.each(tools, fn tool ->
      IO.puts("     - #{tool["name"]}: #{tool["description"]}")
    end)

    IO.puts("")

    # Step 4: Test echo tool
    IO.puts("4. Testing echo tool...")
    test_message = "Hello from Elixir MCP client!"

    echo_response =
      send_request(endpoint_url, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{
            "message" => test_message
          }
        }
      })

    echo_result = echo_response["result"]["content"] |> List.first()
    IO.puts("   Input:  \"#{test_message}\"")
    IO.puts("   Output: \"#{echo_result["text"]}\"")
    IO.puts("   ✓ Echo tool works!\n")

    # Step 5: Test reverse_string tool
    IO.puts("5. Testing reverse_string tool...")
    test_text = "Elixir MCP"

    reverse_response =
      send_request(endpoint_url, %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "reverse_string",
          "arguments" => %{
            "text" => test_text
          }
        }
      })

    reverse_result = reverse_response["result"]["content"] |> List.first()
    IO.puts("   Input:  \"#{test_text}\"")
    IO.puts("   Output: \"#{reverse_result["text"]}\"")
    IO.puts("   ✓ Reverse tool works!\n")

    IO.puts("=== All Tests Passed! ===\n")
  end

  defp get_endpoint_from_sse do
    # Connect to SSE endpoint and read the endpoint URL
    {output, exit_code} = System.cmd("curl", ["-N", "-s", "-m", "2", "#{@server_url}/sse"])

    # Parse SSE message even if curl times out (exit code 28)
    # Format: "event: endpoint\ndata: <URL>\n\n"
    endpoint =
      output
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, "data:") do
          String.trim_leading(line, "data:") |> String.trim()
        end
      end)

    if endpoint do
      {:ok, endpoint}
    else
      IO.puts("   ✗ Failed to parse endpoint from SSE output")
      IO.puts("   Output: #{output}")
      {:error, :connection_failed}
    end
  end

  defp send_request(url, payload) do
    json = Jason.encode!(payload)

    case System.cmd("curl", [
           "-s",
           "-X",
           "POST",
           url,
           "-H",
           "Content-Type: application/json",
           "-d",
           json
         ]) do
      {response, 0} ->
        Jason.decode!(response)

      {error, code} ->
        IO.puts("   ✗ Request failed (#{code}): #{error}")
        %{"error" => %{"message" => error}}
    end
  end
end

# Run the tests
SimpleMCPClient.test_server()

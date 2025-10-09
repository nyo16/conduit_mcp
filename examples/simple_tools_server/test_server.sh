#!/bin/bash

# Simple test script for MCP server
# Make sure the server is running first: elixir examples/simple_tools_server/run.exs

SERVER_URL="http://localhost:4001"

echo "=== Testing MCP Server ==="
echo

# Test 1: Health Check
echo "1. Health Check"
echo "curl $SERVER_URL/health"
curl -s $SERVER_URL/health
echo -e "\n"

# Test 2: Initialize
echo "2. Initialize Connection"
curl -s -X POST $SERVER_URL/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": {
        "name": "test-client",
        "version": "1.0.0"
      }
    }
  }' | python3 -m json.tool 2>/dev/null || cat
echo -e "\n"

# Test 3: List Tools
echo "3. List Available Tools"
curl -s -X POST $SERVER_URL/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
    "params": {}
  }' | python3 -m json.tool 2>/dev/null || cat
echo -e "\n"

# Test 4: Echo Tool
echo "4. Call Echo Tool"
curl -s -X POST $SERVER_URL/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "echo",
      "arguments": {
        "message": "Hello from MCP!"
      }
    }
  }' | python3 -m json.tool 2>/dev/null || cat
echo -e "\n"

# Test 5: Reverse String Tool
echo "5. Call Reverse String Tool"
curl -s -X POST $SERVER_URL/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "reverse_string",
      "arguments": {
        "text": "Elixir MCP is awesome!"
      }
    }
  }' | python3 -m json.tool 2>/dev/null || cat
echo -e "\n"

echo "=== Tests Complete ==="

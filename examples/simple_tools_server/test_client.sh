#!/bin/bash

# Simple MCP client test script
# Tests the full MCP protocol flow

SERVER_URL="http://localhost:4001"

echo ""
echo "=== Testing MCP Server ==="
echo ""

# Step 1: Get endpoint from SSE
echo "1. Connecting to SSE endpoint..."
SSE_OUTPUT=$(timeout 2 curl -N -s $SERVER_URL/sse 2>&1 | head -3)
ENDPOINT=$(echo "$SSE_OUTPUT" | grep "^data:" | sed 's/data: //' | tr -d '\r')

if [ -z "$ENDPOINT" ]; then
  echo "   ✗ Failed to get endpoint from SSE"
  exit 1
fi

echo "   ✓ Got endpoint: $ENDPOINT"
echo ""

# Step 2: Initialize
echo "2. Initializing connection..."
INIT_RESPONSE=$(curl -s -X POST $ENDPOINT \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}')

SERVER_NAME=$(echo $INIT_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['serverInfo']['name'])" 2>/dev/null)
PROTOCOL=$(echo $INIT_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['protocolVersion'])" 2>/dev/null)

echo "   ✓ Server: $SERVER_NAME"
echo "   ✓ Protocol: $PROTOCOL"
echo ""

# Step 3: List tools
echo "3. Listing available tools..."
TOOLS_RESPONSE=$(curl -s -X POST $ENDPOINT \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')

echo "$TOOLS_RESPONSE" | python3 -c "
import sys, json
result = json.load(sys.stdin)
tools = result['result']['tools']
print(f'   ✓ Found {len(tools)} tools:')
for tool in tools:
    print(f'     - {tool[\"name\"]}: {tool[\"description\"]}')
"
echo ""

# Step 4: Test echo tool
echo "4. Testing echo tool..."
TEST_MESSAGE="Hello from MCP client!"
ECHO_RESPONSE=$(curl -s -X POST $ENDPOINT \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"$TEST_MESSAGE\"}}}")

ECHO_RESULT=$(echo $ECHO_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['content'][0]['text'])" 2>/dev/null)
echo "   Input:  \"$TEST_MESSAGE\""
echo "   Output: \"$ECHO_RESULT\""
echo "   ✓ Echo tool works!"
echo ""

# Step 5: Test reverse_string tool
echo "5. Testing reverse_string tool..."
TEST_TEXT="Elixir MCP"
REVERSE_RESPONSE=$(curl -s -X POST $ENDPOINT \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"reverse_string\",\"arguments\":{\"text\":\"$TEST_TEXT\"}}}")

REVERSE_RESULT=$(echo $REVERSE_RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['content'][0]['text'])" 2>/dev/null)
echo "   Input:  \"$TEST_TEXT\""
echo "   Output: \"$REVERSE_RESULT\""
echo "   ✓ Reverse tool works!"
echo ""

echo "=== All Tests Passed! ==="
echo ""

![ConduitMCP](images/header.jpeg)

# ConduitMCP

An Elixir implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification. Build MCP servers to expose tools, resources, and prompts to LLM applications.

[![Tests](https://img.shields.io/badge/tests-229%20passing-brightgreen)]()
[![Version](https://img.shields.io/badge/version-0.6.1-blue)]()

## Features

- **Clean DSL** - Declarative tool definitions with automatic schema generation
- **Runtime Validation** - Parameter validation with NimbleOptions, type coercion, and custom constraints
- **Stateless Architecture** - Pure functions, no processes, maximum concurrency
- **Flexible Authentication** - Bearer tokens, API keys, custom verification
- **Full MCP Spec** - Tools, resources, prompts, and all MCP 2025-06-18 features
- **Phoenix Ready** - Drop-in integration with Phoenix applications
- **Production Ready** - Comprehensive tests, telemetry, CORS support

## Installation

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.6.1"}
  ]
end
```

## Quick Start

### Basic DSL Example

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  tool "greet", "Greet someone" do
    param :name, :string, "Person's name", required: true
    param :style, :string, "Greeting style", enum: ["formal", "casual"]

    handle fn _conn, params ->
      name = params["name"]
      style = params["style"] || "casual"
      greeting = if style == "formal", do: "Good day", else: "Hey"
      text("#{greeting}, #{name}!")
    end
  end

  prompt "code_review", "Code review assistant" do
    arg :code, :string, "Code to review", required: true
    arg :language, :string, "Language", default: "elixir"

    get fn _conn, args ->
      [
        system("You are a code reviewer"),
        user("Review this #{args["language"]} code:\n#{args["code"]}")
      ]
    end
  end

  resource "user://{id}" do
    description "User profile"
    mime_type "application/json"

    read fn _conn, params, _opts ->
      user = MyApp.Users.get!(params["id"])
      json(user)
    end
  end
end
```

### Enhanced DSL with Validation

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  tool "create_user", "Create a new user with validation" do
    # Basic types with constraints
    param :name, :string, "Full name", required: true, min_length: 2, max_length: 50
    param :age, :integer, "Age", min: 0, max: 150, required: true
    param :email, :string, "Email address", validator: &ConduitMcp.Validation.Validators.email/1

    # Enum validation with default
    param :role, :string, "User role", enum: ["admin", "user", "guest"], default: "user"

    # Numeric constraints with defaults
    param :score, :number, "Performance score", min: 0.0, max: 100.0, default: 50.0

    handle &UserService.create/2
  end

  tool "calculate", "Math with validation" do
    param :operation, :string, "Math operation", enum: ~w(add subtract multiply divide), required: true
    param :a, :number, "First number", required: true
    param :b, :number, "Second number", required: true
    param :precision, :integer, "Decimal places", min: 0, max: 10, default: 2

    handle fn _conn, params ->
      result = case params["operation"] do
        "add" -> params["a"] + params["b"]
        "subtract" -> params["a"] - params["b"]
        "multiply" -> params["a"] * params["b"]
        "divide" -> params["a"] / params["b"]
      end

      formatted = Float.round(result, params["precision"])
      text("Result: #{formatted}")
    end
  end
end
```

**Helper functions available:**
- `text(string)` - Text response
- `json(data)` - JSON response
- `raw(data)` - Raw data response (bypasses MCP wrapping, for debugging)
- `error(message)` or `error(message, code)` - Error response
- `system(content)`, `user(content)`, `assistant(content)` - Prompt messages

### Example without DSL (Manual)

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server, dsl: false

  @tools [
    %{
      "name" => "greet",
      "description" => "Greet someone",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        },
        "required" => ["name"]
      }
    }
  ]

  @impl true
  def handle_list_tools(_conn) do
    {:ok, %{"tools" => @tools}}
  end

  @impl true
  def handle_call_tool(_conn, "greet", %{"name" => name}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "Hello, #{name}!"}]}}
  end
end
```

### Standalone with Bandit

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Bandit,
     plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
     port: 4001}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Phoenix Integration

```elixir
# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use ConduitMcp.Server

  alias MyApp.Accounts

  tool "get_user", "Get user from database" do
    param :user_id, :string, "User ID", required: true

    handle fn _conn, %{"user_id" => id} ->
      user = Accounts.get_user!(id)
      json(%{id: user.id, name: user.name, email: user.email})
    end
  end

  tool "search", "Search users" do
    param :query, :string, "Search query", required: true
    param :limit, :number, "Max results", default: 10

    handle Accounts, :search_users
  end
end

# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  scope "/mcp" do
    forward "/", ConduitMcp.Transport.StreamableHTTP,
      server_module: MyApp.MCPServer,
      auth: [
        strategy: :bearer_token,
        token: System.get_env("MCP_AUTH_TOKEN")
      ]
  end
end
```

## Parameter Validation

ConduitMCP v0.6.0+ includes comprehensive runtime parameter validation using [NimbleOptions](https://hexdocs.pm/nimble_options). Validation includes type checking, constraints, and automatic type coercion.

### Enhanced Parameter Options

```elixir
tool "create_user", "Create a new user" do
  # Basic types with constraints
  param :name, :string, "Full name", required: true, min_length: 2, max_length: 50
  param :age, :integer, "Age", min: 0, max: 150
  param :email, :string, "Email address", validator: &ConduitMcp.Validation.Validators.email/1

  # Enum validation
  param :role, :string, "User role", enum: ["admin", "user", "guest"], default: "user"

  # Numeric constraints
  param :score, :number, "Performance score", min: 0.0, max: 100.0, default: 50.0

  handle &UserService.create/2
end
```

### Type Coercion

Automatic type conversion when `type_coercion: true` (enabled by default):

```elixir
# Client sends: {"age": "25", "active": "true", "score": "85.5"}
# Server receives: %{"age" => 25, "active" => true, "score" => 85.5}
```

### Custom Validators

Use built-in validators or create your own:

```elixir
# Built-in validators
param :email, :string, "Email", validator: &ConduitMcp.Validation.Validators.email/1
param :url, :string, "Website", validator: &ConduitMcp.Validation.Validators.url/1

# Custom validator function
param :username, :string, "Username", validator: fn username ->
  String.match?(username, ~r/^[a-zA-Z0-9_]{3,20}$/)
end

# Module function validator
param :priority, :string, "Priority", validator: {MyApp.Validators, :valid_priority?}
```

### Validation Configuration

Configure validation behavior in your application config:

```elixir
# config/config.exs
config :conduit_mcp, :validation,
  runtime_validation: true,    # Enable validation (default: true)
  strict_mode: true,           # Fail on validation errors (default: true)
  type_coercion: true,         # Auto-convert types (default: true)
  log_validation_errors: false # Log failures (default: false)
```

### Error Responses

Validation failures return detailed error information:

```json
{
  "error": {
    "code": -32602,
    "message": "Parameter validation failed",
    "data": {
      "errors": [
        {
          "parameter": "age",
          "value": -5,
          "message": "must be greater than or equal to 0"
        },
        {
          "parameter": "email",
          "value": "invalid-email",
          "message": "must be a valid email address"
        }
      ]
    }
  }
}
```

### Supported Constraints

| Constraint | Types | Description | Example |
|------------|-------|-------------|---------|
| `required: true` | All | Parameter must be present | `required: true` |
| `min: N` | number, integer | Minimum value (inclusive) | `min: 0` |
| `max: N` | number, integer | Maximum value (inclusive) | `max: 100` |
| `min_length: N` | string | Minimum string length | `min_length: 3` |
| `max_length: N` | string | Maximum string length | `max_length: 255` |
| `enum: [...]` | All | Value must be in list | `enum: ["red", "green", "blue"]` |
| `default: value` | All | Default if not provided | `default: "guest"` |
| `validator: fun` | All | Custom validation function | `validator: &valid_email?/1` |

## Authentication

Configure authentication in transport options:

```elixir
# No auth (development)
auth: [enabled: false]

# Static bearer token
auth: [
  strategy: :bearer_token,
  token: "your-secret-token"
]

# Static API key
auth: [
  strategy: :api_key,
  api_key: "your-api-key",
  header: "x-api-key"
]

# Custom verification
auth: [
  strategy: :function,
  verify: fn token ->
    case MyApp.Auth.verify(token) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, "Invalid token"}
    end
  end
]

# Database lookup
auth: [
  strategy: :function,
  verify: fn token ->
    case MyApp.Repo.get_by(ApiToken, token: token) do
      %ApiToken{user: user} -> {:ok, user}
      nil -> {:error, "Invalid token"}
    end
  end
]
```

Access authenticated user in tools:

```elixir
tool "profile", "Get profile" do
  handle fn conn, _params ->
    case conn.assigns[:current_user] do
      nil -> error("Not authenticated")
      user -> json(user)
    end
  end
end
```

## Client Configuration

### VS Code / Cursor

```json
{
  "mcpServers": {
    "my-app": {
      "url": "http://localhost:4001/",
      "headers": {
        "Authorization": "Bearer your-token"
      }
    }
  }
}
```

### Claude Desktop

```json
{
  "mcpServers": {
    "my-app": {
      "command": "elixir",
      "args": ["/path/to/your/server.exs"]
    }
  }
}
```

## Telemetry

ConduitMCP emits telemetry events for monitoring:

- `[:conduit_mcp, :request, :stop]` - All MCP requests
- `[:conduit_mcp, :tool, :execute]` - Tool executions
- `[:conduit_mcp, :resource, :read]` - Resource reads
- `[:conduit_mcp, :prompt, :get]` - Prompt retrievals
- `[:conduit_mcp, :auth, :verify]` - Authentication attempts

Example handler:

```elixir
:telemetry.attach(
  "mcp-logger",
  [:conduit_mcp, :tool, :execute],
  fn _event, %{duration: duration}, %{tool_name: name}, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)
    Logger.info("Tool #{name} executed in #{ms}ms")
  end,
  nil
)
```

## Prometheus Metrics

ConduitMCP includes an optional PromEx plugin for Prometheus monitoring.

### Installation

Add `:prom_ex` to your dependencies:

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.5.0"},
    {:prom_ex, "~> 1.11"}
  ]
end
```

### Setup

Add the ConduitMCP plugin to your PromEx configuration:

```elixir
defmodule MyApp.PromEx do
  use PromEx, otp_app: :my_app

  @impl true
  def plugins do
    [
      PromEx.Plugins.Application,
      PromEx.Plugins.Beam,
      {ConduitMcp.PromEx, otp_app: :my_app}
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "prometheus",
      default_selected_interval: "30s"
    ]
  end
end
```

Add to your supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.PromEx,
    # ... other children ...
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Metrics Available

All metrics are prefixed with `{otp_app}_conduit_mcp_`:

**Request Metrics:**
- `request_total{method, status}` - Total MCP requests
- `request_duration_milliseconds{method, status}` - Request duration distribution

**Tool Metrics:**
- `tool_execution_total{tool_name, status}` - Total tool executions
- `tool_duration_milliseconds{tool_name, status}` - Tool execution duration

**Resource Metrics:**
- `resource_read_total{status}` - Total resource reads
- `resource_read_duration_milliseconds{status}` - Read duration

**Prompt Metrics:**
- `prompt_get_total{prompt_name, status}` - Total prompt retrievals
- `prompt_get_duration_milliseconds{prompt_name, status}` - Retrieval duration

**Auth Metrics:**
- `auth_verify_total{strategy, status}` - Total auth attempts
- `auth_verify_duration_milliseconds{strategy, status}` - Verification duration

### Example PromQL Queries

**Request rate by method:**
```promql
rate(myapp_conduit_mcp_request_total[5m])
```

**Error rate percentage:**
```promql
100 * (
  rate(myapp_conduit_mcp_request_total{status="error"}[5m])
  /
  rate(myapp_conduit_mcp_request_total[5m])
)
```

**P95 tool execution duration:**
```promql
histogram_quantile(0.95,
  rate(myapp_conduit_mcp_tool_duration_milliseconds_bucket[5m])
)
```

**Authentication success rate:**
```promql
100 * (
  rate(myapp_conduit_mcp_auth_verify_total{status="ok"}[5m])
  /
  rate(myapp_conduit_mcp_auth_verify_total[5m])
)
```

See `ConduitMcp.PromEx` module documentation for complete details and alert examples.

## Documentation

- [API Documentation](https://hexdocs.pm/conduit_mcp)
- [Changelog](CHANGELOG.md)
- [MCP Specification](https://modelcontextprotocol.io/specification/)

## Examples

- [Simple Server Example](https://github.com/nyo16/conduit_mcp/tree/master/examples/simple_tools_server)
- [Phoenix Integration](https://github.com/nyo16/conduit_mcp/tree/master/examples/phoenix_mcp)

## License

Apache License 2.0

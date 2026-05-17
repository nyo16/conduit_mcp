# Endpoint Mode

The Endpoint mode lets you define each MCP tool, resource, and prompt as its own Elixir module, then aggregate them in a central Endpoint.

## Defining Components

### Tool Component

```elixir
defmodule MyApp.Echo do
  use ConduitMcp.Component, type: :tool, description: "Echoes text back"

  schema do
    field :text, :string, "The text to echo", required: true, max_length: 500
  end

  @impl true
  def execute(%{text: text}, _conn) do
    text(text)
  end
end
```

Key points:
- `type: :tool` marks this as a tool component
- `description:` is required for tools
- `schema do ... end` defines input parameters — generates JSON Schema and validation automatically
- `execute/2` receives **atom-keyed** params and a `Plug.Conn`
- Response helpers (`text/1`, `json/1`, `error/1`, `image/1`) are imported automatically

### Resource Component

```elixir
defmodule MyApp.ReadUser do
  use ConduitMcp.Component,
    type: :resource,
    uri: "user://{id}",
    description: "User profile by ID",
    mime_type: "application/json"

  @impl true
  def execute(%{id: id}, _conn) do
    user = MyApp.Users.get!(id)
    {:ok, %{
      "contents" => [%{
        "uri" => "user://#{id}",
        "mimeType" => "application/json",
        "text" => JSON.encode!(user)
      }]
    }}
  end
end
```

Key points:
- `uri:` is required — uses `{param}` placeholders for dynamic segments
- URI params are extracted automatically and passed as atom-keyed map to `execute/2`
- No `schema do ... end` needed — params come from the URI template

### Prompt Component

```elixir
defmodule MyApp.CodeReview do
  use ConduitMcp.Component, type: :prompt, description: "Code review assistant"

  schema do
    field :code, :string, "Code to review", required: true
    field :language, :string, "Programming language", default: "elixir"
  end

  @impl true
  def execute(%{code: code, language: language}, _conn) do
    {:ok, %{
      "messages" => [
        system("You are a #{language} code reviewer"),
        user("Review this code:\n#{code}")
      ]
    }}
  end
end
```

## Schema DSL

The `schema do ... end` block defines parameters with automatic JSON Schema and validation generation.

### Field Types

```elixir
schema do
  field :name, :string, "Name", required: true
  field :age, :integer, "Age", min: 0, max: 150
  field :score, :number, "Score", min: 0.0, max: 100.0
  field :active, :boolean, "Is active", default: true
  field :tags, {:array, :string}, "Tags"
end
```

### Field Options

| Option | Types | Description |
|--------|-------|-------------|
| `required: true` | All | Mark as required |
| `default: value` | All | Default value |
| `enum: [...]` | All | Allowed values |
| `min: n` / `max: n` | number, integer | Numeric bounds |
| `min_length: n` / `max_length: n` | string | String length bounds |
| `validator: fn` | All | Custom validator function |

### Nested Objects

```elixir
schema do
  field :address, :object, "Mailing address", required: true do
    field :street, :string, "Street", required: true
    field :city, :string, "City", required: true
    field :zip, :string, "Zip code"
  end
end
```

## Defining the Endpoint

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Endpoint,
    name: "My Application",
    version: "1.0.0",
    rate_limit: [backend: MyApp.RateLimiter, limit: 60, scale: 60_000],
    message_rate_limit: [backend: MyApp.RateLimiter, limit: 50, scale: 300_000],
    auth: [strategy: :bearer_token, token: "secret"]

  component MyApp.Echo
  component MyApp.ReadUser
  component MyApp.CodeReview
end
```

### Endpoint Options

| Option | Description |
|--------|-------------|
| `:name` | Server name (shown in `initialize` response) |
| `:version` | Server version (shown in `initialize` response) |
| `:rate_limit` | HTTP rate limiting config |
| `:message_rate_limit` | Message-level rate limiting config |
| `:auth` | Authentication config |

### Component Registration

Use the `component` macro to register component modules. Components are validated at compile time:
- Must `use ConduitMcp.Component`
- Must implement `execute/2`
- No duplicate names within the same type

## Transport Wiring

The Endpoint's config is **auto-extracted** by transports — no need to duplicate rate_limit/auth/name/version:

```elixir
# Minimal — endpoint config provides name, version, rate_limit, auth
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
 port: 4001}
```

Explicit transport opts always override endpoint config:

```elixir
# Override server name at the transport level
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyApp.MCPServer,
        server_name: "Overridden Name"},
 port: 4001}
```

## Component Options

### Custom Name

By default, the component name is derived from the module name (`MyApp.Echo` → `"echo"`). Override with `:name`:

```elixir
use ConduitMcp.Component,
  type: :tool,
  name: "my_custom_tool",
  description: "Custom named tool"
```

### OAuth Scopes

```elixir
use ConduitMcp.Component,
  type: :tool,
  description: "Delete user",
  scope: "users:write"
```

### Tool Annotations

```elixir
use ConduitMcp.Component,
  type: :tool,
  description: "Fetch data",
  annotations: [readOnlyHint: true, idempotent: true]
```

## Responses

All `execute/2` callbacks must return `{:ok, map()}` or `{:error, map()}`. Helper macros are imported automatically.

### Tool Response Helpers

```elixir
# Plain text
text("Hello!")

# JSON-encoded data
json(%{users: [%{id: 1, name: "Alice"}]})

# Image (base64)
image(Base.encode64(png_data))

# Audio
audio(Base.encode64(wav_data), "audio/wav")

# Error
error("Something went wrong")
error("Bad input", -32602)
```

### Prompt Message Helpers

```elixir
def execute(%{topic: topic}, _conn) do
  {:ok, %{"messages" => [
    system("You are an expert on #{topic}"),
    user("Explain #{topic} in simple terms"),
    assistant("Sure! Let me break it down...")
  ]}}
end
```

### Multi-Content Responses

Return multiple content items (e.g., text + image) by building the map directly:

```elixir
def execute(%{query: query}, _conn) do
  chart_data = MyApp.Charts.generate(query)
  {:ok, %{
    "content" => [
      %{"type" => "text", "text" => "Here are the results for: #{query}"},
      %{"type" => "image", "data" => chart_data, "mimeType" => "image/png"},
      %{"type" => "text", "text" => "Generated at #{DateTime.utc_now()}"}
    ]
  }}
end
```

### Raw Mode

`raw/1` bypasses MCP content wrapping — returns any map directly as `{:ok, map}`:

```elixir
raw(%{"custom_key" => "value", "data" => [1, 2, 3]})
# => {:ok, %{"custom_key" => "value", "data" => [1, 2, 3]}}
```

> **Warning:** Clients expecting the standard MCP `"content"` array won't parse raw responses. Use for debugging or custom integrations only.

### Fully Custom (No Helpers)

You can always skip helpers and return the tuple directly:

```elixir
def execute(%{id: id}, _conn) do
  case MyApp.Repo.get(User, id) do
    nil ->
      {:error, %{"code" => -32002, "message" => "User #{id} not found"}}

    user ->
      {:ok, %{
        "content" => [
          %{"type" => "text", "text" => JSON.encode!(%{
            id: user.id,
            name: user.name,
            roles: user.roles
          })}
        ],
        "isError" => false
      }}
  end
end
```

## Accessing Request Context

The `Plug.Conn` is passed as the second argument to `execute/2`:

```elixir
def execute(_params, conn) do
  user = conn.assigns[:current_user]
  session = conn.private[:mcp_session_data]
  text("Hello #{user}")
end
```

## Capabilities

The Endpoint auto-detects capabilities from registered components. If you only register tools, only `tools` is advertised in the `initialize` response. No manual configuration needed.

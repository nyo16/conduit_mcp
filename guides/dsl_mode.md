# DSL Mode

The DSL mode uses compile-time macros to define tools, resources, and prompts inline in a single server module. Schemas, validation, and handler routing are generated automatically.

## Setup

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server
  # Everything goes here
end
```

## Defining Tools

```elixir
tool "create_user", "Create a new user" do
  param :name, :string, "Full name", required: true, min_length: 2, max_length: 50
  param :age, :integer, "Age", min: 0, max: 150
  param :role, :string, "User role", enum: ["admin", "user", "guest"], default: "user"
  param :score, :number, "Score", min: 0.0, max: 100.0, default: 50.0

  handle fn _conn, params ->
    # params is a string-keyed map: %{"name" => "Alice", "age" => 30, ...}
    text("Created user: #{params["name"]}")
  end
end
```

### Handler Styles

```elixir
# Anonymous function
handle fn _conn, params -> text("ok") end

# Function capture
handle &MyModule.my_function/2

# Module + function reference
handle MyModule, :my_function
```

### Tool Annotations

```elixir
tool "fetch_data", "Fetch data" do
  annotations destructive: false, idempotent: true, readOnlyHint: true
  param :url, :string, "URL", required: true
  handle fn _conn, params -> text("fetched") end
end
```

### OAuth Scopes

```elixir
tool "delete_user", "Delete a user" do
  scope "users:delete"
  param :id, :string, "User ID", required: true
  handle fn _conn, %{"id" => id} -> text("deleted #{id}") end
end
```

## Defining Prompts

```elixir
prompt "code_review", "Code review assistant" do
  arg :code, :string, "Code to review", required: true
  arg :language, :string, "Language", default: "elixir"

  get fn _conn, args ->
    [
      system("You are a #{args["language"]} code reviewer"),
      user("Review this code:\n#{args["code"]}")
    ]
  end
end
```

## Defining Resources

```elixir
resource "user://{id}" do
  description "User profile by ID"
  mime_type "application/json"

  read fn _conn, params, _opts ->
    user = MyApp.Users.get!(params["id"])
    json(user)
  end
end

resource "static://readme" do
  description "Project README"
  mime_type "text/markdown"

  read fn _conn, _params, _opts ->
    text(File.read!("README.md"))
  end
end
```

## Response Helpers

All of these are macros imported automatically:

| Helper | Returns | Example |
|--------|---------|---------|
| `text(string)` | `{:ok, %{"content" => [%{"type" => "text", ...}]}}` | `text("Hello!")` |
| `json(data)` | JSON-encoded text content | `json(%{status: "ok"})` |
| `error(msg)` | `{:error, %{"code" => -32000, ...}}` | `error("Not found")` |
| `error(msg, code)` | Custom error code | `error("Bad params", -32602)` |
| `image(url)` | Image content | `image(base64_data)` |
| `audio(data, mime)` | Audio content | `audio(data, "audio/wav")` |
| `raw(data)` | Bypass MCP wrapping | `raw(%{"custom" => true})` |
| `system(text)` | System role message | For prompts |
| `user(text)` | User role message | For prompts |
| `assistant(text)` | Assistant role message | For prompts |

## Validation

Validation is generated automatically from `param` options. See the README for the full constraints table.

## Custom Validators

```elixir
# Function
param :email, :string, "Email", validator: fn email ->
  String.match?(email, ~r/@/)
end

# Built-in
param :email, :string, "Email", validator: &ConduitMcp.Validation.Validators.email/1

# MFA tuple
param :priority, :string, "Priority", validator: {MyApp.Validators, :valid_priority?}
```

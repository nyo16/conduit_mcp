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

### Header-mirrored Params

On the modern era (`2026-07-28`), `header:` asks clients to copy an argument into an `Mcp-Param-{Name}` HTTP header so gateways can route on it. `ConduitMcp.Plugs.HeaderValidation` rejects a request whose header disagrees with the body (`-32020`, HTTP 400):

```elixir
tool "get_weather", "Weather by region" do
  param :region, :string, "Region", required: true, header: "Region"
  handle fn _conn, %{"region" => region} -> text("Sunny in #{region}") end
end
```

The build fails with a `CompileError` unless the param is `:string`, `:integer` or `:boolean`, isn't inside array `items`, and the name is an HTTP token unique within the tool (case-insensitively). Browser clients also need the header name in the transport's `:cors_headers`. See [Protocol Eras](protocol_eras.md#request-headers).

### Cache Hints

Modern list and read results carry `ttlMs` and `cacheScope`. Override the global default for one tool, prompt or resource with `cache`:

```elixir
tool "catalog", "Public catalog" do
  cache ttl_ms: 5_000, scope: :public
  handle fn _conn, _params -> text("...") end
end
```

A list takes the minimum TTL of its items and is private if any item is private or scoped. `scope` together with `cache scope: :public` is a compile error. See [Protocol Eras](protocol_eras.md#results-and-cache-hints).

### Asking the Client for Input

On a modern request, a `handle`, `get` or `read` handler can return `{:input_required, input_requests, state}`. The retry finds the answers in `conn.assigns[:mcp_input]`. See [MRTR](mrtr.md). A `tools/call` handler can also return `{:task, attrs}` (see [Tasks Extension](tasks_extension.md)).

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

### Completions

`complete` inside a `prompt` (or `resource`) block answers `completion/complete` for one argument (or template parameter):

```elixir
prompt "code_review", "Code review assistant" do
  arg :language, :string, "Language"
  get fn _conn, args -> [user("Review my #{args["language"]}")] end

  complete :language, fn _conn, prefix ->
    Enum.filter(~w(elixir erlang python), &String.starts_with?(&1, prefix))
  end
end

resource "file:///{path}" do
  read MyFiles, :read
  complete :path, &MyFiles.autocomplete/2
end
```

The handler gets the conn and the value typed so far (`""` when the client sent none), and returns a list of strings. It can be an anonymous function, a capture, or `Module, :function`.

- **Response.** The server answers with the first 100 values, `total` and `hasMore`.
- **Errors.** An argument without a completion answers no values; an unknown prompt or resource is `-32602`.
- **Scope.** The block's `scope` also guards its completions.
- **Compile errors.** The name must be one of the prompt's `arg`s or the template's `{params}`, declared at most once per block. `complete` outside a `prompt` or `resource` block is a compile error too.
- **Capability.** Declaring any completion generates `handle_complete/3`, which advertises the `completions` capability.

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

A `read` handler that answers with `text/1`, `json/1`, `image/2` or
`audio/2` is sent as a `ReadResourceResult`: each content block becomes a
`contents` entry for the requested URI. Text is typed with the resource's
`mime_type` (no `mimeType` when it declares none), and image and audio
become `blob` entries with their own MIME type. A result that already has
`"contents"` (`raw_resource/2`, `app_html/1`, or a map you build) is sent
as it is.

## Response Helpers

All of these are macros imported automatically:

| Helper | Returns | Example |
|--------|---------|---------|
| `text(string)` | `{:ok, %{"content" => [%{"type" => "text", ...}]}}` | `text("Hello!")` |
| `json(data)` | JSON-encoded text content | `json(%{status: "ok"})` |
| `error(msg)` | `{:error, %{"code" => -32000, ...}}` | `error("Not found")` |
| `error(msg, code)` | Custom error code | `error("Bad params", -32602)` |
| `image(data, mime)` | Image content | `image(base64_png, "image/png")` |
| `image(url_or_data)` | URL → `resource_link`; base64 PNG/JPEG/GIF/WebP → image with detected MIME type; anything else raises | `image("https://example.com/chart.png")` |
| `audio(data, mime)` | Audio content | `audio(data, "audio/wav")` |
| `raw(data)` | Bypass MCP wrapping | `raw(%{"custom" => true})` |
| `system(text)` | System role message | For prompts |
| `user(text)` | User role message | For prompts |
| `assistant(text)` | Assistant role message | For prompts |

## Validation

Validation is generated automatically from `param` options. See the README for the full constraints table.

## Object and Array Parameters

```elixir
tool "create_user", "Create a user" do
  param :user, :object, "User data", required: true do
    field :name, :string, "Full name", required: true
    field :address, :object, "Address" do
      field :city, :string, "City", required: true
    end
  end

  param :tags, :array, "Tags" do
    items :string
  end

  handle fn _conn, params ->
    text(params["user"]["address"]["city"])
  end
end
```

Nested fields are enforced to any depth and undeclared keys are rejected. Drop
the block for an open object (any keys accepted), or pass
`additional_properties: true` to enforce declared fields and pass the rest
through. Array item schemas are published for clients but not enforced
server-side. Handlers receive string keys at every depth.

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

![ConduitMCP](images/header.jpeg)

# ConduitMCP

An Elixir implementation of the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) specification, serving both protocol eras from one server: modern **2026-07-28** and legacy **2025-11-25** / **2025-06-18**. Build MCP servers to expose tools, resources, and prompts to LLM applications like Claude Desktop, VS Code, and Cursor — and connect to MCP servers from Elixir with the built-in client.

[![CI](https://github.com/nyo16/conduit_mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/nyo16/conduit_mcp/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/conduit_mcp.svg)](https://hex.pm/packages/conduit_mcp)
[![MCP Spec](https://img.shields.io/badge/MCP-2026--07--28%20%2B%202025--11--25%20%2F%202025--06--18-purple)](https://modelcontextprotocol.io/specification/)

## Features

- **MCP Apps** — Tools can return interactive UI rendered as sandboxed iframes in host clients
- **Three Ways to Build** — DSL macros, raw callbacks, or component modules — pick your level of control
- **Dual-era MCP** — One server answers modern 2026-07-28 clients (`server/discover`, MRTR, `subscriptions/listen`, streamed responses, cache hints, header validation) and legacy 2025-11-25 / 2025-06-18 clients; the era is chosen per request
- **MCP Client** — Supervised client for stdio and Streamable HTTP servers in both eras, with a multi-server hub, policy and hooks, LLM provider adapters, and OAuth 2.1
- **Runtime Validation** — NimbleOptions-powered param validation with type coercion and custom constraints
- **Stateless Architecture** — Pure functions, no processes, maximum concurrency via Bandit
- **Authentication** — Bearer tokens, API keys, OAuth 2.1 (RFC 9728), custom verification
- **Rate Limiting** — HTTP-level and message-level rate limiting with Hammer
- **Session Management** — Pluggable session stores (ETS, Redis, PostgreSQL, Mnesia)
- **Observability** — Telemetry events, optional Prometheus metrics via PromEx
- **Phoenix Ready** — Drop-in integration with Phoenix routers
- **CORS & Security** — Configurable origins, preflight handling, origin validation

## Installation

```elixir
def deps do
  [
    {:conduit_mcp, "~> 0.11"}
  ]
end
```

Requires Elixir ~> 1.18.

### Optional dependencies

The core library needs nothing beyond the block above. These features are
compiled in **only when their dependency is present**, so add the ones you
need before you configure the feature:

| Feature | Dependency | Add to `deps` |
|---|---|---|
| `auth: [strategy: :oauth]` — JWT bearer validation ([guide](guides/authentication.md)) | `:joken`, `:jose` | `{:joken, "~> 2.6"}`<br>`{:jose, "~> 1.11"}` |
| `ConduitMcp.OAuth.KeyProvider.JWKS` — fetch signing keys from a JWKS URI | `:req` | `{:req, "~> 0.6.1 or ~> 0.7"}` |
| `ConduitMcp.Plugs.RateLimit` / `ConduitMcp.Plugs.MessageRateLimit` ([guide](guides/rate_limiting.md)) | `:hammer` | `{:hammer, "~> 7.2"}` |
| `ConduitMcp.PromEx` — Prometheus metrics | `:prom_ex` | `{:prom_ex, "~> 1.11"}` |
| Client Streamable HTTP transport and client OAuth ([guide](guides/client.md)) | `:finch` | `{:finch, "~> 0.21"}` |
| Client JSON Schema validation (`validate:`) ([guide](guides/client_permissions_and_hooks.md)) | `:jsv` | `{:jsv, "~> 0.26"}` |

> **Adding one of these later requires a forced rebuild.** These modules are
> guarded by `if Code.ensure_loaded?(Dep)`, which is evaluated once — when
> `:conduit_mcp` is compiled inside your project's `_build`. Mix does not
> recompile an already-built dependency when you add a new one, so run:
>
> ```bash
> mix deps.get
> mix deps.compile conduit_mcp --force
> ```
>
> Skipping this leaves the feature absent. ConduitMCP detects that at
> `init/1` and raises `ConduitMcp.OptionalDependencyError` naming the missing
> dependency and this command, rather than failing at request time.

## Quick Start

Define a server in one module:

```elixir
defmodule MyServer do
  use ConduitMcp.Server

  tool "echo", "Echo a message" do
    param :message, :string, "Message to echo", required: true
    handle fn _conn, %{"message" => msg} -> text(msg) end
  end
end
```

Run it with Bandit:

```elixir
# lib/my_app/application.ex
children = [
  {Bandit, plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyServer}, port: 4000}
]
```

Try it:

```bash
curl -s -X POST http://localhost:4000/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {"name": "echo", "arguments": {"message": "hello"}}
}'
```

For multi-tool servers, authentication, sessions, OAuth, MCP Apps, and more, see the [guides](https://github.com/nyo16/conduit_mcp/tree/master/guides) and [examples](https://github.com/nyo16/conduit_mcp/tree/master/examples).

## Stability

ConduitMCP is pre-1.0. Most APIs are stable; the following are explicitly experimental and may change before 1.0:

- `ConduitMcp.Tasks` and `ConduitMcp.Tasks.Janitor` — legacy (2025-11-25) task lifecycle. Frozen: no new features; modern servers use `ConduitMcp.Ext.Tasks`.
- `ConduitMcp.Ext.Tasks` — the `io.modelcontextprotocol/tasks` extension for 2026-07-28. Off by default and experimental while the extension itself evolves.
- `ConduitMcp.Client.Adapters.Gemini` — the Gemini function-calling adapter is experimental; the Anthropic and OpenAI adapters are not.
- `ConduitMcp.Cancellation` — the cooperative cancellation model may grow a more direct preemption path.

Breaking changes between minor versions will be called out in [CHANGELOG.md](CHANGELOG.md).

Server-to-client input (sampling, elicitation, roots) is built with `ConduitMcp.MRTR` (`elicit/2`, `sample/2`, `list_roots/0`) and returned as `{:input_required, requests, state}`; notification payloads come from `ConduitMcp.Notifications`. `ConduitMcp.Client` is now the MCP client, not a set of message builders.

## Three Ways to Define Servers

ConduitMCP gives you three modes. Each is a complete, independent way to build an MCP server — pick whichever fits your project.

| | DSL Mode | Manual Mode | Endpoint Mode |
|--|----------|-------------|---------------|
| **Style** | Declarative macros | Raw callbacks | Component modules |
| **Schema** | Auto-generated | You build the maps | Auto from `schema do field ... end` |
| **Params** | String-keyed maps | String-keyed maps | Atom-keyed maps |
| **Rate limiting** | Transport option | Transport option | Declarative in `use` opts |
| **Best for** | Quick setup | Maximum control | Larger servers, team projects |

---

### 1. DSL Mode

Everything in one module with compile-time macros. Schemas and validation generated automatically.

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

**Response helpers** (auto-imported): `text/1`, `json/1`, `image/1`, `audio/2`, `error/1`, `raw/1`, `raw_resource/2`, `system/1`, `user/1`, `assistant/1` — see [Responses](#responses) for details and custom response patterns.

---

### 2. Manual Mode

Full control. You implement callbacks directly with raw JSON Schema maps. No compile-time magic.

```elixir
defmodule MyApp.MCPServer do
  use ConduitMcp.Server, dsl: false

  @tools [
    %{
      "name" => "greet",
      "description" => "Greet someone",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }
    }
  ]

  @impl true
  def handle_list_tools(_conn), do: {:ok, %{"tools" => @tools}}

  @impl true
  def handle_call_tool(_conn, "greet", %{"name" => name}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "Hello, #{name}!"}]}}
  end
end
```

---

### 3. Endpoint + Component Mode

Each tool, resource, or prompt is its own module. An Endpoint aggregates them with declarative config for rate limiting, auth, and server metadata.

```elixir
# Each tool is its own module
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

defmodule MyApp.ReadUser do
  use ConduitMcp.Component,
    type: :resource,
    uri: "user://{id}",
    description: "User by ID",
    mime_type: "application/json"

  @impl true
  def execute(%{id: id}, _conn) do
    user = MyApp.Users.get!(id)
    {:ok, %{"contents" => [%{
      "uri" => "user://#{id}",
      "mimeType" => "application/json",
      "text" => JSON.encode!(user)
    }]}}
  end
end

# Endpoint aggregates components
defmodule MyApp.MCPServer do
  use ConduitMcp.Endpoint,
    name: "My App",
    version: "1.0.0",
    rate_limit: [backend: MyApp.RateLimiter, limit: 60, scale: 60_000],
    message_rate_limit: [backend: MyApp.RateLimiter, limit: 50, scale: 300_000]

  component MyApp.Echo
  component MyApp.ReadUser
end
```

Endpoint config is auto-extracted by transports — no duplication needed:

```elixir
{Bandit,
 plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
 port: 4001}
```

See the [Endpoint Mode Guide](guides/endpoint_mode.md) for full details on components, schema DSL, and options.

---

## Running Your Server

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
# lib/my_app_web/router.ex
scope "/mcp" do
  forward "/", ConduitMcp.Transport.StreamableHTTP,
    server_module: MyApp.MCPServer,
    auth: [strategy: :bearer_token, token: System.get_env("MCP_AUTH_TOKEN")]
end
```

### Transports

| Transport | Module | Description |
|-----------|--------|-------------|
| **StreamableHTTP** | `ConduitMcp.Transport.StreamableHTTP` | Recommended. Single `POST /` endpoint for bidirectional communication |
| **SSE** | `ConduitMcp.Transport.SSE` | Legacy. `GET /sse` for streaming, `POST /message` for requests |

Both transports support authentication, rate limiting, CORS, and session management.

## Responses

All tool/resource/prompt handlers return `{:ok, map()}` or `{:error, map()}`. Helper macros are imported automatically in DSL and Endpoint modes.

### Tool Response Helpers

| Helper | What it returns | Use case |
|--------|----------------|----------|
| `text("hello")` | `{:ok, %{"content" => [%{"type" => "text", "text" => "hello"}]}}` | Plain text responses |
| `json(%{a: 1})` | `{:ok, %{"content" => [%{"type" => "text", "text" => "{\"a\":1}"}]}}` | Structured data (Jason-encoded) |
| `image(url_or_base64)` | `{:ok, %{"content" => [%{"type" => "image", ...}]}}` | A URL becomes a `resource_link`; PNG/JPEG/GIF/WebP base64 gets its `mimeType` |
| `image(data, "image/png")` | `{:ok, %{"content" => [%{"type" => "image", "data" => ..., "mimeType" => ...}]}}` | Images with an explicit MIME type |
| `audio(data, "audio/wav")` | `{:ok, %{"content" => [%{"type" => "audio", "data" => ..., "mimeType" => ...}]}}` | Audio clips |
| `error("fail")` | `{:error, %{"code" => -32000, "message" => "fail"}}` | Error with default code |
| `error("fail", -32602)` | `{:error, %{"code" => -32602, "message" => "fail"}}` | Error with custom code |
| `raw(any_map)` | `{:ok, any_map}` | Bypass MCP wrapping entirely |
| `raw_resource(html, "text/html")` | `{:ok, %{"contents" => [%{"mimeType" => ..., "text" => ...}]}}` | Resource content with MIME type |

### Prompt Message Helpers

| Helper | Returns |
|--------|---------|
| `system("You are a reviewer")` | `%{"role" => "system", "content" => %{"type" => "text", "text" => ...}}` |
| `user("Review this code")` | `%{"role" => "user", "content" => %{"type" => "text", "text" => ...}}` |
| `assistant("Here is my review")` | `%{"role" => "assistant", "content" => %{"type" => "text", "text" => ...}}` |

### Multi-Content Responses

Use `texts/1` to return multiple text items in a single response:

```elixir
{:ok, %{"content" => texts(["Line 1", "Line 2", "Line 3"])}}
# => {:ok, %{"content" => [%{"type" => "text", "text" => "Line 1"}, ...]}}
```

### Raw / Fully Custom Responses

For maximum control, skip the helpers entirely and return the map yourself:

```elixir
def execute(_params, _conn) do
  {:ok, %{
    "content" => [
      %{"type" => "text", "text" => "Here is the chart:"},
      %{"type" => "image", "data" => base64_png, "mimeType" => "image/png"},
      %{"type" => "text", "text" => "Analysis complete."}
    ]
  }}
end
```

The `raw/1` helper is a shortcut for returning any map without MCP content wrapping — useful for debugging or non-standard responses:

```elixir
raw(%{"custom_key" => "custom_value", "nested" => %{"data" => [1, 2, 3]}})
# => {:ok, %{"custom_key" => "custom_value", "nested" => %{"data" => [1, 2, 3]}}}
```

> **Note:** `raw/1` bypasses the MCP content structure. Clients expecting standard `"content"` arrays won't parse it correctly. Use it for debugging or custom integrations.

### Error Codes

Standard JSON-RPC 2.0 error codes used by the protocol:

| Code | Meaning |
|------|---------|
| `-32700` | Parse error |
| `-32600` | Invalid request |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |
| `-32000` | Tool/server error (default for `error/1`) |
| `-32002` | Resource not found (legacy era; modern 2026-07-28 clients receive `-32602`) |

Return `ConduitMcp.Protocol.Legacy.resource_not_found()` from `handle_read_resource/2`; the library rewrites it to `-32602` for modern requests. The modern era also uses `-32020` (header mismatch), `-32021` (missing client capability) and `-32022` (unsupported protocol version), from `ConduitMcp.Errors`.

## Parameter Validation

All three modes support runtime validation via [NimbleOptions](https://hexdocs.pm/nimble_options). DSL and Endpoint modes generate validation schemas automatically. Manual mode can opt in via `__validation_schema_for_tool__/1`.

### Constraints

| Constraint | Types | Example |
|------------|-------|---------|
| `required: true` | All | `required: true` |
| `min: N` / `max: N` | number, integer | `min: 0, max: 100` |
| `min_length: N` / `max_length: N` | string | `min_length: 3, max_length: 255` |
| `enum: [...]` | All | `enum: ["red", "green", "blue"]` |
| `default: value` | All | `default: "guest"` |
| `validator: fun` | All | `validator: &valid_email?/1` |
| `additional_properties: bool` | object | `additional_properties: true` |

### Object Parameters

An `:object` param declared with a block validates its nested fields — required,
types, and the constraints above — to any depth, and rejects undeclared keys:

```elixir
param :user, :object, "User data", required: true do
  field :name, :string, "Full name", required: true
  field :address, :object, "Address" do
    field :city, :string, "City", required: true
  end
end
```

Declared with no block it is an open bag: any keys accepted, nothing enforced.
`additional_properties: true` combines the two — declared fields are enforced
and undeclared keys pass through to the handler. The generated JSON Schema
always emits `additionalProperties`, so it agrees with what the server enforces.

Array item types are declared with `items`:

```elixir
param :rows, :array, "Rows" do
  items :object do
    field :id, :integer, "Row id", required: true
  end
end
```

Item schemas are published for clients but **not** enforced server-side —
NimbleOptions cannot attach a nested schema to a list element type.

Handlers always receive string keys, at every depth.

### Type Coercion

Enabled by default. Automatic conversion: `"25"` → `25`, `"true"` → `true`, `"85.5"` → `85.5`.

### Configuration

```elixir
config :conduit_mcp, :validation,
  runtime_validation: true,
  strict_mode: true,
  type_coercion: true,
  log_validation_errors: false
```

## Authentication

Configure in transport options or Endpoint `use` opts:

```elixir
# Bearer token
auth: [strategy: :bearer_token, token: "your-secret-token"]

# API key
auth: [strategy: :api_key, api_key: "your-key", header: "x-api-key"]

# Custom verification
auth: [strategy: :function, verify: fn token ->
  case MyApp.Auth.verify(token) do
    {:ok, user} -> {:ok, user}
    _ -> {:error, "Invalid token"}
  end
end]

# OAuth 2.1 (RFC 9728)
auth: [strategy: :oauth, issuer: "https://auth.example.com", audience: "my-app"]
```

Authenticated user is available via `conn.assigns[:current_user]` in all callbacks.

## Rate Limiting

Two layers using [Hammer](https://hex.pm/packages/hammer) (optional dependency):

```elixir
# Setup: add {:hammer, "~> 7.2"} to deps, then:
defmodule MyApp.RateLimiter do
  use Hammer, backend: :ets
end
```

**HTTP rate limiting** — limits raw connections:

```elixir
rate_limit: [backend: MyApp.RateLimiter, limit: 100, scale: 60_000]
```

**Message rate limiting** — limits MCP method calls (tool calls, reads, prompts):

```elixir
message_rate_limit: [
  backend: MyApp.RateLimiter,
  limit: 50,
  scale: 300_000,
  excluded_methods: ["initialize", "ping"]
]
```

Both support per-user keying via `:key_func`. Returns HTTP 429 with `Retry-After` header.

## Session Management

StreamableHTTP supports server-side sessions with pluggable stores. Sessions are
off unless you configure them:

```elixir
session: []                                 # Opt in, using ConduitMcp.Session.EtsStore
session: [store: MyApp.RedisSessionStore]   # Opt in with a custom store
session: false                              # Off — same as omitting :session
```

Any other `:session` value (`true`, a map) raises `ArgumentError` at the
transport's `init/1`, so the mistake fails at boot.

See guides: [Multi-Node Sessions](guides/multi_node_sessions.md)

## Telemetry

Events emitted for monitoring:

| Event | Description |
|-------|-------------|
| `[:conduit_mcp, :request, :stop]` | All MCP requests |
| `[:conduit_mcp, :tool, :execute]` | Tool executions |
| `[:conduit_mcp, :resource, :read]` | Resource reads |
| `[:conduit_mcp, :prompt, :get]` | Prompt retrievals |
| `[:conduit_mcp, :rate_limit, :check]` | HTTP rate limit checks |
| `[:conduit_mcp, :message_rate_limit, :check]` | Message rate limit checks |
| `[:conduit_mcp, :auth, :verify]` | Authentication attempts |

Optional Prometheus metrics via `ConduitMcp.PromEx` — see module docs.

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

## Building an MCP client

`ConduitMcp.Client` is one supervised connection to one MCP server. It probes `server/discover` and falls back to `initialize`, so it talks to modern and legacy servers alike. The application starts no clients; add them to your own supervision tree.

```elixir
children = [
  # A local server over stdio (no shell; allowlisted environment)
  {ConduitMcp.Client,
   name: MyApp.Files,
   transport:
     {ConduitMcp.Client.Transport.Stdio,
      command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"]}},

  # A remote server over Streamable HTTP (needs :finch)
  {ConduitMcp.Client,
   name: MyApp.GitHub,
   transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/mcp"}}
]

:ok = ConduitMcp.Client.await_ready(MyApp.Files, 10_000)
{:ok, tools} = ConduitMcp.Client.list_all_tools(MyApp.Files)
{:ok, result} = ConduitMcp.Client.call_tool(MyApp.Files, "read_file", %{"path" => "/srv/data/a.txt"})
```

To give a model the tools of several servers, run a `ConduitMcp.Client.Hub`. It requires a `:policy`, names tools `server__tool`, and routes every call through the governed pipeline (policy, approval, hooks):

```elixir
{ConduitMcp.Client.Hub,
 name: MyApp.Hub,
 policy: [deny: ["*/delete_*"], allow: ["github/get_*", "fs/read_*"]],
 servers: [
   github: [transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/mcp"}],
   fs: [transport: {ConduitMcp.Client.Transport.Stdio, command: "mcp-fs"}]
 ]}

{:ok, toolset} = ConduitMcp.Client.Hub.list_tools(MyApp.Hub)
{:ok, result} = ConduitMcp.Client.Hub.call_tool(MyApp.Hub, "github__get_issue", %{"number" => 1}, toolset: toolset)
```

Safe defaults, each documented in [Client security](guides/client_security.md):

- **Secrets.** Credentials are `ConduitMcp.Client.Secret` values that never print and refuse to JSON-encode. Crash reports and telemetry carry no tokens, tool arguments or results.
- **Tokens.** A token must be visible ASCII; a trailing newline from `File.read!/1` is refused instead of leaking into an error.
- **Address checks.** `server_url_policy: :public_only` connects to the address it checked, so DNS rebinding can't redirect the request.
- **Credential-scoped cache.** Private results are cached per credential, and `ConduitMcp.Client.set_auth/3` switches credentials at runtime.
- **Hub limits.** A hub restarts a failed server with jittered backoff (at most 30 s) and runs at most 16 stdio servers (`max_stdio_servers`).

Guides: [Client](guides/client.md), [Permissions and hooks](guides/client_permissions_and_hooks.md), [Hub](guides/client_hub.md), [LLM adapters](guides/client_llm_adapters.md) (Anthropic, OpenAI, Gemini), [OAuth](guides/client_oauth.md), [Security](guides/client_security.md).

## MCP Spec Coverage

ConduitMCP implements the [MCP specification](https://modelcontextprotocol.io/specification/) in both eras. The server picks the era per request; the client negotiates it per connection.

| Feature | Status | Spec Version |
|---------|--------|-------------|
| Tools (list, call) | Supported | 2025-06-18, 2026-07-28 |
| Resources (list, read, templates) | Supported | 2025-06-18, 2026-07-28 |
| Prompts (list, get) | Supported | 2025-06-18, 2026-07-28 |
| Completion | Supported | 2025-06-18, 2026-07-28 |
| Logging | Supported | 2025-06-18 (`logging/setLevel`), 2026-07-28 (per-request `logLevel`) |
| Protocol negotiation (`initialize`) | Supported | 2025-11-25, 2025-06-18 |
| `server/discover` | Supported | 2026-07-28 |
| Session management | Supported | 2025-11-25 |
| Resource subscriptions (`resources/subscribe`) | Supported | 2025-06-18 |
| `subscriptions/listen` (list changes, resource updates, task status) | Supported | 2026-07-28 |
| Multi round-trip requests (MRTR: elicitation, sampling, roots) | Supported | 2026-07-28 |
| Streamed tool responses (progress, log notifications) | Supported | 2026-07-28 |
| Cache hints (`ttlMs`, `cacheScope`) | Supported | 2026-07-28 |
| Header validation (`Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`) | Supported | 2026-07-28 |
| Tasks (`tasks/*`) | Supported (frozen) | 2025-11-25 |
| Tasks extension (`io.modelcontextprotocol/tasks`) | Experimental | 2026-07-28 extension |
| OAuth 2.1 (RFC 9728) resource server | Supported | 2025-11-25, 2026-07-28 |
| StreamableHTTP transport | Supported | 2025-11-25, 2026-07-28 |
| SSE transport (legacy) | Supported | 2025-06-18 |
| MCP Apps (ext-apps) | Supported | Extension |
| Client: stdio and Streamable HTTP transports | Supported | 2025-06-18, 2025-11-25, 2026-07-28 |
| Client: sampling, elicitation, roots, tasks | Supported | 2025-06-18, 2025-11-25, 2026-07-28 |
| Client: OAuth 2.1 (PKCE, CIMD, DCR, step-up, client credentials) | Supported | 2025-11-25, 2026-07-28 |

## Guides

- [Choosing a Mode](guides/choosing_a_mode.md) — DSL vs Manual vs Endpoint comparison
- [Endpoint Mode](guides/endpoint_mode.md) — Component modules, schema DSL, full walkthrough
- [Authentication](guides/authentication.md) — All auth strategies in detail
- [Rate Limiting](guides/rate_limiting.md) — HTTP and message rate limiting
- [Multi-Node Sessions](guides/multi_node_sessions.md) — Redis, PostgreSQL, Mnesia session stores
- [Oban Tasks](guides/oban_tasks.md) — Long-running tasks with Oban
- [MCP Apps](guides/mcp_apps.md) — Interactive UI from MCP tools
- [Protocol Eras](guides/protocol_eras.md) — How one server serves 2026-07-28 and 2025-11-25 / 2025-06-18
- [MRTR](guides/mrtr.md) — Asking the client for input from a tool, resource or prompt
- [Subscriptions](guides/subscriptions.md) — `subscriptions/listen` and `ConduitMcp.notify_*`
- [Tasks Extension](guides/tasks_extension.md) — `ConduitMcp.Ext.Tasks` (experimental)
- [Client](guides/client.md), [Hub](guides/client_hub.md), [Permissions and Hooks](guides/client_permissions_and_hooks.md), [LLM Adapters](guides/client_llm_adapters.md), [Client OAuth](guides/client_oauth.md), [Client Security](guides/client_security.md)

## Documentation

- [API Documentation](https://hexdocs.pm/conduit_mcp)
- [Changelog](CHANGELOG.md)
- [MCP Specification](https://modelcontextprotocol.io/specification/)

## Examples

- [Simple Server Example](https://github.com/nyo16/conduit_mcp/tree/master/examples/simple_tools_server)
- [Phoenix Integration](https://github.com/nyo16/conduit_mcp/tree/master/examples/phoenix_mcp)
- [MCP Apps Demo](https://github.com/nyo16/conduit_mcp/tree/master/examples/mcp_apps_demo)

## License

Apache License 2.0

# Client Hub

`ConduitMcp.Client.Hub` puts many MCP servers behind one tool list. It
supervises one `ConduitMcp.Client` per server, lists their tools under
collision-free names, and routes a model's tool call to the right server
through the governed pipeline.

```elixir
children = [
  {ConduitMcp.Client.Hub,
   name: MyApp.Hub,
   policy: [
     deny: ["*/delete_*"],
     ask: ["github/*"],
     allow: ["github/get_*", "fs/read_*"]
   ],
   on_ask: &MyApp.Approvals.ask/2,
   hooks: [post_tool_call: [{:all, &MyApp.Audit.result/3, id: :audit, on_error: :ignore}]],
   servers: [
     github: [transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/mcp"}],
     fs: [transport: {ConduitMcp.Client.Transport.Stdio, command: "mcp-fs"}, trusted: true]
   ]}
]

{:ok, toolset} = ConduitMcp.Client.Hub.list_tools(MyApp.Hub)
ConduitMcp.Client.ToolSet.names(toolset)
#=> ["github__get_issue", "github__create_issue", "fs__read_file", ...]

{:ok, result} =
  ConduitMcp.Client.Hub.call_tool(MyApp.Hub, "github__get_issue", %{"number" => 1}, toolset: toolset)
```

The application starts no hub; add one to your own supervision tree. Options
are validated when the child spec is built (`ConduitMcp.Client.Hub.Config`),
so a typo, a duplicate server id or a missing `:policy` raises at boot naming
it. To hand the toolset to a model, see
[client_llm_adapters.md](client_llm_adapters.md).

## A policy is required

A hub hands tools to a model, so it refuses to start without `:policy`. To
allow everything, say so:

```elixir
{ConduitMcp.Client.Hub, name: MyApp.Hub, policy: :allow_all, servers: [...]}
```

`:allow_all` is `ConduitMcp.Client.Policy.allow_all/0`: `allow: ["*/*"]`
with `allow_new_tools: true` and `pin_tools: false`. It is never a default.
`:policy` also takes `ConduitMcp.Client.Policy.compile/1` options, a compiled
policy, or `{:named, name}`.

Rules match the `{server_id, tool}` pair (`"github/create_*"`), never the
exposed name `github__create_issue`. With no matching rule, a call is asked
about when there is an `:on_ask` approver and denied otherwise. Rules,
approvals and hooks are covered in
[client_permissions_and_hooks.md](client_permissions_and_hooks.md).

## Servers and per-server options

`servers:` is `[{server_id, client_opts}]` (or a keyword list with atom ids),
in the order their tools are listed. `client_opts` are `ConduitMcp.Client`
options except `:name` and `:server_id`, which the hub sets: each server runs
as a client named `{:hub_server, hub, server_id}`.

```elixir
client = ConduitMcp.Client.Hub.client(MyApp.Hub, "github")
#=> {:hub_server, MyApp.Hub, "github"}

{:ok, %{"contents" => _}} = ConduitMcp.Client.read_resource(client, "repo://a/b/README.md")
{:ok, %{state: :ready}} = ConduitMcp.Client.status(client)
```

The hub's governance options (`:policy`, `:on_ask`, `:ask_timeout`,
`:grant_ttl`, `:hooks`, `:hook_timeout`, `:tools`, `:validate`,
`:max_result_bytes_for_llm`, `:clock`) apply to every server. The same key in
a server's `client_opts` overrides the hub's for that server, except:

| Option | Merge rule |
|---|---|
| `:hooks` | The hub's hooks of an event run before the server's (both must be keyword lists) |
| `:tools` | The server's `:exclude` patterns are added to the hub's; its `:include` patterns, when it has any, replace the hub's |
| `:policy` | May be replaced (`:allow_all` included) but never removed |

```elixir
servers: [
  web: [
    transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://search.example.com/mcp"},
    tools: [exclude: ["*/fetch_raw"]],
    policy: [allow: ["web/search"], default: :deny]
  ],
  fs: [transport: {ConduitMcp.Client.Transport.Stdio, command: "mcp-fs"}, trusted: true]
]
```

`trusted: true` is per server: it lets policy annotation rules believe that
server's tool hints.

Other hub options: `:prefix` (prepended to every exposed name),
`:restart_backoff` and `:max_stdio_servers` (see "Supervision and
restarts"), `:refetch_interval` and `:breaker_threshold` (below).

## Naming

The model sees one flat list of names. `ConduitMcp.Client.Naming.build/2`
makes them:

1. **Spec charset.** A tool whose name is not 1-128 characters of
   `[A-Za-z0-9_.-]` is rejected (`:invalid_name`). This catches homoglyphs,
   zero-width and bidi characters, spaces and empty names.
2. **Mangle.** The exposed name is `prefix <> server_id <> "__" <>
   sanitize(tool)`, where `sanitize/1` maps every character outside
   `[A-Za-z0-9_-]` to `_`.
3. **Length.** A name over 64 bytes becomes `prefix <> "trunc_" <> hex8`,
   where `hex8` is the first 8 hex digits of `sha256(server_id <> <<0>> <>
   tool)`.
4. **Collisions.** When two or more tools map to the same exposed name,
   **all** of them are rejected (`:collision`).

Every exposed name matches `^[A-Za-z0-9_-]{1,64}$`, valid for Anthropic,
OpenAI and Gemini. A model's call is resolved by a table lookup in the
`ConduitMcp.Client.ToolSet` (`ToolSet.resolve/2`), never by splitting the
name, so a tool name containing `__` cannot reach another server's tool.

```elixir
ConduitMcp.Client.Naming.sanitize("fs.read-all")       #=> "fs_read-all"
ConduitMcp.Client.Naming.exposed_name("files", "list") #=> "files__list"
```

### Server ids

A `server_id` is operator configuration, never the server's self-reported
`serverInfo.name` (display only). It must match `^[a-z][a-z0-9_]{0,31}$`,
must not contain `__`, must not end in `_`, and must be unique. The last two
rules keep the `__` separator unambiguous: otherwise `"a_" <> "__" <> "x"` and
`"a" <> "__" <> "_x"` would both be `"a___x"`.

```elixir
ConduitMcp.Client.Naming.validate_server_id("github")   #=> :ok
ConduitMcp.Client.Naming.validate_server_id("git__hub") #=> {:error, :double_underscore}
ConduitMcp.Client.Naming.validate_server_id("github_")  #=> {:error, :trailing_underscore}
```

### Collisions

Picking a winner would let one server shadow another's tool, so a collision
excludes every tool involved. A warning is logged, and the caller that built
the toolset emits `[:conduit_mcp, :client, :hub, :collision]` (once per
distinct tool list) plus a `[:conduit_mcp, :client, :tool, :rejected]` with
`reason: :collision` per tool. Rename the server id or filter one of the
tools out to resolve it.

## Listing tools

`list_tools/2` keeps no aggregated index. It reads each server client's
cache and builds a `ToolSet`:

- only servers whose connection is `:ready` contribute; a starting,
  reconnecting, failed or closed server's tools are left out;
- servers in configuration order (runtime additions after), then each
  server's tools in the order it listed them, which keeps the list stable for
  prompt caching;
- each server's tools first pass its `:tools` filter and `:on_tools_listed`
  hooks (with the call's `:assigns` and `:principal`), so a hidden tool is
  never offered.

```elixir
{:ok, toolset} = ConduitMcp.Client.Hub.list_tools(MyApp.Hub, principal: user_id, assigns: %{user: user})
{:ok, toolset} = ConduitMcp.Client.Hub.list_tools(MyApp.Hub, refresh: true)
```

Options: `:assigns`, `:principal`, `:timeout` (per server fetch, default
5 000 ms; a server that does not answer in time is left out) and `:refresh`
(fetch every ready server's list now).

A server's list is fetched by the hub only when the cache has none, when it
is stale (a `list_changed` arrived, or the connection was lost) or past a
positive `ttlMs`, and at most once per `:refetch_interval` (1 000 ms) per
server. After `:breaker_threshold` (3) consecutive failed fetches, the
server's tools are left out until a fetch succeeds.

## Calling tools

```elixir
case ConduitMcp.Client.Hub.call_tool(MyApp.Hub, exposed_name, args,
       toolset: toolset,
       principal: user_id,
       taint: ["web"]
     ) do
  {:ok, %ConduitMcp.Client.ToolResult{} = result} -> result
  {:error, %ConduitMcp.Client.Error{kind: :unavailable}} -> :server_down
  {:error, %ConduitMcp.Client.Error{kind: :denied}} -> :denied
end
```

- Pass the toolset the model saw as `toolset:`, so the name resolves against
  exactly what it was offered. Without it, the current one is built.
- An **unknown name** is answered `{:ok, %ToolResult{is_error: true}}`
  saying so, and **nothing is sent** to any server.
- A known name runs `ConduitMcp.Client.Pipeline.run/3` on the owning
  server's client: selection, hooks, validation, policy and approval, the
  request, post-hooks. Multi-round-trip retries always go to that same
  server.
- A server that is not running, reconnecting or closed gives
  `{:error, %Error{kind: :unavailable}}` at once.

Every pipeline option works: `:principal`, `:assigns`, `:taint`, `:shape`,
`:meta`, `:timeout`, `:task` and the progress options.

### Taint

Pass `taint:` with the server ids whose output is in the model's context.
`ConduitMcp.Client.Policy.tainted/1` rules can then react to cross-server
data flow, for example asking before an open-world tool once untrusted
output is in context:

```elixir
policy: [
  ask: [{:all, [{:annotation, :open_world, true}, ConduitMcp.Client.Policy.tainted()]}],
  deny: [{:all, ["mail/send", ConduitMcp.Client.Policy.tainted(ignore: ["docs"])]}],
  allow: ["*/*"]
]
```

## Status and runtime changes

```elixir
{:ok, ["github", "fs"]} = ConduitMcp.Client.Hub.servers(MyApp.Hub)

{:ok, [%{id: "github", state: :ready, era: :modern, attempts: 0}, _]} =
  ConduitMcp.Client.Hub.status(MyApp.Hub)

:ok =
  ConduitMcp.Client.Hub.add_server(MyApp.Hub, "linear",
    transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.linear.app/mcp"}
  )

:ok = ConduitMcp.Client.Hub.remove_server(MyApp.Hub, "linear")
```

`status/1` reports each server as `:starting`, `:failed` (waiting to be
started again; `attempts` counts consecutive failures, `reason` tags the last
exit) or its connection's state.

`add_server/3` is idempotent: when the id is present, nothing changes (remove
it first to change its options). It raises `ArgumentError` on an invalid id
or option. `remove_server/2` returns `{:error, %Error{kind: :not_found}}` for
an unknown id.

**Servers added at runtime are not durable.** They survive a restart of the
hub's manager but not of the hub. Re-add them from your own store after the
hub starts. A server from `servers:` that you removed stays removed until the
hub restarts.

## Supervision and restarts

The hub is a `:rest_for_one` supervisor of an OAuth token store, a
`Task.Supervisor` (for adapter calls and listing fetches), a
`DynamicSupervisor` holding the server clients, and a manager process.
Starting never blocks: servers start after `start_link/1` returns, and each
connects in the background.

Server clients are `restart: :temporary`. When one exits (a bug, or its own
supervisor giving up after repeated connection crashes), the manager starts
it again after a jittered backoff: `:restart_backoff`, by default full
jitter from 1 s, doubling, capped at 30 s. `attempt` counts consecutive
failures and starts over once a server ran for a minute; each failure emits
`[:conduit_mcp, :client, :hub, :server_failed]` with the `:delay` and
`:attempt`. One crash-looping server never exhausts a supervisor's restart
intensity or takes the others down. Each client is itself a `:one_for_all`
supervisor allowing 3 restarts in 5 s, so a connection that keeps crashing
takes its client down within seconds and the hub's backoff paces the rest.
Within a running client, ordinary connection failures are handled by its
own reconnect loop (see [client.md](client.md)).

A hub runs at most `:max_stdio_servers` (default 16) servers whose
transport starts a local process (`kind/0` `:stdio`, such as
`ConduitMcp.Client.Transport.Stdio`), whether running or waiting to
restart. More in `servers:` raises `ArgumentError` naming the option when
the hub starts; `add_server/3` beyond the cap returns
`{:error, %ConduitMcp.Client.Error{kind: :overloaded, reason:
:max_stdio_servers}}` and starts nothing. `max_stdio_servers: :infinity`
lifts the cap.

## OAuth servers

The hub starts one in-memory `ConduitMcp.Client.OAuth.TokenStore.ETS` and
gives it to every server whose `auth: {:oauth, opts}` or
`auth: {:client_credentials, opts}` names no `:store`. A server's own
`:store` is kept. Tokens stay keyed by `{principal, issuer, resource}`, so a
server never receives another server's token, but:

- servers behind the same authorization server share one dynamic client
  registration instead of registering once each;
- a server client the manager restarts, or one you remove and add again,
  finds its tokens and needs no new authorization.

The store lives as long as the hub. For tokens that survive a hub restart,
give each server a persistent store; see
[client_oauth.md](client_oauth.md#token-stores).

## Per-user hubs

Each server client sends one set of credentials at a time. Its private
cached results are keyed by them and never served to other credentials
(see "Private results and credentials" in [client.md](client.md)), but its
grants and approval baseline belong to the client. When servers answer
differently per user (private results, per-user OAuth tokens), run **one
hub per credential**:

```elixir
DynamicSupervisor.start_child(MyApp.Hubs,
  {ConduitMcp.Client.Hub,
   name: {MyApp.Hub, user.id},
   policy: MyApp.Policy.for(user),
   servers: [
     github: [
       transport:
         {ConduitMcp.Client.Transport.StreamableHTTP,
          url: "https://mcp.example.com/mcp",
          finch: MyApp.MCPFinch,
          auth: {:bearer, ConduitMcp.Client.Secret.new(user.github_token)}}
     ]
   ]}
)
```

Hub names may be any term. Share one Finch pool with `finch:` for HTTP
servers, since the default per-client pool creates one atom per distinct
client name. Within one hub, pass `principal:` on calls so "always allow"
grants stay per user.

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:conduit_mcp, :client, :hub, :server_failed]` | `:count`, `:delay` (ms until the restart) | `:hub`, `:server_id`, `:attempt`, `:reason` (a closed-set tag) |
| `[:conduit_mcp, :client, :hub, :server_restarted]` | `:count` | `:hub`, `:server_id`, `:attempt` |
| `[:conduit_mcp, :client, :hub, :collision]` | `:count` (colliding tools) | `:hub`, `:exposed_name`, `:colliders` (`[{server_id, tool_name}]`; never a metric tag) |

Each server's client emits the usual client events with
`client: {:hub_server, hub, server_id}`.

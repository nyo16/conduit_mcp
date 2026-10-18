# Client Permissions and Hooks

A plain `ConduitMcp.Client` sends what it is asked to. Before you hand a
client to a model, decide which tools it may see, which calls it may make,
who approves the risky ones, and what host code runs around each call.

```elixir
{ConduitMcp.Client,
 name: :github,
 server_id: "github",
 transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/mcp"},
 tools: [exclude: ["*/delete_*"]],
 policy: [
   deny: ["*/delete_repo", "admin_*"],
   ask: ["github/create_*", "github/merge_*"],
   allow: ["github/get_*", "github/list_*"]
 ],
 on_ask: &MyApp.Approvals.ask/2,
 hooks: [post_tool_call: [{:all, &MyApp.Audit.result/3, id: :audit, on_error: :ignore}]],
 validate: [arguments: true]}
```

## When governance applies

`call_tool/4` runs through `ConduitMcp.Client.Pipeline` when the client is
configured with any of `:policy`, `:hooks`, `:tools` (a filter) or
`:validate`, or when the call passes `shape: :llm`. Otherwise the call is
sent as given: **a plain client has no policy**. A `ConduitMcp.Client.Hub`
always has one, because it refuses to start without `:policy`.

The pipeline runs in the calling process. Hooks and approvers run in tasks
under the client's `Task.Supervisor`, never in the connection.

## The pipeline

Every step runs once per logical call, in this order:

| # | Step | What happens |
|---|---|---|
| 1 | Resolve | Find the tool in the client's cache, listing tools first if nothing is cached. Unknown: `{:error, %Error{kind: :not_found, reason: :unknown_tool}}` |
| 2 | Select | A tool hidden by the `:tools` filter fails exactly like an unknown one, so its name cannot be probed |
| 3 | Fingerprint | Gather the approved fingerprints for the policy's pin |
| 4 | Pre-hooks | May rewrite the arguments, deny, halt with a synthetic result, or fail closed |
| 5 | Input validation | With `validate: [arguments: true]`, invalid arguments are never sent |
| 6 | Policy | `ConduitMcp.Client.Policy.evaluate/4` on the **final** arguments: deny > pin > ask > allow > default |
| 7 | Ask | An `:ask` is settled by a live grant or by the `:on_ask` approver |
| 8 | Encode | The arguments' digest must still be the one policy and the approver saw (else `kind: :hook, reason: :args_changed`); `meta` becomes `_meta`, with reserved keys winning |
| 9 | Send | Including the modern multi-round-trip loop; each input request goes through the `ConduitMcp.Client.Handler` safety checks. Nothing above runs again per round |
| 10 | Output validation | With `validate: [structured_content: true]` |
| 11 | Post-hooks | On a result (including `is_error` results), or **failure hooks** on an error from step 3 on |
| 12 | Shaping | With `shape: :llm` |
| 13 | Telemetry | `[:conduit_mcp, :client, :tool_call, :stop]` |

Pipeline call options, besides the request options in the client guide:

- `:principal` - who the call is made for (the end user the host acts for).
  It is in `ctx`, and it keys "always allow" grants.
- `:shape` - `:llm` to shape the result for a model.
- `:taint` - the server ids whose output is in the model's context (see
  "Taint").

Hooks, the approver, filter functions and policy predicates get `ctx` with
`:client`, `:server_id` (where the call goes), `:era`, `:assigns`,
`:principal`, `:taint` (a `MapSet`), `:has_approver?` and, from step 3,
`:approved_fingerprints`.

## Visibility: the `:tools` filter

Visibility is separate from authorization. A hidden tool is left out of
every tool list and adapter output, and calling it fails with
`kind: :not_found`.

```elixir
tools: [
  include: ["github/*", "fs/read_*"],
  exclude: ["*/delete_*", fn tool, ctx -> MyApp.hidden_for?(ctx.assigns.user, tool) end]
]
```

`:exclude` always wins. An empty `:include` (the default) shows every tool
not excluded. Exclude patterns match loosely and include patterns exactly,
like policy deny and allow rules. A function that raises or returns a
non-boolean counts as matching for `:exclude` and not matching for
`:include`. Function patterns see `:assigns` and `:principal`, so pass them
to `list_all_tools/2`, `cached_tools/2` and `tool/3` too.

## Policy rules

```elixir
policy: [
  deny: ["*/delete_*", "shell/*", {:rule, :no_force_push, {"git", ~r/^push/}}],
  ask: [{:all, [{:annotation, :open_world, true}, ConduitMcp.Client.Policy.tainted()]}],
  allow: [
    "github/get_*",
    {:all, ["fs/*", {:annotation, :read_only, true}]},
    fn tool, ctx -> ctx.assigns[:role] == :admin and tool.server_id == "ops" end
  ],
  default: :ask,
  trusted: ["fs"]
]
```

`:policy` takes `ConduitMcp.Client.Policy.compile/1` options, a compiled
policy, or `{:named, name}` to read a policy stored with
`ConduitMcp.Client.Policy.update/2` at each call (a missing one denies).
Compiling raises an `ArgumentError` naming the bad entry.

| Rule | Matches |
|---|---|
| `"server/tool"` | `*` globs within one segment; a bare `"tool"` means any server |
| `{server, ~r/.../}` | The regex against the tool name; `server` is a segment glob |
| `fn %Tool{}, ctx -> boolean end` | Any condition on the tool and the call context |
| `{:annotation, key, boolean}` | `key` in `:read_only`, `:destructive`, `:open_world`, `:idempotent`, compared on the tool's effective annotation |
| `{:args, fun}` | `fun.(args)` or `fun.(args, ctx)` on the final arguments; see `ConduitMcp.Client.Policy.Paths` |
| `{:all, [rule, ...]}` | Every member matches |
| `{:rule, id, rule}` | Any rule with an explicit `rule_id` (an atom or string); otherwise the id is `{list, index}` |

Every rule matches the structured `{server_id, tool}` pair one segment at a
time, never a namespaced string, so server `a_b` + tool `c` and server `a` +
tool `b_c` are never confused.

Compile options: `:deny`, `:ask`, `:allow` (rule lists), `:default` (`:ask`
or `:deny`), `:scope` (a subset of `[:tools, :resources, :prompts]`,
default `[:tools]`), `:pin_tools` (default `true`), `:allow_new_tools`
(default `false`) and `:trusted`.

### Precedence

Fixed and not configurable: **deny > pin > ask > allow > default**. List
order and rule specificity never change the outcome. A narrow allow cannot
carve an exception out of a broad deny. Within one list, order only picks
which `rule_id` is reported.

Without an approver (`:on_ask`), evaluation never returns `:ask`. An ask rule
becomes a deny with `reason: :no_approver`, and the pin and an `:ask` default
become denies with their own reasons. With nothing matching, the default is
`:ask` (a deny with `reason: :no_rule` when there is no approver) or `:deny`.

### Asymmetric matching

Deny and ask rules match **loosely**: both segments are lower-cased, with
`-`, `.` and `_` equivalent, and a regex is tried against the name and that
folded form. Allow rules match **exactly**.

```elixir
deny: ["*/delete_repo"]   # also denies Delete_Repo, delete-repo, DELETE.REPO
allow: ["*/delete_repo"]  # does not allow Delete_Repo
```

### Failing predicates

A function, argument or annotation predicate that raises, exits, throws or
returns a non-boolean counts as **matching** in deny and ask lists
(`reason: :predicate_failed`) and **not matching** in the allow list.
Failures never widen access.

### Annotations

Tool annotations are server-supplied hints. For an untrusted server, every
annotation rule sees the conservative value whatever the hints say: not
read-only, destructive, open-world, non-idempotent. Trust a server's hints
with the policy's `trusted:` (a server id list, `true`, or a map) or the
client's `trusted: true`. A trusted server's hints are used, with the spec
defaults when absent.

### Argument predicates and paths

`ConduitMcp.Client.Policy.Paths` canonicalizes path arguments (NFC, no NUL,
relative paths joined to the root, `.`/`..` resolved lexically; `~` is not
expanded) before comparing them with a root:

```elixir
alias ConduitMcp.Client.Policy.Paths

root = "/srv/sandbox"

policy: [
  deny: [{:args, Paths.escapes("path", root)}],
  allow: [{:all, ["fs/write_file", {:args, Paths.inside("path", root)}]}]
]
```

The selector is a key (`"path"`) or a key/index list (`["files", 0,
"path"]`); list values are checked element by element.

- `Paths.inside/3` is for allow rules. It matches only when every path
  canonicalizes and lies within the root. A missing argument is no match.
- `Paths.escapes/3` is for deny and ask rules. It matches when any path fails
  to canonicalize (including a non-string value) or lies outside the root.
  A missing argument is no match.
- `resolve: fun` lets you resolve symlinks yourself. Nothing in `Paths`
  touches the file system on its own.

Argument rules are defence in depth, not a sandbox: the server is the
enforcement point.

### Resources and prompts

With `:resources` or `:prompts` in `:scope`, these rules apply to
`read_resource/3` and `get_prompt/4`:

```elixir
policy: [
  scope: [:tools, :resources],
  deny: ["resource:*/file:///etc/*"],
  allow: ["*/*", "resource:docs/*"]
]
```

`"resource:server/uri"` globs the URI (`*` may span `/`);
`{:resource, server, ~r/.../}`, `"prompt:server/name"` and
`{:prompt, server, ~r/.../}` work the same way. Tool rules never match
resources or prompts, and the reverse. Reads and gets have no approver, so an
ask rule denies them.

### Updating a policy at runtime

```elixir
:ok = ConduitMcp.Client.Policy.update(:github_policy, deny: ["*/delete_*"], allow: ["github/*"])

{ConduitMcp.Client, name: :github, transport: transport, policy: {:named, :github_policy}}
```

`update/2` stores the compiled policy in `:persistent_term`; every update
triggers a scan of every process's heap, so update rarely, not per call.
`get/1` and `delete/1` read and remove it.

## Fingerprints and rug pulls

A server can change a tool's description or schema after you approved it.
`ConduitMcp.Client.Fingerprint` is the SHA-256 of the canonical JSON of the
tool's `name`, `title`, `description`, `inputSchema`, `outputSchema`,
`annotations`, `execution` and `_meta`. Reordering keys gives the same
fingerprint; any change in a value, including whitespace in the description,
gives a new one.

- `pin_tools: true` (default): a tool whose current fingerprint differs from
  its approved one is decided by the pin, right after deny rules: `:ask` (or
  `:deny` without an approver), `source: :pin`, `reason: :definition_changed`.
- `allow_new_tools: false` (default): a tool with no approved fingerprint is
  allowed only by **exact** allow rules (`"fs/read"`, both segments literal,
  or an `:all` containing one). Globs, bare names, regexes, functions and
  predicates do not allow it. Deny and ask rules apply as usual.

Where approved fingerprints come from is the client's
`:approved_fingerprints` option:

- `:first_listing` (default) records the fingerprints of the first full tool
  list a client with a policy reads (with `list_all_tools/2`,
  `cached_tools/2`, or its first call). A later change asks again, and a tool
  first listed later is new. The baseline is recorded again after a restart.
- A map of tool name to fingerprint pins exactly those.

A live grant for the call's principal adds the granted fingerprint. A
refreshed list that changes a known tool emits
`[:conduit_mcp, :client, :tool, :definition_changed]`.

## Asking for approval

```elixir
defmodule MyApp.Approvals do
  def ask(%ConduitMcp.Client.ToolCall{} = call, ctx) do
    case MyApp.UI.confirm(ctx.principal, call.server_id, call.name, call.args, call.args_digest) do
      :once -> {:allow, :once}
      :always -> {:allow, :always}
      :no -> {:deny, :user_declined}
      :stop -> {:deny, :user_stopped, :halt}
    end
  end
end
```

`:on_ask` is `fun.(%ToolCall{}, ctx)` or `{Module, :function}`. It runs in a
task under `:ask_timeout` (default 60 s), with the exact arguments that will
be sent and their `args_digest`. The approver cannot change the arguments;
rewriting belongs in pre-hooks, which run before policy.

| Answer | Result |
|---|---|
| `{:allow, :once}` | Send this call |
| `{:allow, :always}` | Send it, and record a grant for the call's `:principal`, this tool and its current fingerprint, for `:grant_ttl` (default 24 h) |
| `{:deny, reason}` | `{:error, %Error{kind: :denied, reason: :ask_denied, data: reason}}` |
| `{:deny, reason, :halt}` | The same with `reason: :ask_halt`, telling an agent loop to stop |
| anything else, a raise, an exit, a timeout | A deny with `reason: {:ask_failed, :bad_return \| :raise \| :exit \| :timeout}` |

### Grants

A grant is keyed `{principal, server_id, tool_name, fingerprint}`. One
user's grant never applies to another; without principals, grants are per
client. A server that changes the tool's definition gets asked about again.
A grant only settles an `:ask`: it never overrides a deny rule.

```elixir
{:ok, grants} = ConduitMcp.Client.Grants.list(:github)
:ok = ConduitMcp.Client.Grants.revoke(:github, user_id)
:ok = ConduitMcp.Client.Grants.clear(:github)
```

Grants live in the client's governance table (`:protected` ETS, written by
one process under the client's supervisor) and are lost when the client
restarts, which only means asking again.

## Hooks

```elixir
hooks: [
  pre_tool_call: [
    {:all, &MyApp.Audit.before/2, id: :audit},
    {"fs/write_*", {MyApp.Paths, :normalize}, id: :normalize}
  ],
  post_tool_call: [{"fs/*", &MyApp.Redact.result/3, id: :redact}],
  tool_call_failed: [{:all, &MyApp.Alert.failed/3, id: :alert, on_error: :ignore}]
]
```

| Event | Called as | Returns |
|---|---|---|
| `:pre_tool_call` | `fun.(%ToolCall{}, ctx)` | `:cont`, `{:cont, %ToolCall{}}`, `{:deny, reason}` or `{:halt, %ToolResult{}}` |
| `:post_tool_call` | `fun.(%ToolCall{}, %ToolResult{}, ctx)` | `:cont` or `{:cont, %ToolResult{}}` |
| `:tool_call_failed` | `fun.(%ToolCall{}, %Error{}, ctx)` | `:cont` or `{:recover, %ToolResult{}}` |
| `:on_tools_listed` | `fun.([%Tool{}], ctx)` | `:cont` or `{:cont, [%Tool{}]}` |
| `:on_resource_read` | `fun.(uri, ctx)` | `:cont` or `{:deny, reason}` |
| `:on_prompt_get` | `fun.(name, args, ctx)` | `:cont`, `{:cont, args}` or `{:deny, reason}` |

- A pre-hook may rewrite only the call's `args` and `meta`; the digest is
  recomputed and policy sees the result. Changing `server_id`, `name` or
  `call_id` is a bad return. `{:deny, reason}` fails the call with
  `kind: :denied, reason: {:hook_denied, hook_id}, data: reason`.
  `{:halt, result}` answers with a synthetic result and sends nothing (policy
  does not run; post-hooks do).
- Post-hooks also see `is_error: true` results.
- Failure hooks run instead of post-hooks when the call ends in an error.
  `{:recover, result}` turns the error into that result and ends the chain.
- `:on_tools_listed` hooks may drop or annotate the tools their matcher
  selects; a returned tool must be one of those given. This shapes what the
  host and its model see; it is not authorization (use `:tools` or a policy).
- `:on_resource_read` and `:on_prompt_get` gate `read_resource/3` and
  `get_prompt/4` the way pre-hooks gate calls.

**No hook can allow anything.** There is no allow return. Policy is the only
allow authority, and it runs after the pre-hooks, on the final arguments.

`ctx` has `:client`, `:server_id`, `:era`, `:assigns` and `:principal`.

### Matchers, options and order

A hook spec is `{matcher, fun}` or `{matcher, fun, opts}`; `fun` has the
event's arity or is `{Module, :function}`. Matchers:

- `:all` (or `:any`, `"*"`) - every call;
- `"server/tool"` - `*` globs within one segment; a bare `"tool"` means any
  server (resource hooks glob the URI, prompt hooks the name);
- `{server, ~r/.../}` - the regex against the tool name (URI, prompt name).

Matchers compare loosely, like deny rules, so a redaction hook on
`"fs/read_file"` also covers `Read-File`.

Options: `:id` (an atom or string, unique; default `{event, index}`),
`:timeout` (default the client's `:hook_timeout`, 5 000 ms) and `:on_error`
(`:fail` by default, or `:ignore`, for post-hooks and failure hooks only).

Hooks run one at a time, each `{:cont, value}` feeding the next, in onion
order: **global** (`:all`), then **server** (`"server/*"`), then **tool**
(any other matcher), in declaration order within a level. Post-hooks and
failure hooks run in the reverse order.

### Failures are closed

Every hook runs in a task under the client's `Task.Supervisor` with its
deadline. A hook that raises, throws, exits (even `exit(:kill)`), times out
or returns outside its contract:

| Hook | Outcome |
|---|---|
| pre-hook, resource or prompt hook | The call fails with `kind: :hook, reason: {:hook_failed, hook_id, :raise \| :exit \| :timeout \| :bad_return}`. No request is sent |
| post-hook | The result is **withheld**: the caller gets `{:ok, %ToolResult{is_error: true}}` with a fixed text and the raw result is dropped unlogged. With `on_error: :ignore` the hook is skipped instead |
| failure hook | The original error is returned unchanged |
| `:on_tools_listed` | The listing fails with a `:hook` error, not an empty list |

What a failing hook raised is never logged or put in telemetry: it may quote
the arguments or result.

## Schema validation

```elixir
# mix.exs
{:jsv, "~> 0.26"}
```

```elixir
validate: [arguments: true, structured_content: true]
```

- `arguments: true` validates the final arguments (after pre-hooks) against
  the tool's `inputSchema` before policy runs. An invalid call is never sent:
  `kind: :protocol, reason: :invalid_arguments`, with the validator's errors
  in `data`.
- `structured_content: true` validates a successful result's
  `structuredContent` against the tool's `outputSchema`, when it has one:
  `kind: :protocol, reason: :invalid_structured_content`.

The default validator is `ConduitMcp.Client.SchemaValidator.JSV`, which needs
the optional `:jsv` dependency. Asking for validation without it raises
`ConduitMcp.OptionalDependencyError` when the client's options are validated.
Set another with `validate: [validator: MyValidator]`.

Server schemas are untrusted, so they are bounded before any validator sees
them. A schema is refused when it is not an object or boolean, nests more
than 64 levels (32 of subschemas), has more than 1 000 subschemas, encodes to
more than 256 KiB, or has a `$ref`/`$dynamicRef` that is not a local `#...`
pointer. A tool with a refused schema is left out of tool lists while that
validation is on, and calling it fails with `kind: :protocol, reason:
{:unsafe_schema, :input | :output, reason}`. JSV runs `pattern` under a
backtracking budget, so a catastrophic regex fails the value instead of
hanging the caller.

## Shaping results for a model

`shape: :llm` (the default in `ConduitMcp.Client.Adapters.execute_tool_calls/4`)
rewrites a `ToolResult` for an LLM's context:

- `provenance: %{server_id:, truncated:, flags:}` says where it came from and
  what changed;
- text (including embedded resource text, link names and `structuredContent`
  strings) loses bidi controls, zero-width and Unicode tag characters,
  flagged `:bidi`, `:zero_width`, `:tag_chars`;
- images other than JPEG, PNG, GIF and WebP (notably SVG), audio other than
  WAV, MP3, Ogg, WebM and FLAC, and non-image blobs become a text placeholder
  (`:media_dropped`); unknown block types too (`:unsupported_content`);
- `resource_link` URIs are kept as text and never fetched; nothing else is
  fetched either;
- `_meta` and unknown keys are dropped;
- the whole result is capped at the client's `:max_result_bytes_for_llm`
  (default 100 KiB). The crossing block is cut on a character boundary, later
  blocks and an over-size `structuredContent` are dropped, and a final text
  block says so.

```elixir
{:ok, %ConduitMcp.Client.ToolResult{provenance: %{server_id: "fs", truncated: false, flags: []}}} =
  ConduitMcp.Client.call_tool(:fs, "read_file", %{"path" => "/srv/a.txt"}, shape: :llm)
```

Server `instructions` are not part of a tool result. Use
`ConduitMcp.Client.instructions_for_llm/1`, which returns `{:ok, nil}` unless
the client has `include_instructions: true`; then they are capped at 4 KiB,
stripped of invisible characters and, unless the client is `trusted: true`,
prefixed with a line naming the server.

## Taint

A model that read one server's output may be steered by it into calling
another server's tool. The library cannot see the model's context, so the
host passes `taint:` with the server ids whose output entered the current
turn, and policy rules react:

```elixir
policy: [
  ask: [{:all, [{:annotation, :open_world, true}, ConduitMcp.Client.Policy.tainted(ignore: ["docs"])]}],
  deny: [{:all, ["mail/send", ConduitMcp.Client.Policy.tainted()]}],
  allow: ["*/*"]
]

ConduitMcp.Client.Hub.call_tool(MyApp.Hub, "mail__send", args, taint: ["web"])
```

`Policy.tainted/1` matches when the taint set holds a server other than the
called tool's own (minus `:ignore`). A call without `:taint` is never
tainted. Use it in deny and ask lists; in an allow list it would only widen
access.

## Recipes

### Audit logging

A post-hook that never blocks the result. `on_error: :ignore` skips the hook
if the audit sink fails, instead of withholding the result.

```elixir
defmodule MyApp.Audit do
  require Logger

  def result(%ConduitMcp.Client.ToolCall{} = call, %ConduitMcp.Client.ToolResult{} = result, ctx) do
    Logger.info("mcp call",
      principal: inspect(ctx.principal),
      server: call.server_id,
      tool: call.name,
      args_digest: call.args_digest,
      is_error: result.is_error
    )

    :cont
  end
end

hooks: [post_tool_call: [{:all, &MyApp.Audit.result/3, id: :audit, on_error: :ignore}]]
```

Log the `args_digest`, not the arguments: they can hold user data.

### Secret redaction

A post-hook that rewrites the result. Leave `on_error` at `:fail`: if the
redactor crashes, the result is withheld rather than passed through
unredacted.

```elixir
defmodule MyApp.Redact do
  @token ~r/\b(ghp|gho|ghs)_[A-Za-z0-9]{36}\b/

  def result(_call, %ConduitMcp.Client.ToolResult{content: content} = result, _ctx) do
    {:cont, %{result | content: Enum.map(content, &redact/1)}}
  end

  defp redact(%{"type" => "text", "text" => text} = block),
    do: %{block | "text" => Regex.replace(@token, text, "[redacted]")}

  defp redact(block), do: block
end

hooks: [post_tool_call: [{"github/*", &MyApp.Redact.result/3, id: :redact}]]
```

### Path sandbox

Deny any filesystem call whose `path` leaves the sandbox; allow writes only
inside it.

```elixir
alias ConduitMcp.Client.Policy.Paths

root = "/srv/sandbox"

policy: [
  deny: [{:rule, :sandbox, {:all, ["fs/*", {:args, Paths.escapes("path", root)}]}}],
  ask: ["fs/write_*"],
  allow: [{:all, ["fs/read_file", {:args, Paths.inside("path", root)}]}]
]
```

### Cost guard

A pre-hook that halts a call once a budget is spent. `{:halt, result}`
answers with a synthetic result and sends nothing.

```elixir
defmodule MyApp.CostGuard do
  def check(%ConduitMcp.Client.ToolCall{} = _call, ctx) do
    if MyApp.Budget.remaining(ctx.principal) > 0 do
      :cont
    else
      {:halt,
       %ConduitMcp.Client.ToolResult{
         is_error: true,
         content: [%{"type" => "text", "text" => "Tool budget exhausted for today."}]
       }}
    end
  end
end

hooks: [pre_tool_call: [{"search/*", &MyApp.CostGuard.check/2, id: :cost_guard}]]
```

Return `{:deny, :budget_exhausted}` instead to fail the call with
`kind: :denied`.

## Telemetry

`[:conduit_mcp, :client, :policy, :decision]` is emitted per governed tool
call, resource read or prompt get, after any approval. Its metadata adds:

| Key | Value |
|---|---|
| `:target` | `:tool`, `:resource` or `:prompt` |
| `:tool_name` | Sanitized; tools only; never a metric tag |
| `:decision` | `:allow`, `:ask` or `:deny` |
| `:source` | `:deny`, `:ask`, `:allow`, `:pin` or `:default` |
| `:reason` | A `ConduitMcp.Client.Policy.Decision` reason (`:deny_rule`, `:ask_rule`, `:allow_rule`, `:predicate_failed`, `:no_approver`, `:definition_changed`, `:no_rule`, `:out_of_scope`), or `:no_policy` when a `{:named, name}` policy is not stored |
| `:rule_id` | The deciding rule's id; `nil` for the pin and the default |
| `:approval` | `:grant`, `:once`, `:always`, `:denied`, `:halted`, `:failed`, or `nil` when the decision was not `:ask` |
| `:principal` | The call's `:principal`, only when given |

`[:conduit_mcp, :client, :hook, :stop]` (`:status` is `:cont`, `:rewrite`,
`:deny`, `:halt` or `:recover`) and `[:conduit_mcp, :client, :hook,
:exception]` (`:reason` is `:raise`, `:exit`, `:timeout` or `:bad_return`)
are emitted per hook run, with `:hook_id`, `:kind` (the hook event) and, for
tool hooks, `:tool_name`. Neither event carries arguments or results.

# Client LLM Adapters

`ConduitMcp.Client.Adapters` connects MCP tools to an LLM's tool calling.
It lists a hub's (or one client's) tools in a provider's format, runs the
tool calls the model made through the governed pipeline, and answers them in
the same format. The library makes no LLM HTTP calls: you send the request
with your own HTTP client.

| Provider | `provider` | Pure module |
|---|---|---|
| Anthropic Messages API | `:anthropic` | `ConduitMcp.Client.Adapters.Anthropic` |
| OpenAI Chat Completions | `:openai`, `api: :chat` | `ConduitMcp.Client.Adapters.OpenAI` |
| OpenAI Responses | `:openai`, `api: :responses` | `ConduitMcp.Client.Adapters.OpenAI` |
| Gemini `generateContent` (experimental) | `:gemini` | `ConduitMcp.Client.Adapters.Gemini` |

Two calls do the work:

```elixir
{:ok, %{tools: tools, toolset: toolset, null_paths: null_paths}} =
  ConduitMcp.Client.Adapters.tools(MyApp.Hub, :anthropic)

{:ok, results} =
  ConduitMcp.Client.Adapters.execute_tool_calls(MyApp.Hub, :anthropic, response,
    toolset: toolset,
    principal: user_id
  )
```

## Hub or client

The first argument is a `ConduitMcp.Client.Hub` name or a `ConduitMcp.Client`
name:

- **Hub**: tools are named `server__tool` (see [client_hub.md](client_hub.md)).
  A hub always has a policy.
- **Client**: tools keep their own sanitized names (a `namespace: false`
  toolset). `:prefix` adds a prefix. A client without `:policy`, `:hooks`,
  `:tools` or `:validate` has no policy, so the model's calls are sent as
  asked. **Configure a policy on any client you hand to a model.**

A name registered as both is treated as the hub.

```elixir
{ConduitMcp.Client,
 name: :github,
 server_id: "github",
 transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "https://mcp.example.com/mcp"},
 policy: [allow: ["github/get_*", "github/list_*"], ask: ["github/*"]],
 on_ask: &MyApp.Approvals.ask/2}

{:ok, listing} = ConduitMcp.Client.Adapters.tools(:github, :anthropic)
# names like "get_issue", "list_pull_requests"
```

## Anthropic Messages

```elixir
defmodule MyApp.Agent.Anthropic do
  alias ConduitMcp.Client.Adapters

  @url "https://api.anthropic.com/v1/messages"

  def run(source, user_id, prompt) do
    {:ok, listing} = Adapters.tools(source, :anthropic, cache_control: :last, principal: user_id)
    loop(source, user_id, listing, [%{"role" => "user", "content" => prompt}])
  end

  defp loop(source, user_id, listing, messages) do
    response =
      Req.post!(@url,
        headers: [
          {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
          {"anthropic-version", "2023-06-01"}
        ],
        json: %{
          "model" => model(),
          "max_tokens" => 4096,
          "tools" => listing.tools,
          "messages" => messages
        }
      ).body

    messages = messages ++ [%{"role" => "assistant", "content" => response["content"]}]

    if response["stop_reason"] == "tool_use" do
      case Adapters.execute_tool_calls(source, :anthropic, response,
             toolset: listing.toolset,
             principal: user_id
           ) do
        {:ok, results} ->
          loop(source, user_id, listing, messages ++ [%{"role" => "user", "content" => results}])

        {:halt, _results} ->
          {:halted, messages}
      end
    else
      {:done, messages}
    end
  end

  defp model, do: Application.fetch_env!(:my_app, :anthropic_model)
end
```

`results` are `tool_result` blocks, one per `tool_use` in the model's order;
they must come first in the next user turn. `cache_control: :last` marks the
last tool so the whole tool list is cached as a prompt prefix.

**Never force tool use on current Claude models.** The adapter never builds a
`tool_choice` of type `any` or `tool`; current Claude models reject forced
tool use with HTTP 400. Leave `tool_choice` unset, or use `auto` or `none`.

## OpenAI Chat Completions

```elixir
defmodule MyApp.Agent.OpenAIChat do
  alias ConduitMcp.Client.Adapters

  @url "https://api.openai.com/v1/chat/completions"

  def run(source, user_id, prompt) do
    {:ok, listing} = Adapters.tools(source, :openai, api: :chat, principal: user_id)
    loop(source, user_id, listing, [%{"role" => "user", "content" => prompt}])
  end

  defp loop(source, user_id, listing, messages) do
    response =
      Req.post!(@url,
        auth: {:bearer, System.fetch_env!("OPENAI_API_KEY")},
        json: %{"model" => model(), "tools" => listing.tools, "messages" => messages}
      ).body

    message = hd(response["choices"])["message"]
    messages = messages ++ [message]

    case Adapters.execute_tool_calls(source, :openai, response,
           api: :chat,
           toolset: listing.toolset,
           null_paths: listing.null_paths,
           principal: user_id
         ) do
      {:ok, []} -> {:done, messages}
      {:ok, tool_messages} -> loop(source, user_id, listing, messages ++ tool_messages)
      {:halt, _tool_messages} -> {:halted, messages}
    end
  end

  defp model, do: Application.fetch_env!(:my_app, :openai_model)
end
```

Each result is a `%{"role" => "tool", "tool_call_id" => id, "content" => text}`
message. Pass `null_paths:` from the listing: strict mode made optional
properties nullable, and those `null`s are removed before the call is sent.

## OpenAI Responses

```elixir
defmodule MyApp.Agent.OpenAIResponses do
  alias ConduitMcp.Client.Adapters

  @url "https://api.openai.com/v1/responses"

  def run(source, user_id, prompt) do
    {:ok, listing} = Adapters.tools(source, :openai, api: :responses, principal: user_id)
    loop(source, user_id, listing, [%{"role" => "user", "content" => prompt}])
  end

  defp loop(source, user_id, listing, input) do
    response =
      Req.post!(@url,
        auth: {:bearer, System.fetch_env!("OPENAI_API_KEY")},
        json: %{"model" => model(), "tools" => listing.tools, "input" => input}
      ).body

    input = input ++ response["output"]

    case Adapters.execute_tool_calls(source, :openai, response,
           api: :responses,
           toolset: listing.toolset,
           null_paths: listing.null_paths,
           principal: user_id
         ) do
      {:ok, []} -> {:done, input}
      {:ok, outputs} -> loop(source, user_id, listing, input ++ outputs)
      {:halt, _outputs} -> {:halted, input}
    end
  end

  defp model, do: Application.fetch_env!(:my_app, :openai_model)
end
```

Each result is a `%{"type" => "function_call_output", "call_id" => id,
"output" => output}` item, where `output` is a string, or a list of
`input_text`/`input_image` items when the result carries an image.

## Gemini generateContent

> #### Experimental {: .warning}
>
> The Gemini adapter's shapes come from the Gemini API reference, not from
> end-to-end runs against the API, and may change in a minor release.

```elixir
defmodule MyApp.Agent.Gemini do
  alias ConduitMcp.Client.Adapters

  def run(source, user_id, prompt) do
    {:ok, listing} = Adapters.tools(source, :gemini, principal: user_id)
    loop(source, user_id, listing, [%{"role" => "user", "parts" => [%{"text" => prompt}]}])
  end

  defp loop(source, user_id, listing, contents) do
    url = "https://generativelanguage.googleapis.com/v1beta/models/#{model()}:generateContent"

    response =
      Req.post!(url,
        headers: [{"x-goog-api-key", System.fetch_env!("GEMINI_API_KEY")}],
        json: %{
          "contents" => contents,
          "tools" => [%{"functionDeclarations" => listing.tools}]
        }
      ).body

    contents = contents ++ [hd(response["candidates"])["content"]]

    case Adapters.execute_tool_calls(source, :gemini, response,
           toolset: listing.toolset,
           principal: user_id
         ) do
      {:ok, []} -> {:done, contents}
      {:ok, parts} -> loop(source, user_id, listing, contents ++ [%{"role" => "user", "parts" => parts}])
      {:halt, _parts} -> {:halted, contents}
    end
  end

  defp model, do: Application.fetch_env!(:my_app, :gemini_model)
end
```

`Adapters.tools(_, :gemini)` returns the `functionDeclarations`; wrap them in
`%{"functionDeclarations" => tools}`. Each result is a `functionResponse`
part with the exposed name, the call's `id` when Gemini sent one, and the
result under `response.output` (the `structuredContent` object when present,
else the content as text) or a failure under `response.error`.

## Results

`execute_tool_calls/4` answers **every** call in the model's order, each in
the provider's shape and keyed by the call's id:

| The call | Its answer |
|---|---|
| Names a tool not in the toolset, or has non-object arguments | The provider's error answer. **Nothing is sent** to any server |
| Completes | Its `ToolResult` (including `is_error` results), shaped for a model (`shape: :llm`) unless `shape: nil` |
| Fails (denied, timed out, server unavailable, ...) | An error answer with the `ConduitMcp.Client.Error` message |

Errors are marked per provider: Anthropic sets `"is_error": true`, OpenAI
prefixes the text with `"Error: "` (it has no error flag; change it with
`:error_prefix`), and Gemini puts the text under `response.error`.

When an approver answered `{:deny, reason, :halt}` for any call, the return
is `{:halt, results}`. You may answer the model, but stop the agent loop.
Otherwise it is `{:ok, results}`.

Options:

| Option | Default | Meaning |
|---|---|---|
| `:toolset` | built with `toolset/2` | The toolset the model was offered (from `tools/3`). Calls resolve against it only |
| `:api` | required for `:openai` | `:chat` or `:responses` |
| `:null_paths` | `%{}` | OpenAI strict-mode null paths (from `tools/3`) |
| `:max_concurrency` | `System.schedulers_online/0` | Calls run at once |
| `:call_timeout` | 300 000 | Milliseconds one call may take in all, approval and hooks included; over it the call is killed and answered with a `:timeout` error |
| `:structured` | provider default | How `structuredContent` is used: `:auto`, `:prefer`, `:append` or `:ignore` |
| `:shape` | `:llm` | `nil` to skip shaping |
| any pipeline option | | `:principal`, `:assigns`, `:taint`, `:timeout`, `:meta`, progress options. `:task` is not supported |

### Taint across turns

The calls of one turn run concurrently and see the same `:taint`. Once their
results are in the model's context, add their servers to the next turn's
`taint:` so `ConduitMcp.Client.Policy.tainted/1` rules can react:

```elixir
taint = MapSet.new()

{:ok, results} =
  ConduitMcp.Client.Adapters.execute_tool_calls(MyApp.Hub, :anthropic, response,
    toolset: listing.toolset,
    taint: MapSet.to_list(taint)
  )

{calls, _rejected} = ConduitMcp.Client.Adapters.Anthropic.tool_calls(response, listing.toolset)
taint = Enum.into(calls, taint, & &1.server_id)
```

## Tool definitions and provider limits

| | Anthropic | OpenAI | Gemini |
|---|---|---|---|
| Shape | `%{"name", "description", "input_schema"}` | Chat: `%{"type" => "function", "function" => %{"name", "description", "parameters", "strict"}}`; Responses: `%{"type" => "function", "name", "description", "parameters", "strict"}` | `%{"name", "description", "parametersJsonSchema"}` (the `inputSchema` unchanged) |
| Names | exposed names, `^[A-Za-z0-9_-]{1,64}$` (Anthropic allows 128) | same (OpenAI's limit is 64) | same (Gemini allows `a-z A-Z 0-9 _ : . -`, 128) |
| Descriptions | invisible characters removed, capped at 4 KiB | same | same; a tool without one gets `""` |

All three emit only tools in the toolset, so tools hidden by a filter, left
out after a collision or belonging to a down server never reach the model.
Every adapter keeps the toolset's order, which keeps the tool list stable
between turns for prompt caching.

### OpenAI strict mode

`"strict"` is always sent: when it is omitted, the Responses API tries strict
mode and silently falls back, so the same list would behave differently per
API.

| `strict:` | A tool whose schema converts | A tool whose schema cannot |
|---|---|---|
| `:auto` (default) | `"strict": true`, converted schema | `"strict": false`, original schema, listed in the report's `fallbacks`; `Adapters.tools/3` emits `[:conduit_mcp, :client, :adapter, :strict_fallback]` |
| `true` | `"strict": true` | left out, listed in `excluded` (OpenAI would reject the whole request) |
| `false` | `"strict": false`, original schema | `"strict": false`, original schema |

The conversion (`ConduitMcp.Client.Adapters.OpenAI.strict_schema/1`):

- The root must be `"type": "object"` and must not be `anyOf`.
- Every object gets `"additionalProperties": false` and lists every property
  in `required`. An optional property becomes nullable (`"type": [t,
  "null"]`, `null` in its `enum`, or `anyOf` with `{"type": "null"}`), and its
  path goes into `null_paths`, so the `null` the model must now send is
  stripped before the call.
- Kept: `type`, `properties`, `required`, `additionalProperties: false`,
  `items`, `enum`, `const`, `anyOf`, local `$ref` with root
  `$defs`/`definitions`, `description`, `title`, `pattern`, `minLength`,
  `maxLength`, `multipleOf`, `minimum`, `maximum`, `exclusiveMinimum`,
  `exclusiveMaximum`, `minItems`, `maxItems`, and `format` when it is one of
  `date-time time date duration email hostname ipv4 ipv6 uuid`.
- Unsupported (conversion fails): `allOf`, `not`, `oneOf`, `if`/`then`/`else`,
  `dependentRequired`, `dependentSchemas`, `dependencies`,
  `patternProperties`, `unevaluatedProperties`, `unevaluatedItems`,
  `propertyNames`, `prefixItems`, `contains`, `minContains`, `maxContains`,
  `$dynamicRef`, `$recursiveRef`; open maps; arrays without `items`; untyped
  nodes; non-local or unresolvable `$ref`; recursive `$ref` with optional
  properties.
- Dropped (they only narrow or annotate; the server still validates):
  `default`, `examples`, `uniqueItems`, `minProperties`, `contentMediaType`,
  vendor keywords, other `format`s.
- Limits: 5 000 properties, 10 levels of object nesting, 120 000 characters
  of names and enum values, 1 000 enum values, 15 000 characters for a string
  enum over 250 values.

```elixir
{:ok, strict, null_paths} =
  ConduitMcp.Client.Adapters.OpenAI.strict_schema(%{
    "type" => "object",
    "properties" => %{"q" => %{"type" => "string"}, "limit" => %{"type" => "integer"}},
    "required" => ["q"]
  })

strict["properties"]["limit"]  #=> %{"type" => ["integer", "null"]}
null_paths                     #=> [["limit"]]
```

## Media mapping

What each provider receives for each kind of MCP content in a tool result.
With the default `shape: :llm`, images other than JPEG, PNG, GIF and WebP
(notably SVG), audio other than WAV, MP3, Ogg, WebM and FLAC, and non-image
blobs have already become text placeholders before the adapter runs.

| MCP content | Anthropic | OpenAI Chat | OpenAI Responses | Gemini |
|---|---|---|---|---|
| `text` | `text` block | text | a plain string (`input_text` items when the result also has an inline image) | text in `response.output` |
| `image` (JPEG/PNG/GIF/WebP) | `image` block, base64 source | placeholder `"[image: image/png, 1024 bytes]"` | `input_image`, data URI | placeholder |
| other `image`, `audio` | text placeholder | placeholder | `input_text` placeholder | placeholder |
| `resource_link` | text `"[resource] name <uri> (mime)"` | same text | same text | same text |
| embedded text `resource` | text with a `[resource: uri]` header | same text | same text | same text |
| embedded blob `resource` | `image` block if an accepted image type, else a placeholder | placeholder | `input_image` if an accepted image type, else a placeholder | placeholder |
| `structuredContent` | JSON text, by default only when `content` is empty | same | same | the object itself as `response.output` (default `structured: :prefer`) |

`resource_link` URIs are never fetched.

## Using the pure modules

The provider modules are pure functions over string-keyed maps. Use them
directly when you drive the pipeline yourself:

```elixir
alias ConduitMcp.Client.Adapters.Anthropic

{:ok, toolset} = ConduitMcp.Client.Hub.list_tools(MyApp.Hub)
tools = Anthropic.tools(toolset, cache_control: :last)

{calls, rejected} = Anthropic.tool_calls(response, toolset)

results =
  Enum.map(calls, fn call ->
    {:ok, tool} = ConduitMcp.Client.ToolSet.exposed_name(toolset, call.server_id, call.name)
    outcome =
      case ConduitMcp.Client.Hub.call_tool(MyApp.Hub, tool, call.args, toolset: toolset, shape: :llm) do
        {:ok, result} -> result
        {:error, error} -> error
      end

    Anthropic.tool_result(call.call_id, outcome)
  end)

next_turn = %{"role" => "user", "content" => rejected ++ results}
```

`rejected` holds the error answers for calls to unknown names or with
non-object arguments. `OpenAI.tool_calls/3`, `OpenAI.tool_output/3`,
`Gemini.function_calls/2` and `Gemini.function_response/3` work the same
way.

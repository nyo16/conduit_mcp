# Multi Round-Trip Requests (MRTR)

In MCP `2026-07-28` a server no longer sends requests to the client.
To ask for input (an elicitation, or the deprecated sampling and roots), a
`tools/call`, `resources/read` or `prompts/get` answers with an
`input_required` result. The client gathers the answers and retries the same
request with them.

```
client                                   server
  │ tools/call deploy                       │
  │────────────────────────────────────────>│ callback → {:input_required, reqs, state}
  │ resultType: input_required              │
  │ inputRequests, requestState             │
  │<────────────────────────────────────────│
  │ tools/call deploy                       │
  │ + inputResponses, requestState          │
  │────────────────────────────────────────>│ callback sees conn.assigns[:mcp_input]
  │ resultType: complete                    │
  │<────────────────────────────────────────│
```

The server stays stateless. Whatever the callback needs on the retry travels
inside `requestState`, sealed so the client can neither read nor change it.

## Configure the keyring

Sealing needs `:mrtr_keys`, a list of `{kid, key}` tuples. Load the key from
a secret at runtime:

```elixir
# config/runtime.exs
config :conduit_mcp,
  mrtr_keys: [{"2026-10", Base.decode64!(System.fetch_env!("MRTR_KEY"))}]
```

```elixir
# generate a key once
:crypto.strong_rand_bytes(32) |> Base.encode64()
```

- `kid` is a non-empty binary without `"."`. `key` is exactly 32 bytes.
- When `:mrtr_keys` is set, it is validated at application boot. A
  malformed entry or a duplicate `kid` raises an `ArgumentError` that names
  the config key, never the key bytes.
- **Rotation.** New tokens are always sealed with the **first** key; a token
  is opened with the key its `kid` names. To rotate, put the new key first
  and keep the old one second until in-flight tokens have expired (5
  minutes at most), then remove it. Rotate well before 2³² seals per key.

  ```elixir
  config :conduit_mcp, mrtr_keys: [{"2026-11", new_key}, {"2026-10", old_key}]
  ```

- **Without `:mrtr_keys`**, a callback that returns `{:input_required, ...}`
  gets `-32603`, and the server logs an error naming `:mrtr_keys`. A retry
  that carries a `requestState` gets `-32602 "Invalid requestState"`.

## Asking for input

Return `{:input_required, input_requests, state}` from the callback:

- `input_requests` maps keys you choose to input requests built with
  `ConduitMcp.MRTR`.
- `state` is any JSON-encodable term you want back on the retry.

On the retry, `conn.assigns[:mcp_input]` is `%{state: state, responses:
input_responses}`. On the first round it is absent (`nil`).

### Manual mode

```elixir
@approval %{
  "type" => "object",
  "properties" => %{"confirm" => %{"type" => "boolean"}},
  "required" => ["confirm"]
}

def handle_call_tool(conn, "deploy", %{"target" => target}) do
  case conn.assigns[:mcp_input] do
    nil ->
      {:input_required,
       %{"approval" => ConduitMcp.MRTR.elicit("Deploy to #{target}?", @approval)},
       %{target: target}}

    %{responses: %{"approval" => %{"action" => "accept"}}} ->
      {:ok, %{"content" => [%{"type" => "text", "text" => "Deployed #{target}"}]}}

    _declined ->
      {:ok, %{"content" => [%{"type" => "text", "text" => "Cancelled"}]}}
  end
end
```

`handle_read_resource/2` and `handle_get_prompt/3` can return the same
tuple.

### DSL mode

`handle`, `read` and `get` handlers return the tuple as it is:

```elixir
tool "deploy", "Deploy a service" do
  param :target, :string, "Target", required: true

  handle fn conn, %{"target" => target} ->
    case conn.assigns[:mcp_input] do
      nil ->
        {:input_required,
         %{"approval" => ConduitMcp.MRTR.elicit("Deploy to #{target}?", @approval)},
         %{step: :awaiting_approval}}

      %{responses: %{"approval" => %{"action" => "accept"}}} ->
        text("Deployed #{target}")

      _declined ->
        text("Cancelled")
    end
  end
end

prompt "summarize", "Summarize a document" do
  get fn conn, _args ->
    case conn.assigns[:mcp_input] do
      nil ->
        {:input_required, %{"doc" => ConduitMcp.MRTR.elicit("Which document?", @document)}, nil}

      %{responses: %{"doc" => %{"action" => "accept", "content" => %{"name" => name}}}} ->
        [user("Summarize #{name}")]

      _declined ->
        [user("Summarize the latest document")]
    end
  end
end
```

### Endpoint mode

`execute/2` returns the tuple, and `ConduitMcp.Endpoint` passes it through:

```elixir
defmodule MyApp.Deploy do
  use ConduitMcp.Component, type: :tool, description: "Deploy a service"

  @approval %{"type" => "object", "properties" => %{"confirm" => %{"type" => "boolean"}}}

  schema do
    field :target, :string, "Target", required: true
  end

  @impl true
  def execute(%{target: target}, conn) do
    case conn.assigns[:mcp_input] do
      nil ->
        {:input_required,
         %{"approval" => ConduitMcp.MRTR.elicit("Deploy to #{target}?", @approval)},
         %{target: target}}

      %{responses: %{"approval" => %{"action" => "accept"}}} ->
        text("Deployed #{target}")

      _declined ->
        text("Cancelled")
    end
  end
end
```

### Several rounds

A callback may return `{:input_required, ...}` again on a retry. Each round
seals a fresh `requestState`. Keys only need to be unique within one round.

## Input request builders

| Builder | Request | Status |
|---|---|---|
| `ConduitMcp.MRTR.elicit(message, requested_schema)` | `elicitation/create` (form mode) | current |
| `ConduitMcp.MRTR.sample(messages, max_tokens: n, ...)` | `sampling/createMessage` | `@deprecated` in `2026-07-28` |
| `ConduitMcp.MRTR.list_roots()` | `roots/list` | `@deprecated` in `2026-07-28` |

`requested_schema` is the restricted JSON Schema the client renders as a
form: a flat `"type" => "object"` with primitive `"properties"`.

`sample/2` requires `:max_tokens` and raises `KeyError` without it. It also
accepts `:system_prompt`, `:model_preferences`, `:temperature`,
`:stop_sequences`, `:tools` and `:tool_choice`.

The values in `input_requests` must be maps with a `"method"` of
`elicitation/create`, `sampling/createMessage` or `roots/list`. Anything
else is logged and answered with `-32603`.

## The retry: `conn.assigns[:mcp_input]`

The library opens `requestState` **before** the callback runs:

```elixir
%{
  state: %{"target" => "prod"},  # your state, as decoded JSON
  responses: %{"approval" => %{"action" => "accept", "content" => %{"confirm" => true}}}
}
```

- `state` comes back as decoded JSON, so atom keys and atom values become
  strings. Tuples, pids, references, functions and non-UTF-8 binaries
  can't be sealed; that is a server bug, answered with `-32603` and an error
  log.
- `responses` is the request's `inputResponses` map, or `%{}` when it is
  absent. A non-object `inputResponses` is `-32602`. **`responses` is client
  input**, so validate it like any other argument.
- `inputResponses` sent without a `requestState` is ignored, and
  `:mcp_input` stays absent.

## Capability gating

Every input request is checked against the capabilities the client declared
in this request's `_meta`. If one is missing, the request is answered with
`-32021` (HTTP 400) instead of an `input_required` result:

```json
{"code": -32021, "message": "Missing required client capability",
 "data": {"requiredCapabilities": {"elicitation": {"form": {}}}}}
```

| Input request | Needs |
|---|---|
| `elicitation/create`, form mode | `elicitation.form`, or an `elicitation` that declares neither mode |
| `elicitation/create` with `"mode" => "url"` | `elicitation.url` |
| `sampling/createMessage` | `sampling`; also `sampling.tools` with `tools`/`toolChoice`, and `sampling.context` when `includeContext` isn't `"none"` |
| `roots/list` | `roots` |

To check before building the requests, call
`ConduitMcp.MRTR.missing_capabilities/2`:

```elixir
ctx = ConduitMcp.Ctx.from_conn(conn)
requests = %{"approval" => ConduitMcp.MRTR.elicit("Approve?", @approval)}

if ConduitMcp.MRTR.missing_capabilities(requests, ctx.client_capabilities) == %{} do
  {:input_required, requests, %{}}
else
  text("This client can't confirm; run it from a client that supports elicitation.")
end
```

## Security properties

The spec says servers must treat `requestState` as attacker-controlled.
`ConduitMcp.MRTR.State` seals it as follows:

- **Encrypted and authenticated** with AES-256-GCM, using a fresh 96-bit IV
  per seal.
- **Bound to the request.** The protocol version, method, the Server or
  Endpoint module that handles the request, and `kid` are authenticated
  data, so a token sealed by one endpoint does not open at another endpoint
  in the same node (the keyring is application-global). The payload holds the principal
  (`ConduitMcp.Principal.id/1`), an expiry, and a SHA-256 digest of the
  method and the request's *salient* params: everything except `_meta`,
  `inputResponses` and `requestState`. A token presented for a different
  tool, arguments, URI, prompt, principal or endpoint is rejected.
- **Short-lived.** Tokens expire after 5 minutes, or 60 seconds when the
  request is unauthenticated.
- **Bounded.** Tokens over 64 KiB are rejected before any decoding. The
  payload is JSON; `:erlang.binary_to_term/1` is never used.
- **Opaque failures.** Every failure is the same `-32602 "Invalid
  requestState"`, so a client learns nothing about which check failed. The
  token is never logged, and neither is the state.
- **Replay is bounded, not prevented.** The same principal can replay a
  token on the same request until it expires. Single-use redemption needs
  server-side storage.

Telemetry never includes the input requests, the state or the token.

## Legacy era

MRTR exists only on `2026-07-28`. On a legacy request (`2025-11-25`,
`2025-06-18`), a callback that returns `{:input_required, ...}` is logged,
and the client gets `-32603` with the message "MRTR input requests require
protocol 2026-07-28". If a callback can serve both eras, check
`ConduitMcp.Ctx.from_conn(conn).era` first and fall back on legacy.

## Telemetry

`[:conduit_mcp, :mrtr, :input_required]` is emitted once per
`input_required` result sent, after gating and sealing succeed. It is not
emitted for a round rejected with `-32021` or `-32603`.

| | |
|---|---|
| Measurements | `%{count: n}`, the number of input requests |
| Metadata | `%{method: "tools/call" \| "resources/read" \| "prompts/get", server_module: module, round: pos_integer}` |

`round` is `1` for a first request and `n + 1` for a retry of round `n`.
It is taken from the sealed state, not from anything the client sent.

## Errors

| Code | When |
|---|---|
| `-32021` (HTTP 400) | An input request needs a capability the client didn't declare |
| `-32602` | `requestState` failed to open (tampered, expired, foreign, oversized, unknown `kid`), or `inputResponses` isn't an object |
| `-32603` | Malformed `input_requests`; state can't be sealed (no `:mrtr_keys`, not JSON-encodable); legacy-era request |

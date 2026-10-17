# LLM agent — a governed MCP hub behind the Anthropic Messages API

A small standalone Mix project showing the client side of ConduitMCP in an
agent loop:

- a `ConduitMcp.Client.Hub` (`LlmAgent.Hub`) over two MCP servers:
  - `notes` — `priv/notes_server.exs`, a tiny server on **stdio**
    (`list_notes`, `read_note`, `delete_note`);
  - `tools` — the [`simple_tools_server`](../simple_tools_server) example
    over **Streamable HTTP** (`echo`, `reverse_string`), served locally by
    this project unless `MCP_HTTP_URL` points at another server;
- a required **policy**: reading notes and every `tools` tool are allowed,
  any `delete_*` is denied, and with no `:on_ask` approver everything else
  is denied too;
- a **pre-hook** that writes an audit line per call (`LlmAgent.Hooks.audit/2`)
  and a **post-hook** that redacts API keys from results before the model
  sees them (`LlmAgent.Hooks.redact/3`);
- the **Anthropic adapter**: `ConduitMcp.Client.Adapters.tools/3` lists the
  hub's tools as Anthropic tool definitions (named `server__tool`), and
  `ConduitMcp.Client.Adapters.execute_tool_calls/4` runs the model's
  `tool_use` blocks through policy, hooks and the owning server, answering
  with `tool_result` blocks (`LlmAgent.Agent`). The servers whose output
  entered the conversation are passed as `taint:` on the next turn.

The configuration lives in `lib/llm_agent/application.ex`.

## Run

```bash
cd examples/llm_agent
mix deps.get

# No API key needed: starts both servers, lists the tools, and runs a
# synthetic tool_use response (a read that gets redacted, an HTTP call, a
# call the policy denies, a tool that does not exist) through
# execute_tool_calls/4.
mix llm_agent.smoke

# The agent loop against the Messages API.
export ANTHROPIC_API_KEY=...
export ANTHROPIC_MODEL=...   # any current Claude model id
mix llm_agent.ask "What does my deploy note say? Then reverse the word 'conduit'."
```

The audit lines show every call before the policy decides; the deploy note
reaches the model with its key replaced by `[REDACTED]`; asking the model
to delete a note gets an error result from the policy, and nothing is sent
to the server.

## Configuration

All from the environment (`config/runtime.exs`); nothing is hard-coded.

| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | required by `mix llm_agent.ask` |
| `ANTHROPIC_MODEL` | — | required by `mix llm_agent.ask` |
| `ANTHROPIC_URL` | `https://api.anthropic.com/v1/messages` | |
| `MCP_HTTP_URL` | unset | an MCP server URL for the `tools` server; unset serves `simple_tools_server` locally |
| `MCP_HTTP_PORT` | `4101` | the port of the local `simple_tools_server` |

## Notes

- The stdio server runs as `elixir -pa <this project's ebin dirs>
  priv/notes_server.exs`. The stdio transport gives a server only an
  allowlisted environment, so `PATH` is passed explicitly.
- `:finch` is a dependency because the client's Streamable HTTP transport
  needs it; `:req` is only for the Messages API calls.
- The hub lists tools only from servers that are `:ready`; the loop lists
  them on every turn, so a server that goes down drops out of the offered
  tools rather than failing the turn.

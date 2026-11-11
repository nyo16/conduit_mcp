---
module: "ConduitMcp.Client.Hub.Manager"
date: "2026-11-10"
problem_type: security_issue
component: genserver
symptoms:
  - "secret_scan_test: {\"hub manager\", \"PLAIN-HEADER-...\"} found in :sys.get_status/1 after :sys.log(manager, true) and a call"
  - "the marker is still present after format_status/1 replaces :log with []"
  - "DEBUG print shows the raw `[log: [8, {{:out, :ok, from, %{config: %{servers: ...}}}}]]` as the 4th status element"
root_cause: "sys:get_status/1 returns the process's raw `Debug` option list (which holds the :sys.log ring buffer of every message and the state after each call) verbatim as the 4th element; format_status/1 only formats the 5th element and crash reports"
severity: medium
tags: [format-status, sys-get-status, sys-log, redaction, secrets, genserver, otp]
---

# `:sys.get_status/1` returns the raw `:sys.log` buffer whatever `format_status/1` does

## Symptoms

After `:sys.log(manager, true)` and one `Hub.add_server/3` call,
`:sys.get_status(manager)` still carried a plain header credential, even with
`format_status/1` doing `Map.replace(status, :log, [])`.

## Investigation

1. **Hypothesis: `format_status/1` is not given `:log`.** Wrong. OTP 29
   `gen_server.erl` `format_status/2` passes `#{state => State, log => sys:get_log(Debug)}`
   and puts the result under "Logged events".
2. **Hypothesis: the leak is somewhere else in the formatted part.** I printed the
   whole status. The marker sat in `[log: [...]]`, the 4th list element.
3. **Root cause found:** `sys.erl` `get_status/5` builds
   `{status, self(), {module, Mod}, [PDict, SysState, Parent, Debug, FmtMisc]}`.
   `Debug` is the unformatted debug option list, ring buffer included. Only
   `FmtMisc` goes through `Mod:format_status`.

## Root Cause

`:sys.get_status/1` is an operator tool. It gives back the debug options the
operator turned on, raw. No callback can redact that element. The log events hold
`{:in, msg, from}` and `{:out, reply, to, state}`, i.e. the full state after each
call.

## Solution

Clear `:log` in `format_status/1` anyway. That governs the formatted section and
every crash report. Assert on the formatted element in tests, not on the whole
tuple.

```elixir
@impl GenServer
def format_status(status) do
  status
  |> Map.update(:state, nil, fn %{config: _} = s -> %{s | config: :redacted}; o -> o end)
  |> Map.update(:message, nil, fn {:add, id, _} -> {:add, id, :redacted}; o -> o end)
  |> Map.replace(:log, [])
end
```

```elixir
# test: the formatted part is what format_status/1 controls
{:status, _pid, _mod, [_pdict, _sys_state, _parent, _debug, formatted]} =
  :sys.get_status(manager)
```

Mutation check: replacing `Map.replace(:log, [])` with a no-op makes the
formatted-part assertion fail.

### Files Changed

- `lib/conduit_mcp/client/hub/manager.ex` `format_status/1`: `Map.replace(:log, [])`
- `test/conduit_mcp/client/secret_scan_test.exs`: SEC-M1 test enables `:sys.log`,
  makes a call, asserts on the 5th status element

## Prevention

- Any process holding secrets: implement `format_status/1` and replace `:log`
  as well as `:state`/`:message`. `TokenStore.ETS` and the hub manager both do.
- Never write "no secret anywhere in `:sys.get_status/1`" as an acceptance
  criterion while `:sys.log` is on: OTP cannot meet it.
- Secret-scan tests: pattern-match the status tuple and scan `formatted`.

## Related

- `CLAUDE.md` Conventions: "Every stateful process that may hold secrets ... implements `format_status/1`"

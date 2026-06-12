---
problem: Testing code that calls Req.get/2 directly, without a plug option to inject
component: testing
symptoms: [Req.Test stubs ignored, real HTTP attempted in tests]
root_cause: Req.Test interception requires the request to carry plug: {Req.Test, name}
solution: Req.default_options(plug: {Req.Test, name}) in setup, async: false, reset in on_exit
date: 2026-06-11
---

# Stubbing Req in code that doesn't expose a plug option

When library code calls `Req.get(url, opts)` directly (no injectable
`:plug`), route requests through `Req.Test` globally:

```elixir
# async: false — Req.default_options is global application env
setup do
  Req.default_options(plug: {Req.Test, __MODULE__})
  on_exit(fn -> Application.delete_env(:req, :default_options) end)
  :ok
end

Req.Test.stub(__MODULE__, fn conn ->
  conn |> Plug.Conn.put_resp_content_type("application/json")
       |> Plug.Conn.send_resp(200, JSON.encode!(%{"keys" => [...]}))
end)
```

Notes from `test/conduit_mcp/oauth/jwks_test.exs`:
- Re-stub mid-test to simulate state changes (key rollover, outage).
- `decode_body: false` in the code under test means stub bodies arrive as
  binaries — stub with `send_resp`, not `Req.Test.json`, when you need
  size/shape control.
- Prove cache hits by re-stubbing with `fn _ -> raise "must not refetch" end`.
- Use a unique URI per test — named ETS caches outlive tests.

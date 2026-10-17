Code.require_file("bench/bench_helper.exs")

alias ConduitMcp.Ctx
alias ConduitMcp.Era
alias ConduitMcp.Handler
alias ConduitMcp.Plugs.HeaderValidation
alias ConduitMcp.Transport.StreamableHTTP
alias Bench.Fixtures

# The cost of the modern (`2026-07-28`) era over the legacy one for the same
# `tools/call` and `tools/list`: era classification (`ConduitMcp.Era`),
# request-header validation (`ConduitMcp.Plugs.HeaderValidation`), modern vs
# legacy dispatch (`ConduitMcp.Handler.dispatch/3`), and all of it through
# the `ConduitMcp.Transport.StreamableHTTP` plug with `Plug.Test`.

server = Bench.DSLServer
modern_version = "2026-07-28"
legacy_version = "2025-06-18"

modern_meta = %{
  "io.modelcontextprotocol/protocolVersion" => modern_version,
  "io.modelcontextprotocol/clientCapabilities" => %{}
}

modern = fn request -> put_in(request, ["params", "_meta"], modern_meta) end

legacy_call = Fixtures.tool_call_request("echo", Fixtures.small_params())
legacy_list = Fixtures.list_tools_request()
modern_call = modern.(legacy_call)
modern_list = modern.(legacy_list)

legacy_headers = fn _request -> [{"mcp-protocol-version", legacy_version}] end

modern_headers = fn request ->
  name =
    case request["params"] do
      %{"name" => name} -> [{"mcp-name", name}]
      _ -> []
    end

  [{"mcp-protocol-version", modern_version}, {"mcp-method", request["method"]} | name]
end

# A conn as the transport has it after `Plug.Parsers`: decoded body, headers,
# server module.
parsed_conn = fn request, headers ->
  conn =
    Enum.reduce(headers, Plug.Test.conn(:post, "/", ""), fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)

  %{conn | body_params: request}
  |> Plug.Conn.put_private(:server_module, server)
end

conn = Fixtures.fake_conn()

run = fn scenarios, file ->
  Benchee.run(scenarios,
    warmup: 2,
    time: 5,
    memory_time: 2,
    formatters: [
      Benchee.Formatters.Console,
      {Benchee.Formatters.HTML, file: "bench/output/#{file}.html"}
    ]
  )
end

IO.puts("\n=== Modern vs Legacy Request Benchmark ===")
IO.puts("Measures: era classification, header validation and dispatch overhead\n")

# --- era classification ---

IO.puts("--- Era.classify/2 ---\n")

run.(
  %{
    "legacy: classify tools/call" => fn -> Era.classify(legacy_call, conn) end,
    "modern: classify tools/call" => fn -> Era.classify(modern_call, conn) end
  },
  "modern_classify"
)

# --- header validation ---

IO.puts("\n--- Plugs.HeaderValidation.call/2 (classify + header checks) ---\n")

hv_legacy_call = parsed_conn.(legacy_call, legacy_headers.(legacy_call))
hv_modern_call = parsed_conn.(modern_call, modern_headers.(modern_call))
hv_modern_list = parsed_conn.(modern_list, modern_headers.(modern_list))

# Builds the x-mcp-header cache once, outside the measurement.
for conn <- [hv_legacy_call, hv_modern_call, hv_modern_list] do
  false = HeaderValidation.call(conn, []).halted
end

run.(
  %{
    "legacy: header validation tools/call" => fn -> HeaderValidation.call(hv_legacy_call, []) end,
    "modern: header validation tools/call" => fn -> HeaderValidation.call(hv_modern_call, []) end,
    "modern: header validation tools/list" => fn -> HeaderValidation.call(hv_modern_list, []) end
  },
  "modern_header_validation"
)

# --- dispatch ---

IO.puts("\n--- Handler.dispatch/3 (classify + route + callback + response) ---\n")

for request <- [legacy_call, legacy_list, modern_call, modern_list] do
  {:reply, %{"result" => _}} = Handler.dispatch(request, server, conn)
end

run.(
  %{
    "legacy: dispatch tools/call" => fn -> Handler.dispatch(legacy_call, server, conn) end,
    "modern: dispatch tools/call" => fn -> Handler.dispatch(modern_call, server, conn) end,
    "legacy: dispatch tools/list" => fn -> Handler.dispatch(legacy_list, server, conn) end,
    "modern: dispatch tools/list" => fn -> Handler.dispatch(modern_list, server, conn) end
  },
  "modern_dispatch"
)

# Header validation followed by dispatch with the context it stored, as
# `ConduitMcp.Transport.Shared` does it (legacy: `handle_request/3`).
pipeline = fn
  %Plug.Conn{body_params: request} = conn, :legacy ->
    conn = HeaderValidation.call(conn, [])
    Handler.handle_request(request, server, conn)

  %Plug.Conn{body_params: request} = conn, :modern ->
    conn = HeaderValidation.call(conn, [])
    Handler.dispatch(request, server, Ctx.from_conn(conn))
end

hv_legacy_list = parsed_conn.(legacy_list, legacy_headers.(legacy_list))

run.(
  %{
    "legacy: validate + dispatch tools/call" => fn -> pipeline.(hv_legacy_call, :legacy) end,
    "modern: validate + dispatch tools/call" => fn -> pipeline.(hv_modern_call, :modern) end,
    "legacy: validate + dispatch tools/list" => fn -> pipeline.(hv_legacy_list, :legacy) end,
    "modern: validate + dispatch tools/list" => fn -> pipeline.(hv_modern_list, :modern) end
  },
  "modern_validate_dispatch"
)

# --- full plug pipeline ---

IO.puts("\n--- StreamableHTTP via Plug.Test (parse + plugs + dispatch + encode) ---\n")

opts = StreamableHTTP.init(server_module: server)

http_conn = fn request, headers ->
  conn =
    Plug.Test.conn(:post, "/", JSON.encode!(request))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")

  Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
end

http = %{
  "legacy: HTTP tools/call" => http_conn.(legacy_call, legacy_headers.(legacy_call)),
  "modern: HTTP tools/call" => http_conn.(modern_call, modern_headers.(modern_call)),
  "legacy: HTTP tools/list" => http_conn.(legacy_list, legacy_headers.(legacy_list)),
  "modern: HTTP tools/list" => http_conn.(modern_list, modern_headers.(modern_list))
}

for {name, conn} <- http do
  %Plug.Conn{status: 200, resp_body: body} = StreamableHTTP.call(conn, opts)
  %{"result" => _} = JSON.decode!(body)
  IO.puts("ok: #{name}")
end

run.(
  Map.new(http, fn {name, conn} -> {name, fn -> StreamableHTTP.call(conn, opts) end} end),
  "modern_http"
)

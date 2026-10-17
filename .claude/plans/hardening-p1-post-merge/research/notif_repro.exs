Application.ensure_all_started(:conduit_mcp)
Code.require_file("test/support/test_server.ex")
Logger.configure(level: :error)

opts = ConduitMcp.Transport.StreamableHTTP.init(server_module: ConduitMcp.TestServer, allowed_origins: "*")

for params <- [nil, "x", %{"requestId" => "a"}] do
  body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => params})

  result =
    try do
      conn =
        Plug.Test.conn(:post, "/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> ConduitMcp.Transport.StreamableHTTP.call(opts)

      {conn.status, conn.resp_body}
    rescue
      e -> {:raised, e.__struct__}
    catch
      kind, reason -> {kind, reason}
    end

  IO.inspect({params, result})
end

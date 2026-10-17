defmodule ConduitMcp.Test.Client.ScriptedServer do
  @moduledoc """
  A scriptable MCP-over-HTTP server for behaviour this library's own server
  lacks (event ids and resumption, server requests mid-stream, the legacy
  GET stream, odd statuses, hostile bodies). Each test passes a handler:

      url =
        ScriptedServer.start(fn conn, message ->
          case message do
            %{"method" => "server/discover"} -> ScriptedServer.json(conn, 200, ...)
            ...
          end
        end)

  The handler runs in the Bandit connection process with the request's
  decoded JSON body (`nil` for a GET or DELETE, or an empty body) and
  returns the conn. Every request is also reported to the test process as
  `{:scripted, method_or_verb, conn.req_headers, message}` (`method_or_verb`
  is the JSON-RPC method, or `"GET"`/`"DELETE"`, or `:response` for a
  JSON-RPC response).
  """

  @behaviour Plug

  import Plug.Conn

  alias ConduitMcp.Test.Client.HTTPServers

  @modern "2026-07-28"
  @legacy "2025-11-25"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{handler: handler, test: test}) do
    {:ok, body, conn} = read_body(conn, length: 64 * 1024 * 1024)
    message = if body == "", do: nil, else: JSON.decode!(body)
    send(test, {:scripted, label(conn, message), conn.req_headers, message})
    handler.(conn, message)
  end

  defp label(%{method: "POST"}, %{"method" => method}), do: method
  defp label(%{method: "POST"}, %{"id" => _}), do: :response
  defp label(conn, _message), do: conn.method

  @doc "Serves `handler` on a fresh loopback port; returns the URL."
  def start(handler),
    do: HTTPServers.serve({__MODULE__, %{handler: handler, test: self()}})

  # --- responses ---------------------------------------------------------------

  @doc "Answers with a JSON body."
  def json(conn, status, body, headers \\ []) do
    conn
    |> merge_resp_headers(headers)
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  @doc "202 Accepted, no body."
  def accepted(conn), do: send_resp(conn, 202, "")

  @doc "Opens an event stream (200, `text/event-stream`)."
  def sse(conn, headers \\ []) do
    conn
    |> merge_resp_headers([{"content-type", "text/event-stream"} | headers])
    |> send_chunked(200)
  end

  @doc """
  Sends one event carrying `message` (a map, encoded as JSON, or raw data).
  Options: `:id`, `:retry`.
  """
  def event(conn, message, opts \\ []) do
    data = if is_map(message), do: JSON.encode!(message), else: message

    frame =
      [
        if(opts[:id], do: ["id: ", opts[:id], "\n"], else: []),
        if(opts[:retry], do: ["retry: ", Integer.to_string(opts[:retry]), "\n"], else: []),
        "data: ",
        data,
        "\n\n"
      ]

    {:ok, conn} = chunk(conn, frame)
    conn
  end

  # --- messages ------------------------------------------------------------------

  @doc "A JSON-RPC result for `request`."
  def result(%{"id" => id}, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @doc "A JSON-RPC error for `request`."
  def error(%{"id" => id}, code, message \\ "error"),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  @doc "A legacy `initialize` result."
  def initialize_result(request, capabilities \\ %{"tools" => %{}}) do
    result(request, %{
      "protocolVersion" => @legacy,
      "capabilities" => capabilities,
      "serverInfo" => %{"name" => "scripted", "version" => "1.0"}
    })
  end

  @doc "A modern `server/discover` result."
  def discover_result(request, capabilities \\ %{"tools" => %{}}) do
    result(request, %{
      "resultType" => "complete",
      "supportedVersions" => [@modern],
      "capabilities" => capabilities,
      "ttlMs" => 0,
      "cacheScope" => "public",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "scripted", "version" => "1"}
      }
    })
  end

  @doc "A tool result with one text block."
  def text_result(request, text),
    do: result(request, %{"content" => [%{"type" => "text", "text" => text}]})

  @doc "Header `name` of the request, or `nil`."
  def header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end

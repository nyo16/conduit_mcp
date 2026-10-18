defmodule ConduitMcp.Client.TraceparentTest do
  # Client trace-context propagation (TL-4): a W3C `traceparent` from the
  # caller's Logger metadata or the `:traceparent` request option goes into
  # a modern request's `_meta`, validated; `tracestate` and `baggage` never
  # do on their own.
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Client.Transport.InProcess

  @tp "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  @other "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"

  defp modern do
    name = {__MODULE__, make_ref()}
    conn = start_client(name)
    ready_modern(name, conn)
    {name, conn}
  end

  # Runs `fun` in a fresh process (its own Logger metadata) and returns the
  # `_meta` of the `tools/call` it sent.
  defp sent_meta(conn, fun) do
    task = Task.async(fun)
    {id, message, _opts} = expect_request(conn, "tools/call")
    reply(conn, id, %{"content" => []})
    assert {:ok, %ToolResult{}} = Task.await(task)
    message["params"]["_meta"]
  end

  test "the caller's Logger metadata traceparent reaches the modern _meta, and only it" do
    {name, conn} = modern()

    meta =
      sent_meta(conn, fn ->
        Logger.metadata(traceparent: @tp, tracestate: "k=v", baggage: "user=alice")
        Client.call_tool(name, "t", %{})
      end)

    assert meta["traceparent"] == @tp
    refute Map.has_key?(meta, "tracestate")
    refute Map.has_key?(meta, "baggage")
  end

  test "the :traceparent option wins over Logger metadata" do
    {name, conn} = modern()

    meta =
      sent_meta(conn, fn ->
        Logger.metadata(traceparent: @tp)
        Client.call_tool(name, "t", %{}, traceparent: @other)
      end)

    assert meta["traceparent"] == @other
  end

  test "a malformed traceparent is not propagated" do
    {name, conn} = modern()

    for bad <- [
          "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
          "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
          "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
          @tp <> "\r\nx",
          String.duplicate("a", 55),
          42
        ] do
      meta =
        sent_meta(conn, fn ->
          Logger.metadata(traceparent: bad)
          Client.call_tool(name, "t", %{})
        end)

      refute Map.has_key?(meta, "traceparent"), inspect(bad)

      meta = sent_meta(conn, fn -> Client.call_tool(name, "t", %{}, traceparent: bad) end)
      refute Map.has_key?(meta, "traceparent"), inspect(bad)
    end
  end

  test "a caller's explicit _meta traceparent is kept" do
    {name, conn} = modern()

    meta =
      sent_meta(conn, fn ->
        Logger.metadata(traceparent: @tp)
        Client.call_tool(name, "t", %{}, meta: %{"traceparent" => @other})
      end)

    assert meta["traceparent"] == @other
  end

  test "no trace context, no key" do
    {name, conn} = modern()
    meta = sent_meta(conn, fn -> Client.call_tool(name, "t", %{}) end)
    refute Map.has_key?(meta, "traceparent")
  end

  test "legacy requests carry no traceparent" do
    name = {__MODULE__, make_ref()}
    conn = start_client(name, protocol: :legacy)
    ready_legacy(name, conn)

    task =
      Task.async(fn ->
        Logger.metadata(traceparent: @tp)
        Client.call_tool(name, "t", %{})
      end)

    {id, message, _opts} = expect_request(conn, "tools/call")
    reply(conn, id, %{"content" => []})
    assert {:ok, _} = Task.await(task)
    refute Map.has_key?(message["params"], "_meta")
  end

  test "envelope/2 puts a traceparent only in the modern era" do
    info = %{
      version: "2026-07-28",
      client_capabilities: %{},
      client_info: %{},
      traceparent: @tp
    }

    assert Request.envelope(%{}, Map.put(info, :era, :modern))["_meta"]["traceparent"] == @tp
    assert Request.envelope(%{}, Map.put(info, :era, :legacy)) == %{}
  end

  defmodule TraceServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn),
      do: {:ok, %{"tools" => [%{"name" => "t", "inputSchema" => %{"type" => "object"}}]}}

    @impl true
    def handle_call_tool(conn, _name, _params) do
      tp = ConduitMcp.Ctx.from_conn(conn).traceparent
      {:ok, %{"content" => [%{"type" => "text", "text" => inspect(tp)}]}}
    end
  end

  test "the server sees it as ctx.traceparent, through a governed client" do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      {Client,
       name: name,
       protocol: :modern,
       transport: {InProcess, server: TraceServer},
       policy: [allow: ["*"]]}
    )

    assert :ok = Client.await_ready(name)
    Logger.metadata(traceparent: @tp)

    assert {:ok, %ToolResult{content: [%{"text" => text}]}} = Client.call_tool(name, "t", %{})
    assert text == inspect(@tp)

    assert {:ok, %ToolResult{content: [%{"text" => text}]}} =
             Client.call_tool(name, "t", %{}, traceparent: @other)

    assert text == inspect(@other)
  end
end

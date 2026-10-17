defmodule ConduitMcp.Client.LogNotificationsTest do
  # Inbound `notifications/message` (TL-3): what a server logs reaches
  # subscribers and `handle_log/3` sanitized (`ConduitMcp.Reflect.text/2` on
  # every string), with the level clamped to the RFC 5424 set, and at most
  # `:log_rate_limit` per connection: the rest is dropped and counted.
  use ExUnit.Case, async: true

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Test.Client.FakeTransport

  defmodule Logs do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_log(level, params, %{client: {_module, _ref, pid}}),
      do: send(pid, {:handle_log, level, params})
  end

  @dropped [:conduit_mcp, :client, :log, :dropped]

  defp start_ready(opts) do
    name = {__MODULE__, make_ref(), self()}
    conn = start_client(name, [handler: Logs] ++ opts)
    ready_modern(name, conn)
    :ok = Client.subscribe_notifications(name)
    {name, conn}
  end

  defp log(conn, params),
    do: FakeTransport.push(conn, {:notification, "notifications/message", params})

  # Notifications reach a subscriber in arrival order: once this one is in,
  # everything pushed before it was handled.
  defp barrier(name, conn) do
    FakeTransport.push(conn, {:notification, "notifications/barrier", %{}})
    assert_receive {:mcp_notification, ^name, "notifications/barrier", _params}
  end

  defp logged(name, acc \\ []) do
    receive do
      {:mcp_notification, ^name, "notifications/message", params} -> logged(name, [params | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "strings are sanitized, unknown keys dropped, the level clamped" do
    {name, conn} = start_ready([])

    log(conn, %{
      "level" => "WARNING",
      "logger" => "db\n2026-01-01 [error] forged",
      "data" => %{
        "msg\u202E" => "line one\r\nline two\e[31m",
        "list" => ["a\u0000b", 1, true, nil, %{"k" => "v\u2028"}]
      },
      "_meta" => %{"x" => "y"},
      "extra" => "dropped"
    })

    log(conn, %{"level" => "verbose\n", "data" => "x"})
    log(conn, %{"level" => 7, "data" => "y"})
    log(conn, %{"data" => "z"})
    barrier(name, conn)

    assert [first, second, third, fourth] = logged(name)

    assert first == %{
             "level" => "warning",
             "logger" => "db2026-01-01 [error] forged",
             "data" => %{
               "msg" => "line oneline two[31m",
               "list" => ["ab", 1, true, nil, %{"k" => "v"}]
             }
           }

    for params <- [second, third, fourth], do: assert(params["level"] == "info")
    assert Map.keys(fourth) == ["data", "level"]

    assert_receive {:handle_log, "warning", ^first}
    assert_receive {:handle_log, "info", ^second}
  end

  test "data strings are clamped, deep nesting is cut" do
    {name, conn} = start_ready([])
    deep = Enum.reduce(1..100, "leaf", fn _, acc -> [acc] end)

    log(conn, %{
      "level" => "info",
      "data" => %{"long" => String.duplicate("a", 10_000), "deep" => deep}
    })

    barrier(name, conn)

    assert [%{"data" => %{"long" => long, "deep" => cut}}] = logged(name)
    assert String.length(long) == 4_096
    refute inspect(cut, limit: :infinity) =~ "leaf"
  end

  test "beyond the per-connection budget, messages are dropped and counted" do
    {name, conn} = start_ready(log_rate_limit: [per_second: 1, burst: 3])
    attach(name, [@dropped])

    for n <- 1..10, do: log(conn, %{"level" => "info", "data" => "m#{n}"})
    barrier(name, conn)

    assert Enum.map(logged(name), & &1["data"]) == ["m1", "m2", "m3"]

    for _ <- 1..7 do
      assert_received {@dropped, _ref, %{count: 1}, %{client: ^name}}
    end

    refute_received {@dropped, _, _, _}

    # Only logs are limited.
    for _ <- 1..5, do: FakeTransport.push(conn, {:notification, "notifications/other", %{}})
    barrier(name, conn)

    for _ <- 1..5,
        do: assert_received({:mcp_notification, ^name, "notifications/other", _params})
  end

  test "the default budget is 50 per second" do
    config = ConduitMcp.Client.Config.new!(name: :x, transport: {FakeTransport, []})
    assert config.log_rate_limit[:per_second] == 50
  end
end

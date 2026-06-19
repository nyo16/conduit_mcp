defmodule Examples.ObanTasks.SmokeTest do
  @moduledoc """
  Boots the full app (Repo + Migrator + Rescuer + Oban + Bandit on a
  random port) and drives a `tools/call` → `tasks/get` poll → `tasks/result`
  round-trip through the HTTP transport using Req. Verifies that the
  ConduitMcp.Tasks.Store dispatch wiring actually lands tasks in SQLite
  and that the worker takes a row through to `completed`.
  """

  use ExUnit.Case, async: false

  # Requires the full app booted on a fixed port — excluded by default in
  # test_helper.exs. Run with `mix test --include integration`.
  @moduletag :integration

  @url "http://localhost:4041/"

  setup_all do
    # The Application has already been started by mix test (we don't
    # override start: false in mix.exs). The DB is the same one the
    # iex flow uses; tests use unique task ids so there's no
    # cross-talk with manual runs.
    :ok = wait_for_server()
    :ok
  end

  test "slow_render: tools/call -> tasks/get poll -> tasks/result" do
    {:ok, _} = init_session()

    %{"result" => %{"_meta" => %{"task" => %{"id" => task_id}}}} =
      rpc("tools/call", %{
        "name" => "slow_render",
        "arguments" => %{"script" => "smoke", "duration_ms" => 300}
      })

    assert is_binary(task_id) and byte_size(task_id) > 0

    # Poll up to ~3s for completion (300ms render + Oban scheduling slack).
    final = poll_until_terminal(task_id, 30)
    assert final["status"] == "completed"

    %{"result" => result} = rpc("tasks/result", %{"taskId" => task_id})
    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    assert text =~ "Render completed in 300ms"
  end

  test "ask_then_render: input_required -> provide_render_input -> completed" do
    {:ok, _} = init_session()

    %{"result" => %{"_meta" => %{"task" => %{"id" => task_id}}}} =
      rpc("tools/call", %{
        "name" => "ask_then_render",
        "arguments" => %{"duration_ms" => 200}
      })

    # Poll for the first attempt to land in input_required + snooze.
    task = poll_until_status(task_id, "input_required", 30)
    assert task["status"] == "input_required"
    assert %{"elicit" => %{"schema" => %{"properties" => %{"script" => _}}}} = task["metadata"]

    %{"result" => _} =
      rpc("tools/call", %{
        "name" => "provide_render_input",
        "arguments" => %{"task_id" => task_id, "script" => "smoke input"}
      })

    # Snooze interval is 5s; render itself is 200ms. Poll generously.
    final = poll_until_terminal(task_id, 80)
    assert final["status"] == "completed"
    assert final["metadata"]["input"] == "smoke input"
  end

  # --- helpers ---

  defp init_session do
    body =
      rpc("initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "smoke", "version" => "0"}
      })

    {:ok, body}
  end

  defp rpc(method, params) do
    Req.post!(@url,
      json: %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      }
    ).body
  end

  defp get_task(task_id) do
    %{"result" => %{"task" => task}} = rpc("tasks/get", %{"taskId" => task_id})
    task
  end

  defp poll_until_terminal(task_id, max_attempts) do
    poll_until(
      task_id,
      max_attempts,
      &(&1["status"] in ~w(completed failed cancelled)),
      "a terminal state"
    )
  end

  defp poll_until_status(task_id, status, max_attempts) do
    poll_until(task_id, max_attempts, &(&1["status"] == status), "status #{inspect(status)}")
  end

  # Iron-Law exception: Process.sleep is acceptable here. This is an
  # :integration test that drives the real HTTP transport against an async
  # Oban worker — there's no deterministic event to await across the process
  # boundary, so bounded polling is the pragmatic choice.
  defp poll_until(task_id, max_attempts, predicate, description) do
    Enum.reduce_while(1..max_attempts, nil, fn _, _ ->
      Process.sleep(100)
      task = get_task(task_id)
      if predicate.(task), do: {:halt, task}, else: {:cont, nil}
    end)
    |> case do
      nil -> flunk("task #{task_id} did not reach #{description} within budget")
      task -> task
    end
  end

  # Iron-Law exception (Process.sleep): polling for the HTTP server to accept
  # connections during :integration boot. Budget is 100 × 100ms = 10s — the
  # first boot runs cold SQLite migrations (Oban schema + mcp_tasks), which can
  # exceed the previous 5s on a slow/cold CI runner.
  defp wait_for_server do
    Enum.reduce_while(1..100, :error, fn _, _ ->
      try do
        case Req.get!("http://localhost:4041/health") do
          %{status: 200} -> {:halt, :ok}
          _ -> {:cont, :error}
        end
      rescue
        _ ->
          Process.sleep(100)
          {:cont, :error}
      end
    end)
    |> case do
      :ok -> :ok
      :error -> flunk("server did not come up on :4041 within 10s")
    end
  end
end

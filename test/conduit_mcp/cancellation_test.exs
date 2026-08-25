defmodule ConduitMcp.CancellationTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Principal

  setup do
    if :ets.whereis(:conduit_mcp_cancellations) != :undefined do
      :ets.delete_all_objects(:conduit_mcp_cancellations)
    end

    previous = Application.get_env(:conduit_mcp, :cancellations_max_rows)
    previous_per_scope = Application.get_env(:conduit_mcp, :cancellations_max_rows_per_scope)

    on_exit(fn ->
      restore(:cancellations_max_rows, previous)
      restore(:cancellations_max_rows_per_scope, previous_per_scope)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:conduit_mcp, key)
  defp restore(key, value), do: Application.put_env(:conduit_mcp, key, value)

  defp client_conn(scope_opts) do
    %Plug.Conn{}
    |> Map.put(:remote_ip, Keyword.get(scope_opts, :remote_ip, {127, 0, 0, 1}))
    |> then(fn conn ->
      case Keyword.get(scope_opts, :session_id) do
        nil -> conn
        id -> Plug.Conn.put_private(conn, :mcp_session_id, id)
      end
    end)
    |> then(fn conn ->
      case Keyword.get(scope_opts, :principal) do
        nil -> conn
        id -> Principal.put(conn, %{id: id})
      end
    end)
    |> then(fn conn ->
      case Keyword.get(scope_opts, :request_id) do
        nil -> conn
        id -> Plug.Conn.assign(conn, :mcp_request_id, id)
      end
    end)
  end

  describe "scope/1" do
    test "prefers the session id, then the principal, then the client IP" do
      assert Cancellation.scope(client_conn(session_id: "sess-1", principal: "user-1")) ==
               "sess-1"

      assert Cancellation.scope(client_conn(principal: "user-1")) == "user-1"
      assert Cancellation.scope(client_conn(remote_ip: {203, 0, 113, 9})) == "203.0.113.9"
    end

    test "falls back to a constant for a non-conn" do
      assert Cancellation.scope(nil) == "global"
    end
  end

  describe "cancel/3 + cancelled?/2" do
    test "records cancellation by id (string or integer)" do
      assert :ok = Cancellation.cancel(42, "user pressed stop", "s")
      assert Cancellation.cancelled?(42, "s")
      assert Cancellation.cancelled?("42", "s")
    end

    test "stores reason and exposes it via reason/2" do
      Cancellation.cancel("req-1", "timeout", "s")
      assert Cancellation.reason("req-1", "s") == "timeout"
    end

    test "no-ops on nil id" do
      assert :ok = Cancellation.cancel(nil, nil, "s")
      refute Cancellation.cancelled?(nil, "s")
    end

    test "rejects a request id that is neither string nor integer" do
      # `to_string(%{})` used to raise here, and the notification path had no
      # rescue — a client mistake became a 500.
      assert {:error, :invalid_request_id} = Cancellation.cancel(%{}, nil, "s")
      assert {:error, :invalid_request_id} = Cancellation.cancel([1, 2], nil, "s")
      assert {:error, :invalid_request_id} = Cancellation.cancel(1.5, nil, "s")
      assert :ets.info(:conduit_mcp_cancellations, :size) == 0
    end

    test "truncates and strips control characters from the reason" do
      Cancellation.cancel("req-2", "abort\x00\x1b[31m" <> String.duplicate("x", 500), "s")

      reason = Cancellation.reason("req-2", "s")
      assert String.length(reason) == 200
      refute reason =~ "\x00"
      refute reason =~ "\e"
    end

    test "accepts a non-binary reason without raising" do
      Cancellation.cancel("req-3", %{"why" => "because"}, "s")
      assert is_binary(Cancellation.reason("req-3", "s"))
    end
  end

  describe "cross-client isolation" do
    test "client A cancelling id 1 does not affect client B's id 1" do
      a = client_conn(session_id: "session-a", request_id: 1)
      b = client_conn(session_id: "session-b", request_id: 1)

      assert :ok = Cancellation.cancel(1, "stop", Cancellation.scope(a))

      assert Cancellation.cancelled?(a)
      refute Cancellation.cancelled?(b)
    end

    test "two OAuth principals behind one IP do not share a namespace" do
      a = client_conn(principal: "alice", request_id: "7")
      b = client_conn(principal: "bob", request_id: "7")

      Cancellation.cancel("7", nil, Cancellation.scope(a))

      assert Cancellation.cancelled?(a)
      refute Cancellation.cancelled?(b)
    end

    test "clear/2 only clears the caller's own row" do
      a = client_conn(session_id: "session-a", request_id: "x")
      b = client_conn(session_id: "session-b", request_id: "x")

      Cancellation.cancel("x", nil, Cancellation.scope(a))
      Cancellation.cancel("x", nil, Cancellation.scope(b))

      Cancellation.clear("x", Cancellation.scope(a))

      refute Cancellation.cancelled?(a)
      assert Cancellation.cancelled?(b)
    end
  end

  describe "row cap" do
    test "the global cap bounds the table by evicting, not by rejecting" do
      # The global cap used to reject. That made it a cross-tenant DoS lever,
      # so it now reclaims from the largest scope instead — the table stays
      # bounded and the caller is still served. Rejection is the *per-scope*
      # quota's job, tested below.
      Application.put_env(:conduit_mcp, :cancellations_max_rows, 2)
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, :infinity)

      assert :ok = Cancellation.cancel("a", nil, "s")
      assert :ok = Cancellation.cancel("b", nil, "s")
      assert :ok = Cancellation.cancel("c", nil, "s")

      assert :ets.info(:conduit_mcp_cancellations, :size) <= 2
      # The newest insert is the one that survives.
      assert Cancellation.cancelled?("c", "s")
    end

    test ":infinity disables the cap" do
      Application.put_env(:conduit_mcp, :cancellations_max_rows, :infinity)
      for i <- 1..5, do: assert(:ok = Cancellation.cancel("id-#{i}", nil, "s"))
      assert :ets.info(:conduit_mcp_cancellations, :size) == 5
    end

    test "the per-scope quota stops one client denying cancellation to others" do
      # A global cap alone is a cross-tenant DoS: one unauthenticated client
      # filling the table refuses every other client's cancellations.
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, 3)

      for i <- 1..3, do: assert(:ok = Cancellation.cancel("flood-#{i}", nil, "attacker"))

      assert {:error, :cancellation_limit_reached} =
               Cancellation.cancel("flood-4", nil, "attacker")

      # Another client is entirely unaffected.
      assert :ok = Cancellation.cancel("mine", nil, "victim")
      assert Cancellation.cancelled?("mine", "victim")
    end

    test ":infinity disables the per-scope quota" do
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, :infinity)
      for i <- 1..300, do: assert(:ok = Cancellation.cancel("id-#{i}", nil, "s"))
      assert :ets.info(:conduit_mcp_cancellations, :size) == 300
    end

    test "the global cap does not deny a scope that is under its own quota" do
      # The per-scope quota bounds one scope to N rows, but nothing bounds how
      # many scopes one client owns: 6 scopes x 20 rows > a 100-row global cap.
      # With the global check first, that flood refused every *other* client's
      # cancellations - reinstating exactly the cross-tenant DoS the per-scope
      # quota exists to prevent, and which the moduledoc claims it prevents.
      Application.put_env(:conduit_mcp, :cancellations_max_rows, 100)
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, 20)

      for s <- 1..6, i <- 1..20 do
        Cancellation.cancel("a-#{s}-#{i}", nil, "attacker-#{s}")
      end

      # The backstop still holds: the table never exceeds the global cap.
      assert :ets.info(:conduit_mcp_cancellations, :size) <= 100

      # A victim holding zero rows is recorded, not refused.
      assert :ok = Cancellation.cancel("mine", nil, "victim")
      assert Cancellation.cancelled?("mine", "victim")

      # And the victim's own quota is still enforced against them.
      for i <- 1..19, do: Cancellation.cancel("v-#{i}", nil, "victim")

      assert {:error, :cancellation_limit_reached} =
               Cancellation.cancel("v-over", nil, "victim")
    end

    test "reclaim evicts the largest scope, not the caller" do
      Application.put_env(:conduit_mcp, :cancellations_max_rows, 40)
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, :infinity)

      for i <- 1..40, do: Cancellation.cancel("hog-#{i}", nil, "hog")
      assert :ets.info(:conduit_mcp_cancellations, :size) == 40

      assert :ok = Cancellation.cancel("small-1", nil, "small")

      # The small scope's row survives; the hog paid for it.
      assert Cancellation.cancelled?("small-1", "small")
      assert :ets.select_count(:conduit_mcp_cancellations, [{{{"hog", :_}, :_}, [], [true]}]) < 40
    end
  end

  describe "cancelled?/1 with Plug.Conn" do
    test "uses :mcp_request_id and the conn's scope" do
      conn = client_conn(session_id: "sess", request_id: "conn-1")
      Cancellation.cancel("conn-1", nil, Cancellation.scope(conn))
      assert Cancellation.cancelled?(conn)
    end

    test "returns false when conn has no request id" do
      refute Cancellation.cancelled?(%Plug.Conn{})
    end
  end

  describe "clear/2" do
    test "removes a cancellation entry" do
      Cancellation.cancel("req-2", nil, "s")
      assert Cancellation.cancelled?("req-2", "s")
      Cancellation.clear("req-2", "s")
      refute Cancellation.cancelled?("req-2", "s")
    end

    test "no-ops on nil and on a malformed id" do
      assert :ok = Cancellation.clear(nil, "s")
      assert :ok = Cancellation.clear(%{}, "s")
    end
  end

  describe "cleanup/1" do
    test "removes entries older than ttl_ms" do
      Cancellation.cancel("fresh", nil, "s")

      stale_at = System.system_time(:millisecond) - 60_000

      :ets.insert(
        :conduit_mcp_cancellations,
        {{"s", "stale"}, %{"reason" => nil, "cancelled_at" => stale_at}}
      )

      removed = Cancellation.cleanup(30_000)

      assert removed == 1
      assert Cancellation.cancelled?("fresh", "s")
      refute Cancellation.cancelled?("stale", "s")
    end
  end

  describe "supervision" do
    test "a janitor is started against this module by default" do
      assert is_pid(Process.whereis(Cancellation.Janitor))
    end

    test "the table is owned by the supervised Owner" do
      assert :ets.info(:conduit_mcp_cancellations, :owner) ==
               Process.whereis(Cancellation.Owner)
    end
  end

  describe "telemetry" do
    test "emits [:conduit_mcp, :request, :cancelled] on cancel" do
      handler_id = "cancel-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :request, :cancelled],
        fn _event, m, md, parent -> send(parent, {:cancelled, m, md}) end,
        self()
      )

      Cancellation.cancel("evt-1", "client abort", "s")

      assert_receive {:cancelled, %{count: 1},
                      %{request_id: "evt-1", scope: "s", reason: "client abort"}}
    end

    test "emits [:conduit_mcp, :cancellation, :cleanup] with the removed count" do
      handler_id = "cleanup-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :cancellation, :cleanup],
        fn _event, m, _md, parent -> send(parent, {:cleanup, m}) end,
        self()
      )

      stale_at = System.system_time(:millisecond) - 60_000

      :ets.insert(
        :conduit_mcp_cancellations,
        {{"s", "stale-evt"}, %{"reason" => nil, "cancelled_at" => stale_at}}
      )

      assert Cancellation.cleanup(30_000) == 1
      assert_receive {:cleanup, %{removed: 1}}
    end
  end
end

defmodule ConduitMcp.CancellationTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Cancellation
  alias ConduitMcp.Principal

  setup do
    for table <- [:conduit_mcp_cancellations, :conduit_mcp_in_flight],
        :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
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

  defp seed(scope, id, cancelled_at) do
    :ets.insert(
      :conduit_mcp_cancellations,
      {{scope, id}, %{"reason" => nil, "cancelled_at" => cancelled_at}}
    )
  end

  defp table_size, do: :ets.info(:conduit_mcp_cancellations, :size)

  defp scope_count(scope) do
    :ets.select_count(:conduit_mcp_cancellations, [{{{scope, :_}, :_}, [], [true]}])
  end

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
               "session:sess-1"

      assert Cancellation.scope(client_conn(principal: "user-1")) == "principal:user-1"
      assert Cancellation.scope(client_conn(remote_ip: {203, 0, 113, 9})) == "ip:203.0.113.9"
    end

    test "a principal id that bypassed Principal.put/2 falls back to the client IP" do
      # `Principal.put/2` normalises ids to strings, but a custom plug can
      # assign the principal map directly. `scope/1` runs in the handler's
      # `after` block, so raising here turned every such request into a 500.
      for id <- [123, %{"nested" => "x"}, :atom_id] do
        conn =
          client_conn(remote_ip: {203, 0, 113, 9})
          |> Plug.Conn.assign(Principal.assign_key(), %{id: id})

        assert Cancellation.scope(conn) == "ip:203.0.113.9"
      end
    end

    test "an anonymous IPv6 client is scoped to its /64, not its address" do
      # A host is routinely handed a whole /64 and can rotate through it at
      # will, so a per-address scope would multiply the per-scope quota.
      a = client_conn(remote_ip: {0x2001, 0xDB8, 1, 2, 0xA, 0xB, 0xC, 0xD})
      b = client_conn(remote_ip: {0x2001, 0xDB8, 1, 2, 0xFFFF, 0, 0, 1})

      assert Cancellation.scope(a) == "ip:2001:db8:1:2::/64"
      assert Cancellation.scope(b) == Cancellation.scope(a)
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

    test "rejects a string id longer than 256 bytes" do
      at_cap = String.duplicate("a", 256)

      assert :ok = Cancellation.cancel(at_cap, nil, "s")
      assert {:error, :invalid_request_id} = Cancellation.cancel(at_cap <> "a", nil, "s")
      # Bytes, not characters: 129 two-byte characters are 258 bytes.
      assert {:error, :invalid_request_id} =
               Cancellation.cancel(String.duplicate("é", 129), nil, "s")

      assert table_size() == 1
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

    test "a principal whose id equals a client IP does not share that IP's quota" do
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, 1)

      principal = client_conn(principal: "203.0.113.9", request_id: "1")
      anonymous = client_conn(remote_ip: {203, 0, 113, 9}, request_id: "1")

      assert :ok = Cancellation.cancel("1", nil, Cancellation.scope(principal))
      assert :ok = Cancellation.cancel("2", nil, Cancellation.scope(anonymous))

      refute Cancellation.cancelled?(anonymous)
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

    test "reclaim evicts the largest scope, not the caller or a bystander" do
      # max 100 -> batch of 5. The bystander's rows are the oldest in the table,
      # so an "evict the globally oldest batch" shortcut would take them.
      Application.put_env(:conduit_mcp, :cancellations_max_rows, 100)
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, :infinity)
      now = System.system_time(:millisecond)

      seed("bystander", "b-1", now - 10_000)
      seed("bystander", "b-2", now - 9_999)
      for i <- 1..98, do: seed("hog", "hog-#{i}", now - 5_000 + i)
      assert table_size() == 100

      assert :ok = Cancellation.cancel("small-1", nil, "small")

      assert scope_count("bystander") == 2
      assert Cancellation.cancelled?("small-1", "small")
      assert scope_count("hog") == 98 - 5
      # Oldest first within the hog scope.
      for i <- 1..5, do: refute(Cancellation.cancelled?("hog-#{i}", "hog"))
      assert Cancellation.cancelled?("hog-6", "hog")
    end

    test "reclaim spills into the next-largest scope when the largest is smaller than a batch" do
      # max 100 -> batch of 5. The largest scope holds only 4 rows, so the
      # fifth comes from the next largest, oldest first, and the third largest
      # is untouched. Rows get newer as scopes get larger, so an age-only
      # eviction would take the 1-row scopes instead.
      Application.put_env(:conduit_mcp, :cancellations_max_rows, 100)
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, :infinity)
      now = System.system_time(:millisecond)

      for i <- 1..91, do: seed("single-#{i}", "id", now - 10_000 + i)
      for i <- 1..2, do: seed("small", "small-#{i}", now - 7_000 + i)
      for i <- 1..3, do: seed("mid", "mid-#{i}", now - 5_000 + i)
      for i <- 1..4, do: seed("big", "big-#{i}", now - 1_000 + i)
      assert table_size() == 100

      assert :ok = Cancellation.cancel("mine", nil, "caller")

      assert table_size() == 100 - 5 + 1
      assert scope_count("big") == 0
      refute Cancellation.cancelled?("mid-1", "mid")
      assert Cancellation.cancelled?("mid-2", "mid")
      assert Cancellation.cancelled?("mid-3", "mid")
      assert scope_count("small") == 2
      for i <- 1..91, do: assert(Cancellation.cancelled?("id", "single-#{i}"))
      assert Cancellation.cancelled?("mine", "caller")
    end

    test "reclaim frees a full batch when every scope holds one row" do
      # Many 1-row scopes is the cheap flood (one `initialize` per scope).
      # Evicting from one scope only would free a single row per full scan.
      Application.put_env(:conduit_mcp, :cancellations_max_rows, 100)
      Application.put_env(:conduit_mcp, :cancellations_max_rows_per_scope, :infinity)
      now = System.system_time(:millisecond)

      # Insert newest first so table (key) order disagrees with age order.
      for i <- 100..1//-1, do: seed("scope-#{i}", "id", now - 1_000 + i)
      assert table_size() == 100

      assert :ok = Cancellation.cancel("mine", nil, "caller")

      assert table_size() == 100 - 5 + 1
      for i <- 1..5, do: refute(Cancellation.cancelled?("id", "scope-#{i}"))
      for i <- 6..100, do: assert(Cancellation.cancelled?("id", "scope-#{i}"))
      assert Cancellation.cancelled?("mine", "caller")
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

  describe "track/2, untrack/2 and in_flight?/2" do
    test "a tracked id is in flight in its own scope only" do
      assert :ok = Cancellation.track(7, "a")

      assert Cancellation.in_flight?(7, "a")
      assert Cancellation.in_flight?("7", "a")
      refute Cancellation.in_flight?(7, "b")
      refute Cancellation.in_flight?(70, "a")

      assert :ok = Cancellation.untrack(7, "a")
      refute Cancellation.in_flight?(7, "a")
    end

    test "concurrent duplicates of one id each hold a row" do
      # One request finishing must not make its still-running namesake
      # uncancellable.
      parent = self()

      other =
        spawn_link(fn ->
          Cancellation.track("dup", "s")
          send(parent, :tracked)

          receive do
            :done -> :ok
          end
        end)

      assert_receive :tracked
      assert :ok = Cancellation.track("dup", "s")
      assert :ok = Cancellation.untrack("dup", "s")

      assert Cancellation.in_flight?("dup", "s")
      send(other, :done)
    end

    test "ignores nil and over-long ids" do
      assert :ok = Cancellation.track(nil, "s")
      assert :ok = Cancellation.track(String.duplicate("a", 257), "s")

      assert :ets.info(:conduit_mcp_in_flight, :size) == 0
      refute Cancellation.in_flight?(nil, "s")
      assert :ok = Cancellation.untrack(nil, "s")
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

    test "removes in-flight rows whose process died without untracking" do
      # A stream process killed before the handler's `after` ran leaves its
      # row behind; the janitor's pass is the only thing that removes it.
      handler_id = "in-flight-cleanup-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:conduit_mcp, :cancellation, :cleanup],
        fn _event, m, _md, parent -> send(parent, {:cleanup, m}) end,
        self()
      )

      {pid, ref} = spawn_monitor(fn -> Cancellation.track("leaked", "s") end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :ok = Cancellation.track("live", "s")
      assert Cancellation.in_flight?("leaked", "s")

      # The return value stays the count of expired cancellation rows.
      assert Cancellation.cleanup(30_000) == 0
      assert_receive {:cleanup, %{removed: 0, in_flight_removed: 1}}

      refute Cancellation.in_flight?("leaked", "s")
      assert Cancellation.in_flight?("live", "s")
    end

    test "sweeping a dead process's row keeps a live process tracking the same id" do
      {pid, ref} = spawn_monitor(fn -> Cancellation.track("shared", "s") end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :ok = Cancellation.track("shared", "s")

      Cancellation.cleanup(30_000)

      assert :ets.lookup(:conduit_mcp_in_flight, {"s", "shared"}) == [{{"s", "shared"}, self()}]
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

    test "the in-flight table is owned by the supervised InFlightOwner" do
      assert :ets.info(:conduit_mcp_in_flight, :owner) ==
               Process.whereis(Cancellation.InFlightOwner)
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

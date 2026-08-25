defmodule ConduitMcp.EtsOwnerTest do
  # async: false — creates and destroys named ETS tables.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ConduitMcp.EtsOwner

  @opts [:named_table, :public, :set]

  defp table_name, do: :"ets_owner_test_#{System.unique_integer([:positive])}"
  defp owner_name(table), do: :"#{table}_owner"

  defp start_owner(owner, table, opts \\ @opts) do
    {:ok, pid} = EtsOwner.start_link(owner, table, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  describe "claiming" do
    test "owns the table it creates" do
      table = table_name()
      pid = start_owner(owner_name(table), table)

      assert :ets.info(table, :owner) == pid
    end

    test "a lost race logs and stays alive instead of raising" do
      # The failure mode this guards: an Owner exits, its table is destroyed,
      # and something calls ensure_table/0 before the supervised restart
      # completes. The restart then hits a taken name. Raising there means
      # three restarts in five seconds take down ConduitMcp.Supervisor — and
      # with it the consumer's whole application — over an ownership question.
      table = table_name()
      :ets.new(table, @opts)

      log =
        capture_log(fn ->
          pid = start_owner(owner_name(table), table)
          assert Process.alive?(pid)
        end)

      assert log =~ "could not claim"
      assert log =~ Atom.to_string(table)
      assert log =~ "ensure_table"
      assert log =~ "Retrying"
    end

    test "invalid options raise rather than being reported as an ownership race" do
      # `:ets.new/2` raises the identical ArgumentError for a taken name and for
      # bad options, and the exception carries no discriminator. Swallowing the
      # second told the operator "the name is already taken" for a typo, in the
      # one module whose job is making ownership diagnosable.
      table = table_name()
      # start_link/3 links, so the reraise would kill the test process.
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      log =
        capture_log(fn ->
          assert {:error, {%ArgumentError{}, _}} =
                   EtsOwner.start_link(owner_name(table), table, [:naned_table, :public])
        end)

      refute log =~ "could not claim"
      assert :ets.whereis(table) == :undefined
    end
  end

  describe "re-claiming" do
    test "takes the table once the racer releases it" do
      # A one-shot degrade idles forever owning nothing, while the table's
      # lifetime silently becomes that of whichever request created it. The
      # racer the warning names is short-lived by definition, so the name comes
      # back — the Owner has to ask for it again.
      table = table_name()
      test_pid = self()

      squatter =
        spawn(fn ->
          :ets.new(table, @opts)
          send(test_pid, :squatting)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :squatting

      owner_pid =
        capture_log(fn ->
          pid = start_owner(owner_name(table), table)
          send(test_pid, {:owner, pid})
        end)
        |> then(fn _log ->
          assert_received {:owner, pid}
          pid
        end)

      refute :ets.info(table, :owner) == owner_pid

      send(squatter, :release)

      # The reclaim timer is 1 s; give it a few cycles on a loaded runner.
      assert eventually(fn -> :ets.info(table, :owner) == owner_pid end),
             "the owner never reclaimed #{inspect(table)} after the racer exited"
    end
  end

  describe "the booted application" do
    test "every supervised owner actually owns its table" do
      # The positive direction: each Owner is the table's owner, not merely a
      # live process that owns nothing.
      owners = [
        {ConduitMcp.Cancellation.Owner, :conduit_mcp_cancellations},
        {ConduitMcp.Session.EtsStore.Owner, :conduit_mcp_sessions},
        {ConduitMcp.Transport.SSE.Owner, :conduit_mcp_sse_connections},
        {ConduitMcp.Tasks.EtsStore.Owner, :conduit_mcp_tasks}
      ]

      # Started only when `req` is available, so it is guarded rather than
      # omitted — omitting it is how it went unchecked in the first place, in
      # the one subsystem where losing ownership is authentication-shaped.
      owners =
        if Code.ensure_loaded?(ConduitMcp.OAuth.KeyProvider.JWKS.Owner) do
          owners ++
            [{ConduitMcp.OAuth.KeyProvider.JWKS.Owner, :conduit_mcp_jwks_cache}]
        else
          owners
        end

      assert length(owners) == 5, "the JWKS owner is not being checked"

      for {owner, table} <- owners do
        pid = Process.whereis(owner)
        assert is_pid(pid), "#{inspect(owner)} is not running"

        assert :ets.info(table, :owner) == pid,
               "#{inspect(table)} is not owned by #{inspect(owner)}"
      end
    end
  end

  defp eventually(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 6_000

    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(50) && eventually(fun, deadline)
    end
  end
end

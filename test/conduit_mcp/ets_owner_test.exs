defmodule ConduitMcp.EtsOwnerTest do
  # async: false — creates and destroys named ETS tables.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ConduitMcp.EtsOwner

  @opts [:named_table, :public, :set]

  defp table_name, do: :"ets_owner_test_#{System.unique_integer([:positive])}"
  defp owner_name(table), do: :"#{table}_owner"

  defp start_owner(owner, table, table_opts \\ @opts, opts \\ []) do
    {:ok, pid} = EtsOwner.start_link(owner, table, table_opts, opts)
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
    # A one-shot degrade idles forever owning nothing, while the table's
    # lifetime silently becomes that of whichever request created it. The
    # racer the warning names is short-lived by definition, so the name comes
    # back — and nothing but the Owner's own timer will ask for it again.

    test "takes the table by itself once the racer releases it" do
      table = table_name()
      squatter = squat(table)
      owner_pid = start_racing_owner(table)

      release(squatter, table)

      assert_reclaims(owner_pid, table)
    end

    test "a retry that loses again re-arms the timer" do
      table = table_name()
      squatter = squat(table)
      owner_pid = start_racing_owner(table)

      # One timer-driven retry runs while the name is still taken...
      assert_receive {:trace, ^owner_pid, :receive, :reclaim}, 1_000
      :sys.get_state(owner_pid)
      refute :ets.info(table, :owner) == owner_pid

      # ...so only a re-armed timer can deliver the claim that succeeds.
      release(squatter, table)

      assert_reclaims(owner_pid, table)
    end
  end

  describe "the booted application" do
    test "every supervised owner actually owns its table" do
      # The positive direction: each Owner is the table's owner, not merely a
      # live process that owns nothing.
      #
      # The JWKS owner is started only when `req` is compiled in, and this
      # suite always compiles with every optional dep, so it is listed
      # unconditionally: a missing owner fails the "is not running" assertion
      # below instead of being silently skipped.
      owners = [
        {ConduitMcp.Cancellation.Owner, :conduit_mcp_cancellations},
        {ConduitMcp.Cancellation.InFlightOwner, :conduit_mcp_in_flight},
        {ConduitMcp.Session.EtsStore.Owner, :conduit_mcp_sessions},
        {ConduitMcp.Transport.SSE.Owner, :conduit_mcp_sse_connections},
        {ConduitMcp.Tasks.EtsStore.Owner, :conduit_mcp_tasks},
        {ConduitMcp.OAuth.KeyProvider.JWKS.Owner, :conduit_mcp_jwks_cache}
      ]

      for {owner, table} <- owners do
        pid = Process.whereis(owner)
        assert is_pid(pid), "#{inspect(owner)} is not running"

        assert :ets.info(table, :owner) == pid,
               "#{inspect(table)} is not owned by #{inspect(owner)}"
      end
    end
  end

  defp squat(table) do
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
    squatter
  end

  # Waits for the squatter to be gone, and with it its table, so the next
  # claim cannot lose the race again.
  defp release(squatter, table) do
    ref = Process.monitor(squatter)
    send(squatter, :release)
    assert_receive {:DOWN, ^ref, :process, ^squatter, _}
    assert :ets.whereis(table) == :undefined
  end

  # Starts an owner that loses the race for `table`, retrying every 10 ms, and
  # traces what reaches its mailbox so the test sees each timer-delivered
  # `:reclaim` instead of sleeping. Any retry that fires before the trace is on
  # loses (the squatter still holds the name) and so only precedes a traced one.
  defp start_racing_owner(table) do
    {pid, log} =
      with_log(fn -> start_owner(owner_name(table), table, @opts, reclaim_interval: 10) end)

    assert log =~ "Retrying every 10ms"
    refute :ets.info(table, :owner) == pid

    :erlang.trace(pid, true, [:receive])
    pid
  end

  # Follows the owner's timer until a retry claims the table. `:sys.get_state/1`
  # is the barrier: it returns only after `handle_info(:reclaim, _)` for every
  # `:reclaim` received so far has run. A retry that arrived before the racer
  # exited may still lose, hence the loop; each wait is bounded, and a timer
  # that never fires fails the `assert_receive`.
  defp assert_reclaims(owner_pid, table) do
    capture_log(fn -> await_reclaim(owner_pid, table) end)
  end

  defp await_reclaim(owner_pid, table) do
    assert_receive {:trace, ^owner_pid, :receive, :reclaim},
                   1_000,
                   "no timer-driven :reclaim reached the owner of #{inspect(table)}"

    :sys.get_state(owner_pid)

    unless :ets.info(table, :owner) == owner_pid, do: await_reclaim(owner_pid, table)
  end
end
